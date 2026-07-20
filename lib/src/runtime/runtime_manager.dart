import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants.dart';
import 'application_runtime_identity.dart';
import 'runtime.dart';
import 'runtime_source_downloader.dart';

sealed class RuntimeManager {
  static const String _kRuntimeSourcesFileDefaultContent =
"""
[
  {
    "type": "github",
    "uri": "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
  }
]
""";

  static final _runtimeSourcesFilePath = p.join(runtimeDirectory, "sources.list");
  static final _latestUpdateFilePath = p.join(runtimeDirectory, "last_update");

  static final List<Runtime> _runtimes = [];
  static final Map<ApplicationRuntimeIdentity, Runtime> _runtimesByIdentity = {};
  static Future<void>? _findRuntimesFuture;
  static bool _runtimesInitializing = false;

  /// Checks for updates for all runtimes defined in the sources file.
  /// Reloads runtimes after updating, if any runtimes were updated.
  static Future<void> updateRuntimesFromSources() async {
    await _ensureRuntimes();
    final runtimeSourcesFile = File(_runtimeSourcesFilePath);
    if (!await runtimeSourcesFile.exists()) {
      print('Runtime sources file does not exist. Creating a default one now.');
      try {
        await runtimeSourcesFile.writeAsString(
          _kRuntimeSourcesFileDefaultContent,
          flush: true,
        );
      } catch (e) {
        print('Failed to create default runtime sources file "${runtimeSourcesFile.path}": $e');
      }
    }
    final res = await RuntimeSourceDownloader.download(
      runtimeSourcesFile,
      File(_latestUpdateFilePath),
    );
    if (res) {
      await _ensureRuntimes(true);
    }
  }

  /// Returns the runtime for the given application runtime identity,
  /// or null if it doesn't exist. Does not throw under regular circumstances.
  static Future<Runtime?> getRuntime(ApplicationRuntimeIdentity? runtimeIdentity) async {
    if (runtimeIdentity == null) {
      return null;
    }
    await _ensureRuntimes();
    return _runtimesByIdentity[runtimeIdentity];
  }

  /// Returns a list of found runtimes.
  static Future<List<Runtime>> listRuntimes() async {
    await _ensureRuntimes();
    return _runtimes;
  }

  /// Reads the source hash for a given runtime. It is used to resolve where the
  /// runtime came from.
  static Future<int?> readSourceHash(Directory runtimePath) async {
    final file = File(_getSourceHashFilePath(runtimePath));
    if (!await file.exists()) {
      return null;
    }
    return int.parse(await file.readAsString());
  }

  /// Writes a source hash for a given runtime. It is used to resolve where the
  /// runtime came from.
  static Future<void> writeSourceHash(Directory runtimePath, int? hash) async {
    final file = File(_getSourceHashFilePath(runtimePath));
    if (hash == null) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    await file.writeAsString(hash.toString());
  }

  /// Reads the remote hash for a given runtime. It is used to identify the
  /// version of the runtime.
  static Future<String?> readRemoteHash(Directory runtimePath) async {
    final file = File(_getRemoteHashFilePath(runtimePath));
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }

  /// Writes a remote hash for a given runtime. It is used to identify the
  /// version of the runtime.
  static Future<void> writeRemoteHash(Directory runtimePath, String? hash) async {
    final file = File(_getRemoteHashFilePath(runtimePath));
    if (hash == null) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    await file.writeAsString(hash.toString());
  }

  static String _getSourceHashFilePath(Directory runtimeDir) {
    return p.join(runtimeDir.path, 'source.hash');
  }

  static String _getRemoteHashFilePath(Directory runtimeDir) {
    return p.join(runtimeDir.path, 'remote.hash');
  }

