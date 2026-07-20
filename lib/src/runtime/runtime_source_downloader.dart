import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../architecture.dart';
import '../constants.dart';
import '../gui_dialog.dart';
import 'runtime.dart';
import 'runtime_manager.dart';
import 'runtime_source.dart';

sealed class RuntimeSourceDownloader {
  static const _kUpdateCheckDuration = Duration(days: 2);

  /// Downloads updates from sources defined in [runtimeSourcesFile].
  /// Returns true if any runtimes were updated, otherwise false.
  static Future<bool> download(File runtimeSourcesFile, File lastUpdateFile) async {
    // Check available sources to donwload runtimes from.
    RuntimeSources sources;
    try {
      sources = await RuntimeSources.read(runtimeSourcesFile);
    } on PathNotFoundException {
      _print("Failed to read sources file (skipping updates), because it does not exist.");
      return false;
    } catch (e) {
      _print("Failed to read sources file (skipping updates): $e");
      return false;
    }

    // Check whether to update based on [_kUpdateCheckDuration]. We don't need
    // to be constantly updating if there are many frequently updating runtimes.
    // Instead, we will update all at once, more rarely, for UX purposes.
    DateTime? lastUpdate;
    try {
      lastUpdate = await _readLastUpdate(lastUpdateFile);
    } catch (e) {
      _print("Failed to read last update file. Updating now: $e");
    }

    final difference = lastUpdate?.difference(DateTime.now()).abs();
    final shouldUpdate = difference == null || difference > _kUpdateCheckDuration;

    if (!shouldUpdate) {
      _print("Skipping automatic updates.");
      return false;
    }

    _print("Performing automatic updates.");
    try {
      await _writeLastUpdate(lastUpdateFile);
    } catch (e) {
      _print("Failed to write last update file (updating anyway): $e");
    }

    // Check updates from all sources. [anyUpdated] stays false if nothing updated,
    // otherwise true. Shows a per-source-update progress dialog.
    bool anyUpdated = false;
    for (final source in sources.sources) {
      _print("Downloading source.", source);

      GuiDialog? progressDialog;
      bool updated;

      Future<void> onProgress(int received, int total) async {
        final pct = total > 0 ? (received / total * 100) : 0;
        progressDialog ??= GuiDialog.progress(
          "Downloading runtimes...",
          intermediate: false
        );
        await progressDialog!.updateProgress(
          percentage: pct.toInt(),
        );
      }

      try {
        switch (source.type) {
          case RuntimeSourceType.static:
            updated = await _downloadStatic(source);
            break;
          case RuntimeSourceType.github:
            updated = await _downloadGithub(source, onProgress);
            break;
          // ignore: unreachable_switch_default
          default: throw Exception("Unhandled runtime source type: ${source.type.name}");
        }

        if (updated) {
          anyUpdated = true;
        }
      } catch (e) {
        _print("Failed downloading source $source: $e");
      } finally {
        await progressDialog?.close();
      }

      _print("Successfully downloaded source.", source);
    }

    return anyUpdated;
  }

  static Future<bool> _downloadStatic(RuntimeSource source) async {
    throw UnimplementedError("Static downloads are not yet implemented.");
  }

