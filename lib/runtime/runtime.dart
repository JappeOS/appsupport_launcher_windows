import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../application_identity.dart';
import '../constants.dart';
import '../prefix/prefix_identity.dart';
import '../prefix/prefix_manager.dart';
import 'application_runtime_identity.dart';

/// Represents an installed runtime. A runtime is the environment in which
/// the target app will run. All applications might not work with all runtimes.
abstract class Runtime {
  static const List<Future<Runtime?> Function(Directory)> _runtimeConstructors = [
    WineRuntime.fromDirectoryOrNull,
    ProtonRuntime.fromDirectoryOrNull,
  ];

  static const List<Future<void> Function()> _runtimeInitializers = [
    WineRuntime.initialize,
    ProtonRuntime.initialize,
  ];

  static bool _runtimesInitializedSuccess = false;

  /// Tries to find and create a runtime from a directory. Returns null if
  /// the provided directory does not contain a runtime.
  static Future<Runtime?> fromDirectoryOrNull(Directory dir) async {
    assert(_runtimesInitializedSuccess);
    for (final constructor in _runtimeConstructors) {
      Runtime? runtime;
      try {
        runtime = await constructor(dir);
      } catch (e) {
        print('Error while trying to initialize runtime from directory ${dir.path}: $e');
        continue;
      }
      if (runtime != null) {
        return runtime;
      }
    }
    return null;
  }

  /// Initializes all static data for all runtime types. Call once before
  /// calling [fromDirectoryOrNull], or during app initialization.
  static Future<void> initializeRuntimes() async {
    if (_runtimesInitializedSuccess) {
      return;
    }
    for (final initializer in _runtimeInitializers) {
      await initializer();
    }
    _runtimesInitializedSuccess = true;
  }

  final ApplicationRuntimeIdentity identity;
  final Directory path;

  const Runtime(this.identity, this.path);

  /// Checks if this runtime is compatible with another one, based on the
  /// provided [ApplicationRuntimeIdentity].
  bool isCompatibleWith(ApplicationRuntimeIdentity appRuntimeIdentity);

  /// Gets the necessary information needed to launch a program using this
  /// runtime.
  Future<RuntimeLaunchInfo> getLaunchCommand(String appPath, PrefixIdentity prefixIdentity);

  /// Creates a prefix for this runtime. Make sure to use [isCompatibleWith]
  /// to check whether the same prefix can be used with a different runtime.
  Future<void> createPrefix(Directory prefixPath);
}

/// Launch parameters for a runtime.
class RuntimeLaunchInfo {
  final List<String> command;
  final Map<String, String> environment;
  final String? workingDirectory;

  const RuntimeLaunchInfo({
    required this.command,
    required this.environment,
    this.workingDirectory,
  });
}

class WineRuntime extends Runtime {
  static Future<void> initialize() async {}

  static Future<WineRuntime?> fromDirectoryOrNull(Directory dir) async {
    if (!await File(_getExecutablePath(dir)).exists()) {
      return null;
    }

    final version = await _readWineVersion(dir);
    if (version.isEmpty) {
      return null;
    }

    return WineRuntime._(
      ApplicationRuntimeIdentity(
        type: 'wine',
        version: version,
        name: 'Wine $version',
      ),
      dir,
    );
  }

  static Future<String> _readWineVersion(Directory dir) async {
    const resultTimeout = Duration(minutes: 1);
    final result = await Process.run(_getExecutablePath(dir), ['--version'])
        .timeout(resultTimeout, onTimeout: () {
          throw TimeoutException('Failed to read Wine version from $dir: Process timed out.', resultTimeout);
        });

    if (result.exitCode != 0) {
      throw Exception('Failed to read Wine version from $dir: ${result.stderr}');
    }
    return result.stdout.replaceFirst("wine-", "").trim();
  }

  static String _getExecutablePath(Directory dir) {
    return p.join(dir.path, 'bin', 'wine');
  }

  static String _getWinebootExecutablePath(Directory dir) {
    return p.join(dir.path, 'bin', 'wineboot');
  }

  const WineRuntime._(super.identity, super.path);

  @override
  bool isCompatibleWith(ApplicationRuntimeIdentity appRuntimeIdentity)
      => appRuntimeIdentity.type == identity.type;

  @override
  Future<RuntimeLaunchInfo> getLaunchCommand(String appPath, PrefixIdentity prefixIdentity) async {
    return RuntimeLaunchInfo(
      command: [_getExecutablePath(path), appPath],
      environment: {
        'WINEPREFIX': prefixIdentity.prefixPath,
      },
      workingDirectory: File(appPath).parent.path,
    );
  }

  @override
  Future<void> createPrefix(Directory prefixPath) async {
    const resultTimeout = Duration(minutes: 2);
    final result = await Process.run(
      _getWinebootExecutablePath(path),
      ['-u'],
      environment: {
        'WINEPREFIX': prefixPath.path,
        'WINEARCH': 'win64',
      },
    ).timeout(resultTimeout, onTimeout: () {
      throw TimeoutException('Failed to create Wine prefix at ${prefixPath.path}: Process timed out.', resultTimeout);
    });

    if (result.exitCode != 0) {
      throw Exception('Failed to create Wine prefix at ${prefixPath.path}: ${result.stderr}');
    }
  }
}

