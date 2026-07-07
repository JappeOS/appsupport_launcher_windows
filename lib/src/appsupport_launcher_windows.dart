import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appsupport_launcher_windows/src/gui_dialog.dart';

import 'application_identity.dart';
import 'constants.dart';
import 'lock.dart';
import 'prefix/prefix_manager.dart';
import 'runtime/runtime.dart';
import 'runtime/runtime_manager.dart';

/// A program that allows running Windows OS executables in a Linux-based OS.
sealed class AppSupportLauncherWindows {
  static bool _isRunning = false;
  static Process? _currentProcess;

  /// Main method that runs the entire application launcher.
  static Future<int> main(List<String> arguments) async {
    if (_isRunning) {
      throw StateError("Main method already called and running.");
    }
    _isRunning = true;

    List<StreamSubscription<ProcessSignal>>? subs;
    try {
      _currentProcess = null;

      if (arguments.isEmpty) {
        throw Exception('No application path provided. Please provide the path to the application executable.');
      }

      subs = [
        ProcessSignal.sigint.watch().listen(_handleQuitSignal),
        ProcessSignal.sigterm.watch().listen(_handleQuitSignal),
      ];

      final code = await _launchApp(arguments[0]);
      print("Application or child exiting with code: $code");
      return code;
    } catch (e, stackTrace) {
      final errorString = 'Error launching application: $e: \n$stackTrace';

      stderr.writeln(errorString);
      await GuiDialog.error(errorString).result();

      print("Application exiting with code: 1");
      return 1;
    } finally {
      for (final sub in subs ?? []) {
        sub.cancel();
      }
      _isRunning = false;
    }
  }

  /// Launches a program by path. The program must exist and be a valid executable.
  /// Returns the exit code of this or the child app process.
  static Future<int> _launchApp(String appPath) async {
    final waitForInitDialog = GuiDialog.progress("Launching Windows Application...");
    Lock? prefixLock;
    try {
      if (!await File(appPath).exists()) {
        throw Exception('Application executable not found at path: $appPath');
      }

      final runtimes = await RuntimeManager.listRuntimes();
      if (runtimes.isEmpty) {
        throw Exception('No runtimes available to launch the application.');
      }

      final identity = await ApplicationIdentity.readFromExe(appPath);

      {
        final prefixDir = Directory(getPrefixDirectoryForApp(identity));
        if (await prefixDir.exists()) {
          prefixLock = await Lock.acquire(prefixDir);
        }
      }

      final prefixIdentity = await PrefixManager.getPrefix(identity);
      final runtime = await RuntimeManager.getRuntime(prefixIdentity?.runtimeIdentity);
      bool needsCreatePrefix = prefixIdentity == null;

      if (prefixIdentity != null && runtime != null) {
        final command = await runtime.getLaunchCommand(appPath, prefixIdentity);
        final launch = await _launch(command);
        if (launch.$1) {
          await prefixLock?.close();
          await waitForInitDialog.close();
          return await launch.$2!.exitCode;
        }
        print('Failed to launch app with runtime ${runtime.identity.name} version ${runtime.identity.version}. Trying other compatible runtimes...');
      }

      // TODO: Write new working runtime to prefix data, so it's picked first the
      //       next time.
      for (final runtime in runtimes) {
        print('Trying runtime ${runtime.identity.name} version ${runtime.identity.version}...');
        try {
          if (prefixIdentity != null &&
              !runtime.isCompatibleWith(prefixIdentity.runtimeIdentity)) {
            continue;
          }
          final prefix = needsCreatePrefix
              ? await PrefixManager.createPrefix(runtime, identity, true)
              : prefixIdentity;
          final command = await runtime.getLaunchCommand(appPath, prefix);
          final launch = await _launch(command);
          if (launch.$1) {
            await prefixLock?.close();
            await waitForInitDialog.close();
            return await launch.$2!.exitCode;
          }
          print('Failed to launch app with runtime ${runtime.identity.name} version ${runtime.identity.version}: Launch command failed.');
        } catch (e) {
          print('Failed to launch app with runtime ${runtime.identity.name} version ${runtime.identity.version}: $e');
        }
      }
    } finally {
      await prefixLock?.tryClose();
      await waitForInitDialog.close();
    }

    final errorString = 'Failed to launch app with any available runtime. Please ensure that a compatible runtime is installed and try again.';
    print(errorString);
    await GuiDialog.error(errorString).result();
    return 1;
  }

  /// Performs the launch operation of an app, based on a [RuntimeLaunchInfo]
  /// object. Returns true if launch succeeded, otherwise false. Should
  /// never throw.
  static Future<(bool, Process?)> _launch(RuntimeLaunchInfo launchInfo) async {
    print('Launching app with command ${launchInfo.command}.');
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

        process.stdout
            .transform(utf8.decoder)
            .forEach(stdout.write);

        process.stderr
            .transform(utf8.decoder)
            .forEach(stderr.write);

        exitCode = await process.exitCode.timeout(Duration(seconds: 10));
      } on TimeoutException {
        _currentProcess = process!;
        return (true, process);
      }

      final stdoutRes = await process.stdout.transform(utf8.decoder).join();
      final stderrRes = await process.stderr.transform(utf8.decoder).join();
      if (exitCode != 0 && _isCompatToolFailure(exitCode, stdoutRes, stderrRes)) {
        throw Exception('App exited with code $exitCode.');
      }
    } on ProcessException catch (e) {
      print('Failed to launch app with command ${launchInfo.command}: Invalid runtime executable: $e');
      return (false, null);
    } catch (e) {
      print('Failed to launch app with command ${launchInfo.command}: $e');
      return (false, null);
    }
    _currentProcess = process;
    return (true, process);
  }

  // TODO
  static bool _isCompatToolFailure(int exitCode, String stdout, String stderr) {
    return false;
  }

  static void _handleQuitSignal(ProcessSignal signal) {
    _currentProcess?.kill(signal);
  }
}