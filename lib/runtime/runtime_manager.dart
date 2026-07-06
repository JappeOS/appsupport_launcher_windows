import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants.dart';
import 'application_runtime_identity.dart';
import 'runtime.dart';

sealed class RuntimeManager {
  static final List<Runtime> _runtimes = [];
  static final Map<ApplicationRuntimeIdentity, Runtime> _runtimesByIdentity = {};
  static Future<void>? _findRuntimesFuture;
  static bool _runtimesInitializing = false;

  /// Returns the runtime for the given application runtime identity,
  /// or null if it doesn't exist. Does not throw under regular circumstances.
  static Future<Runtime?> getRuntime(ApplicationRuntimeIdentity? runtimeIdentity) async {
    if (runtimeIdentity == null) {
      return null;
    }
    if (!_runtimesInitializing) {
      _findRuntimesFuture = _findRuntimes();
    }
    await _findRuntimesFuture;
    return _runtimesByIdentity[runtimeIdentity];
  }

  /// Returns a list of found runtimes.
  static Future<List<Runtime>> listRuntimes() async {
    if (!_runtimesInitializing) {
      _findRuntimesFuture = _findRuntimes();
    }
    await _findRuntimesFuture;
    return _runtimes;
  }

  /// Finds all runtimes installed on this system.
  static Future<void> _findRuntimes() async {
    _runtimesInitializing = true;
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

    for (final runtime in _runtimes) {
      print('Found runtime: ${runtime.identity.name} version ${runtime.identity.version} at ${runtime.path.path}');
    }
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