class ProtonRuntime extends Runtime {
  static const _kMetaKeyRuntimeProtonUmuDbEntry = "runtime.proton.umu_db_entry";

  static Future<void> initialize() async {
    final dbFile = File(_getUmuDatabasePath());
    if (await dbFile.exists() &&
        (await dbFile.length() > 1 ||
        (await dbFile.lastModified()).isAfter(DateTime.now().subtract(Duration(days: 15))))) {
      return; // Database is already present and not older than 15 days
    }

    print('Downloading UMU database for Proton runtimes...');

    final response = await http.get(
      Uri.parse('https://umu.openwinecomponents.org/umu_api.php'),
    );

    await dbFile.writeAsBytes(response.bodyBytes);
  }

  static Future<ProtonRuntime?> fromDirectoryOrNull(Directory dir) async {
    if (!await File(_getInternalProtonExecutablePath(dir)).exists()) {
      return null;
    }

    final version = await _readProtonVersion(dir);
    if (version.isEmpty) {
      return null;
    }

    return ProtonRuntime._(
      ApplicationRuntimeIdentity(
        type: 'proton',
        version: version,
        name: 'Proton $version',
      ),
      dir,
    );
  }

  static Future<String> _readProtonVersion(Directory dir) async {
    return p.basename(dir.path).replaceFirst("Proton", "").trim();
  }

  static String _getInternalProtonExecutablePath(Directory dir) {
    return p.join(dir.path, 'proton');
  }

  static String _getUmuDatabasePath() {
    return p.join(runtimeDirectory, 'umu_database.json');
  }

  static String _normalizeUmuName(String name) {
    return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static Future<_ProtonRuntimeUmuDatabaseEntry?> _queryUmuDatabase(
    ApplicationIdentity appIdentity,
  ) async {
    final umuDb = File(_getUmuDatabasePath());
    if (!await umuDb.exists()) {
      print('UMU database file does not exist at ${_getUmuDatabasePath()}. Skipping UMU query.');
      return null;
    }

    final List<dynamic> jsonList = jsonDecode(await umuDb.readAsString());
    final List<_ProtonRuntimeUmuDatabaseEntry> matches = [];
    final normalizedTrademarks = _normalizeUmuName(appIdentity.legalTrademarks);
    for (final item in jsonList) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final title = _normalizeUmuName(item["title"]);
      final store = item["store"];
      final id = item["umu_id"];

      if (title != _normalizeUmuName(appIdentity.name) &&
          !normalizedTrademarks.contains(title)) {
        continue;
      }

      final entry = _ProtonRuntimeUmuDatabaseEntry(
        title: title,
        store: store.trim(),
        id: id.trim(),
      );
      matches.add(entry);
    }

    final finalMatch = matches.firstWhereOrNull((e) => e.store == 'none');
    return finalMatch;
  }

  const ProtonRuntime._(super.identity, super.path);

  @override
  bool isCompatibleWith(ApplicationRuntimeIdentity appRuntimeIdentity)
      => appRuntimeIdentity.type == identity.type;

  @override
  Future<RuntimeLaunchInfo> getLaunchCommand(String appPath, PrefixIdentity prefixIdentity) async {
    String? umuDbEntryId;

    try {
      umuDbEntryId
        = prefixIdentity.readMetadata(_kMetaKeyRuntimeProtonUmuDbEntry) as String?
        ?? (await _queryUmuDatabase(prefixIdentity.identity))?.id;
    } catch (e) {
      print('(Proton Runtime) Failed to query UMU database for ${prefixIdentity.identity.name}: $e');
      umuDbEntryId = null;
      if (prefixIdentity.removeMetadata(_kMetaKeyRuntimeProtonUmuDbEntry)) {
        await PrefixManager.updatePrefix(prefixIdentity);
      }
    }

    if (umuDbEntryId != null) {
      print('(Proton Runtime) Found UMU database entry for ${prefixIdentity.identity.name}: $umuDbEntryId');
      if (prefixIdentity.writeMetadata(_kMetaKeyRuntimeProtonUmuDbEntry, umuDbEntryId)) {
        await PrefixManager.updatePrefix(prefixIdentity);
      }
    } else {
      print('(Proton Runtime) No UMU database entry found for ${prefixIdentity.identity.name}.');
    }

    return RuntimeLaunchInfo(
      command: ['umu-run', appPath],
      environment: {
        'WINEPREFIX': prefixIdentity.prefixPath,
        'PROTONPATH': path.path,
        'GAMEID': ?umuDbEntryId,
      },
      workingDirectory: File(appPath).parent.path,
    );
  }

  @override
  Future<void> createPrefix(Directory prefixPath) async {}
}

class _ProtonRuntimeUmuDatabaseEntry {
  final String title;
  final String store;
  final String id;

  const _ProtonRuntimeUmuDatabaseEntry({
    required this.title,
    required this.store,
    required this.id,
  });

  @override
  String toString() {
    return 'ProtonRuntimeUmuDatabaseEntry(title: $title, store: $store, id: $id)';
  }
}