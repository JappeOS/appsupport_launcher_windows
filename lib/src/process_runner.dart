import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'prefix/prefix_desktop_entry.dart';
import 'prefix/prefix_identity.dart';
import 'prefix/prefix_manager.dart';
import 'runtime/runtime.dart';

/// Handles the lifecycle of a running compatibility-tool hosted process.
class ProcessRunner {
  static const _kTimeout = Duration(seconds: 4);

  /// Performs the launch operation of an app. [runtime] is the runtime used
  /// to launch the app. [appPath] is the path to the executable to be launched
  /// with a compatibility tool. [prefixIdentity] is the prefix to launch this
  /// application in.
  static Future<ProcessRunner> launch(
    Runtime runtime,
    String appPath,
    PrefixIdentity prefixIdentity,
  ) async {
    final launchInfo = await runtime.getLaunchCommand(appPath, prefixIdentity);
    final stopwatch = Stopwatch();

    print('Launching app with command ${launchInfo.command}.');

    ProcessRunner ret(bool success, Process? process)
        => ProcessRunner._(success, process, runtime, prefixIdentity);

    Process? process;
    try {
      int? exitCode;
      try {
        process = await Process.start(
          launchInfo.command.first,
          launchInfo.command.skip(1).toList(),
          environment: launchInfo.environment,
          workingDirectory: launchInfo.workingDirectory,
          mode: ProcessStartMode.normal,
        );

        stopwatch.start();

        process.stdout
            .transform(utf8.decoder)
            .forEach(stdout.write);

        process.stderr
            .transform(utf8.decoder)
            .forEach(stderr.write);

        exitCode = await process.exitCode.timeout(_kTimeout);
      } on TimeoutException {
        stopwatch.stop();
        return ret(true, process);
      }

      stopwatch.stop();
      final stdoutRes = await process.stdout.transform(utf8.decoder).join();
      final stderrRes = await process.stderr.transform(utf8.decoder).join();
      if (exitCode != 0 && _isCompatToolFailure(exitCode, stdoutRes, stderrRes, stopwatch.elapsed)) {
        throw Exception('App exited with code $exitCode.');
      }
    } on ProcessException catch (e) {
      print('Failed to launch app with command ${launchInfo.command}: Invalid runtime executable: $e');
      return ret(false, null);
    } catch (e) {
      print('Failed to launch app with command ${launchInfo.command}: $e');
      return ret(false, null);
    }

    return ret(true, process);
  }

  // TODO: More better checks
  static bool _isCompatToolFailure(
    int exitCode,
    String stdout,
    String stderr,
    Duration runTime,
  ) {
    if (runTime < const Duration(seconds: 1)) {
      return true;
    }

    final toolFailMessage = 'Compatibility tool failed';
    return stdout.toLowerCase().contains(toolFailMessage.toLowerCase()) ||
        stderr.toLowerCase().contains(toolFailMessage.toLowerCase());
  }

  final bool launchSuccess;
  final Process? _process;
  final Runtime _runtime;
  final PrefixIdentity _prefix;
  late final Future<int?> _future;

  Future<int?> get future => _future;

  ProcessRunner._(
    this.launchSuccess,
    this._process,
    this._runtime,
    this._prefix,
  ) : assert(!launchSuccess || _process == null) {
    _future = _exitCode();
  }

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_process == null) {
      return false;
    }
    return _process.kill(signal);
  }

  Future<int?> _exitCode() async {
    final res = await _process?.exitCode;
    await _handleCleanup();
    return res;
  }

  Future<void> _handleCleanup() async {
    if (await PrefixManager.getDesktopEntry(_prefix) != null) {
      return;
    }

    final pathResolver = _runtime.pathResolver;
    Map<File, File> executablesToSourceLnk = {};
    await for (final ent in Directory(_prefix.prefixPath)
        .list(recursive: true, followLinks: false)
        .handleError((_) {})) {
      if (ent is File && p.extension(ent.path) == '.lnk') {
        try {
          final data = await PrefixDesktopEntry.readSourceFile(
            ent,
            pathResolver,
            _prefix,
          );
          executablesToSourceLnk[data.executableFile] = ent;
        } catch (e) {
          print("Desktop file generation: Skipping invalid lnk file: ${ent.path}");
        }
      }
    }

    if (executablesToSourceLnk.isEmpty) {
      return;
    }

    final first = (await _rankExecutables(executablesToSourceLnk.keys.toList())).first;
    try {
      await PrefixManager.updateDesktopEntry(
        _prefix,
        executablesToSourceLnk[first]!,
        pathResolver,
      );
    } on Exception catch (e) {
      print("Desktop file generation: Failed to create desktop entry for prefix: $e");
    }
  }

  Future<List<File>> _rankExecutables(List<File> files) async {
    const badWords = [
      'uninstall',
      'unins',
      'setup',
      'installer',
      'install',
      'update',
      'updater',
      'patch',
      'repair',
      'modify',
      'remove',
      'vc_redist',
      'vcredist',
      'dxsetup',
    ];

    final scored = <_ScoredExe>[];

    for (final file in files) {
      final stat = await file.stat();

      double score = 0;

      // Newer is better.
      score += stat.modified.millisecondsSinceEpoch / 1e12;

      // Larger is better.
      score += stat.size / 1e7;

      // Penalize common installer/uninstaller names.
      final lower = p.basename(file.path).toLowerCase();
      if (badWords.any(lower.contains)) {
        score -= 1000;
      }

      // Check if path is in program files
      final path = file.path.toLowerCase();
      if (path.contains('/program files/')) {
        score += 100;
      }
      if (path.contains('/program files (x86)/')) {
        score += 100;
      }

      scored.add(_ScoredExe(file, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored.map((e) => e.file).toList();
  }
}

class _ScoredExe {
  final File file;
  final double score;

  const _ScoredExe(this.file, this.score);
}