  /// Finds all runtimes installed on this system.
  static Future<void> _findRuntimes() async {
    _runtimesInitializing = true;
    _runtimes.clear();
    _runtimesByIdentity.clear();

    await Runtime.initializeRuntimes();

    void addRuntimeIfNotExists(Runtime? runtime) {
      if (runtime == null) return;
      if (!_runtimesByIdentity.containsKey(runtime.identity)) {
        _runtimes.add(runtime);
        _runtimesByIdentity[runtime.identity] = runtime;
      }
    }

    List<Directory> dirs = [];
    final runtimeDir = Directory(runtimeDirectory);
    if (await runtimeDir.exists()) {
      dirs = (await runtimeDir.list().toList()).whereType<Directory>().toList();
    } else {
      print('Runtime directory does not exist (skipping): ${runtimeDir.path}');
    }

    dirs.add(Directory('/usr'));
    dirs = _sortCompatToolDirectories(dirs);

    for (final dir in dirs) {
      addRuntimeIfNotExists(await Runtime.fromDirectoryOrNull(dir));
    }

    if (_runtimes.isEmpty) {
      print('No runtimes found!');
    }

    print('Found ${_runtimes.length} runtimes:');
    for (final runtime in _runtimes) {
      print('\t${runtime.identity.name} version ${runtime.identity.version} at ${runtime.path.path}');
    }
  }

  static Future<void> _ensureRuntimes([bool reload = false]) async {
    if (reload) {
      if (_findRuntimesFuture != null) {
        await _findRuntimesFuture;
      }
      _runtimesInitializing = false;
    }
    if (!_runtimesInitializing) {
      _findRuntimesFuture = _findRuntimes();
    }
    await _findRuntimesFuture;
  }

  /// Sorts a list of Proton compatibility tool directory names into this
  /// priority order:
  ///
  /// 1. GE-Proton builds, highest version first (e.g. GE-Proton11-1 before
  ///    GE-Proton10-30 before GE-Proton10-25)
  /// 2. "Proton - Experimental"
  /// 3. The single highest-numbered official "Proton X.Y" build
  /// 4. "Proton Hotfix"
  /// 5. All remaining official "Proton X.Y" builds, second-highest to lowest
  ///
  /// Anything that doesn't match a known naming pattern is left in place at
  /// the end (in original relative order), so unexpected entries don't get
  /// silently dropped.
  static List<Directory> _sortCompatToolDirectories(List<Directory> dirs) {
    final geProtonRegex = RegExp(r'^GE-Proton(\d+)-(\d+)$');
    final protonRegex = RegExp(r'^Proton (\d+)\.(\d+)$');
    const experimentalName = 'Proton - Experimental';
    const hotfixName = 'Proton Hotfix';

    final geProtons = <Directory>[];
    final protons = <Directory>[];
    final others = <Directory>[];
    Directory? experimental;
    Directory? hotfix;

    for (final dir in dirs) {
      final name = p.basename(dir.path);
      if (geProtonRegex.hasMatch(name)) {
        geProtons.add(dir);
      } else if (name == experimentalName) {
        experimental = dir;
      } else if (name == hotfixName) {
        hotfix = dir;
      } else if (protonRegex.hasMatch(name)) {
        protons.add(dir);
      } else {
        others.add(dir);
      }
    }

    int compareVersionsDesc(String a, String b, RegExp pattern) {
      final matchA = pattern.firstMatch(a)!;
      final matchB = pattern.firstMatch(b)!;
      final majorA = int.parse(matchA.group(1)!);
      final minorA = int.parse(matchA.group(2)!);
      final majorB = int.parse(matchB.group(1)!);
      final minorB = int.parse(matchB.group(2)!);
      if (majorA != majorB) return majorB.compareTo(majorA);
      return minorB.compareTo(minorA);
    }

    geProtons.sort((a, b) => compareVersionsDesc(
      p.basename(a.path),
      p.basename(b.path),
      geProtonRegex,
    ));

    protons.sort((a, b) => compareVersionsDesc(
      p.basename(a.path),
      p.basename(b.path),
      protonRegex,
    ));

    final result = <Directory>[];
    result.addAll(geProtons);
    if (experimental != null) result.add(experimental);
    if (protons.isNotEmpty) result.add(protons.first);
    if (hotfix != null) result.add(hotfix);
    if (protons.length > 1) result.addAll(protons.sublist(1));
    result.addAll(others);

    return result;
  }
}