  static Future<bool> _downloadGithub(
    RuntimeSource source,
    void Function(int received, int total)? onProgress,
  ) async {
    final uri = source.uri;
    final arch = await getArchitecture();

    final response = await http.get(
      uri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'appsupport-launcher-windows',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('GitHub API request failed: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String;
    final assets = json['assets'] as List<dynamic>;

    final tarAssets = assets
        .where((a) => (a['name'] as String).endsWith('.tar.gz'))
        .toList();

    if (tarAssets.isEmpty) {
      throw Exception('No .tar.gz assets found in release $tag');
    }

    final chosen = tarAssets
        .where((a) => _matchesArch(a['name'] as String, arch))
        .toList();

    if (chosen.isEmpty) {
      throw Exception(
        'No Proton-GE build available for architecture: $arch (release $tag)',
      );
    }

    final tarAsset = chosen.first;

    final expectedShaName = tarAsset['name'].toString().replaceAll('.tar.gz', '.sha512sum');
    final shaAsset = assets.firstWhereOrNull(
      (a) => (a['name'] as String) == expectedShaName,
    ) ?? assets.firstWhereOrNull(
      (a) => (a['name'] as String).endsWith('.sha512sum') && _matchesArch(a['name'] as String, arch),
    ) ?? assets.firstWhereOrNull(
      (a) => (a['name'] as String).endsWith('.sha512sum'),
    );

    final downloadUrl = tarAsset['browser_download_url'] as String;
    final fileName = tarAsset['name'] as String;
    //final size = tarAsset['size'] as int;
    final sha512Url = shaAsset != null
        ? shaAsset['browser_download_url'] as String
        : null;

    if (sha512Url == null) {
      _print("No hash for source type ${source.type.name} from: ${source.uri.toString()}");
    }

    final remoteHash = sha512Url != null ? await _fetchExpectedHash(sha512Url) : null;

    final updateCheck = await _shouldDownload(source, remoteHash);
    if (!updateCheck.performUpdate) {
      return false;
    }

    final tmpPath = p.join(Directory.systemTemp.path, fileName);
    try {
      await _downloadWithProgress(
        downloadUrl,
        tmpPath,
        onProgress: onProgress,
      );

      if (remoteHash != null) {
        await _verifySha512(tmpPath, remoteHash);
      }

      await _RuntimeTarInstaller.install(
        archivePath: tmpPath,
        archiveHash: remoteHash, // NOTE: remoteHash is equals local one at this point
        source: source,
        runtimeToOverwrite: updateCheck.runtimeToOverwrite,
      );
    } finally {
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }

    return true;
  }

  static Future<DateTime> _readLastUpdate(File file) async {
    return DateTime.parse(await file.readAsString());
  }

  static Future<void> _writeLastUpdate(File file) async {
    await file.writeAsString(DateTime.now().toString());
  }

  // TODO: Check by filename too
  /// Checks whether we should download updates for a given runtime. Will return
  /// true if the runtime to download is new, or the hashes differ, or if a hash
  /// doesn't exist. Otherwise returns false, like when [remoteSha512] is null
  /// or empty.
  static Future<_UpdateCheckResult> _shouldDownload(RuntimeSource source, String? remoteSha512) async {
    _print("Checking whether updates are needed.", source);

    String updateStr(bool update) => update ? "updating now" : "not updating";

    if (remoteSha512 == null || remoteSha512.trim().isEmpty) {
      const update = false;
      _print("Remote hash does not exist, ${updateStr(update)}.");
      return _UpdateCheckResult(
        performUpdate: update,
        runtimeToOverwrite: null,
      );
    }

    final runtimes = await RuntimeManager.listRuntimes();
    for (final runtime in runtimes) {
      int? runtimeSourceHash;
      try {
        runtimeSourceHash = await RuntimeManager.readSourceHash(runtime.path);
      } catch (e) {
        _print("Failed to get source of runtime $runtime: $e");
        continue;
      }

      if (runtimeSourceHash != source.hashCode) {
        continue;
      }

      String? runtimeRemoteHash;
      try {
        runtimeRemoteHash = await RuntimeManager.readRemoteHash(runtime.path);
      } catch (e) {
        const update = true;
        _print("Failed to get current runtime remote hash of runtime $runtime (${updateStr(update)}): $e");
        return _UpdateCheckResult(
          performUpdate: update,
          runtimeToOverwrite: runtime,
        );
      }

      final updating = runtimeRemoteHash != remoteSha512;
      _print("Checked updates of $runtime, ${updateStr(updating)}.");
      return _UpdateCheckResult(
        performUpdate: updating,
        runtimeToOverwrite: runtime,
      );
    }

    _print("Checked updates, but no existing runtime found for source $source. Downloading now.");
    return _UpdateCheckResult(
      performUpdate: true,
      runtimeToOverwrite: null,
    );
  }

  static Future<void> _downloadWithProgress(
    String url,
    String outputPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    http.Client? client;
    IOSink? sink;

    try {
      client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Download failed: ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      var received = 0;

      final file = File(outputPath);
      sink = file.openWrite();

      await response.stream.map((chunk) {
        received += chunk.length;
        onProgress?.call(received, total);
        return chunk;
      }).pipe(sink);
    } finally {
      if (sink != null) await sink.close();
      client?.close();
    }

    _print('Download complete.');
  }

  /*static Future<void> _fetchAndVerifyHash(String filePath, String? sha512Url) async {
    if (sha512Url != null) {
      final expected = await _fetchExpectedHash(sha512Url);
      await _verifySha512(filePath, expected);
    }
  }*/

  static Future<void> _verifySha512(String filePath, String expectedHash) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final digest = sha512.convert(bytes);
    final ok = digest.toString().toLowerCase() == expectedHash.toLowerCase().trim();
    if (!ok) throw Exception('Checksum verification failed!');
    _print('Checksum verified.');
  }

  static Future<String> _fetchExpectedHash(String shaUrl) async {
    final response = await http.get(Uri.parse(shaUrl));
    return response.body.split(' ').first;
  }

  // Suffixes/patterns that indicate a *non-default* architecture.
  // Proton-GE's x86_64 build has no suffix at all, so we can't positively
  // match "x86_64" -- we can only rule out the other architectures.
  static const _archMarkers = <Architecture, List<String>>{
    Architecture.arm64: ['aarch64', 'arm64'],
  };

  static Architecture? _explicitArchOf(String assetName) {
    final lower = assetName.toLowerCase();
    for (final entry in _archMarkers.entries) {
      if (entry.value.any((marker) => lower.contains(marker))) {
        return entry.key;
      }
    }
    return null; // no arch marker found -> default build (x86_64)
  }

  static bool _matchesArch(String assetName, Architecture wanted) {
    final explicit = _explicitArchOf(assetName);
    if (explicit != null) return explicit == wanted;
    // No marker present -> this is the default/unsuffixed build.
    return wanted == Architecture.x86_64;
  }

  static void _print(Object obj, [RuntimeSource? source]) {
    print('(RuntimeSourceDownloader) $obj${source != null ? ' $source' : ''}');
  }
}

sealed class _RuntimeTarInstaller {
  static Future<void> install({
    required String archivePath,
    required String? archiveHash,
    required RuntimeSource source,
    required Runtime? runtimeToOverwrite,
  }) async {
    final destDir = runtimeDirectory;

    // Remove old runtime version, if provided.
    if (runtimeToOverwrite != null && await runtimeToOverwrite.path.exists()) {
      _print('Deleting old runtime at ${runtimeToOverwrite.path.path}', source);
      await runtimeToOverwrite.path.delete(recursive: true);
    }

    // Extract new one safely.
    final path = Directory(await _safeExtractTarGz(archivePath, destDir));

    // Write runtime-specific hash data for future update checks.
    await RuntimeManager.writeSourceHash(path, source.hashCode);
    await RuntimeManager.writeRemoteHash(path, archiveHash);

    _print('Extracted to $destDir', source);
  }

  static Future<String> _safeExtractTarGz(String archivePath, String runtimesDir) async {
    // Refuse to extract into a directory that already has content
    final runtimesDirEntity = Directory(runtimesDir);
    await runtimesDirEntity.create(recursive: true);
    /*if (await destDirEntity.exists()) {
      final hasContent = await destDirEntity.list().isEmpty.then((e) => !e);
      if (hasContent) {
        throw Exception('Destination already exists and is not empty: $destDir');
      }
    }*/

    final entries = await _listTarEntries(archivePath);
    final rootDir = _getSingleRootDir(entries);

    final extractedPath = p.join(
      runtimesDir,
      rootDir ?? p.basenameWithoutExtension(archivePath),
    );

    if (await Directory(extractedPath).exists()) {
      throw Exception('Extraction target already exists: $extractedPath');
    }

    final result = await Process.run('tar', [
      '-xzf', archivePath,
      '-C', rootDir != null ? runtimesDir : extractedPath,
      '--keep-old-files',
    ]);
    if (result.exitCode != 0) {
      throw Exception('Extraction failed (${result.exitCode}): ${result.stderr}');
    }

    return extractedPath;

    /*if (rootDir != null) {
      // Tar already has one root dir (e.g. "GE-Proton9-20/...").

      final extractedPath = p.join(runtimesDir, rootDir);
      if (await Directory(extractedPath).exists()) {
        throw Exception('Extraction target already exists: $extractedPath');
      }

      final result = await Process.run('tar', [
        '-xzf', archivePath,
        '-C', runtimesDir,
        '--keep-old-files', // belt-and-suspenders: fail rather than overwrite
      ]);
      if (result.exitCode != 0) {
        throw Exception('Extraction failed (${result.exitCode}): ${result.stderr}');
      }

      /*if (extractedPath != runtimesDir) {
        await Directory(extractedPath).rename(runtimesDir);
      }*/
    } else {
      // No single root: multiple top-level entries. Wrap it ourselves
      // so it can't spill files into an arbitrary directory.
      //await runtimesDirEntity.create(recursive: true);

      final extractedPath = p.join(runtimesDir, p.basenameWithoutExtension(archivePath));
      if (await Directory(extractedPath).exists()) {
        throw Exception('Extraction target already exists: $extractedPath');
      }

      final result = await Process.run('tar', [
        '-xzf', archivePath,
        '-C', extractedPath,
        '--keep-old-files',
      ]);
      if (result.exitCode != 0) {
        throw Exception('Extraction failed (${result.exitCode}): ${result.stderr}');
      }
    }*/
  }

  static Future<List<String>> _listTarEntries(String archivePath) async {
    final result = await Process.run('tar', ['-tzf', archivePath]);
    if (result.exitCode != 0) {
      throw Exception('Failed to list tar contents: ${result.stderr}');
    }
    return (result.stdout as String)
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
  }

  /// Returns the single top-level directory name if every entry lives under
  /// one root, or null if there are multiple top-level files/dirs (a "tar bomb").
  static String? _getSingleRootDir(List<String> entries) {
    final topLevelNames = <String>{};

    for (final entry in entries) {
      final normalized = entry.startsWith('./') ? entry.substring(2) : entry;
      if (normalized.isEmpty) continue;
      topLevelNames.add(normalized.split('/').first);
    }

    if (topLevelNames.length != 1) return null;

    final name = topLevelNames.first;
    // Confirm that name is actually a directory entry, not just a single
    // top-level file that happens to be the only entry.
    final isDir = entries.any((e) {
      final normalized = e.startsWith('./') ? e.substring(2) : e;
      return normalized == '$name/' || normalized.startsWith('$name/');
    });

    return isDir ? name : null;
  }

  static void _print(Object obj, [RuntimeSource? source]) {
    print('(_RuntimeTarInstaller) $obj${source != null ? ' $source' : ''}');
  }
}

class _UpdateCheckResult {
  final bool performUpdate;
  final Runtime? runtimeToOverwrite;

  const _UpdateCheckResult({
    required this.performUpdate,
    required this.runtimeToOverwrite,
  });
}