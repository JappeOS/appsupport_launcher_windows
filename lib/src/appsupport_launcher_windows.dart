import 'dart:async';
import 'dart:io';

import 'application_identity.dart';
import 'constants.dart';
import 'gui_dialog.dart';
import 'lock.dart';
import 'prefix/prefix_identity.dart';
import 'prefix/prefix_manager.dart';
import 'process_runner.dart';
import 'runtime/runtime.dart';
import 'runtime/runtime_manager.dart';

/// A program that allows running Windows OS executables in a Linux-based OS.
sealed class AppSupportLauncherWindows {
  static bool _isRunning = false;
  static ProcessRunner? _currentProcess;

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

      final code = await _launchApp(readLaunchCommand(arguments).appPath);
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
    final waitForInitDialog = GuiDialog.progress("Launching Windows application...");
    Lock? prefixLock;

    Future<void> cleanup() async {
      await prefixLock?.tryClose();
      await waitForInitDialog.close();
    }

    Future<ProcessRunner> launch(
      Runtime runtime,
      String appPath,
      PrefixIdentity prefixIdentity,
    ) async {
      _currentProcess = await ProcessRunner.launch(runtime, appPath, prefixIdentity);
      return _currentProcess!;
    }

    Future<void> lock(ApplicationIdentity app) async {
      final prefixDir = Directory(getPrefixDirectoryForApp(app));
      await prefixDir.create(recursive: true);
      await prefixLock?.tryClose();
      prefixLock = await Lock.acquire(prefixDir);
    }

    try {
      // Return early if the executable to be launched does not exist.
      if (!await File(appPath).exists()) {
        throw Exception('Application executable not found at path: $appPath');
      }

      // Update runtimes.
      await RuntimeManager.updateRuntimesFromSources();

      // Return early if no runtimes are present on the system.
      final runtimes = await RuntimeManager.listRuntimes();
      if (runtimes.isEmpty) {
        throw Exception('No runtimes available to launch the application.');
      }

      // Read application identity data from the executable to be launched.
      // This is associated with a prefix later.
      final identity = await ApplicationIdentity.readFromExe(appPath);

      // Lock the prefix for the executable to be launched.
      await lock(identity);

      // Get existing prefix for app, or null if none exists.
      final prefixIdentity = await PrefixManager.getPrefixForExecutable(
        identity,
        appPath,
      );

      final runtime = await RuntimeManager.getRuntime(prefixIdentity?.runtimeIdentity);
      final hasNoOriginalPrefix = prefixIdentity == null;

      // If a prefix exists already, the app has been launched before, which
      // means that we will try to launch it with the same runtime as before.
      // If a prefix does not exist or the previously used runtime is not present,
      // we will try the available runtimes in the loop below.
      if (prefixIdentity != null && runtime != null) {
        // Launch the app normally, and return the exit code future.
        // If launch does not succeed, enter the loop below to try alternatives.
        print('Trying previously selected runtime $runtime...');
        final launched = await launch(runtime, appPath, prefixIdentity);
        if (launched.launchSuccess) {
          await cleanup();
          return (await launched.future)!;
        }
        print('Failed to launch app with previously selected runtime $runtime. Trying other compatible runtimes...');
      }

      // Try runtimes until the app launches with one of them.
      for (final runtime in runtimes) {
        try {
          // If an original prefix exists, only launch with runtimes that can
          // share the same prefix. We do NOT want to overwrite the user's prefix.
          if (!hasNoOriginalPrefix &&
              !runtime.isCompatibleWith(prefixIdentity.runtimeIdentity)) {
            print('Skipping runtime $runtime for compatibility reasons.');
            continue;
          }

          print('Trying runtime $runtime...');

          // If an original prefix did not exist, we will create a new one each
          // time, so we go through all installed runtimes to check which one
          // works for this app.
          // If an original prefix exists, but could not be launched with the
          // runtime it was last launched with, we will only overwrite metadata,
          // so that the new working runtime will be the new default, and all
          // prefix files are preserved.
          final prefix = hasNoOriginalPrefix
              ? await PrefixManager.createPrefix(
                  runtime,
                  identity,
                  CreatePrefixMode.overwriteAll,
                )
              : await PrefixManager.createPrefix(
                  runtime,
                  identity,
                  CreatePrefixMode.overwriteMetadata,
                );

          // Launch the app normally, and return the exit code future.
          // If launch does not succeed, try with another runtime at the next iteration.
          final launched = await launch(runtime, appPath, prefix);
          if (launched.launchSuccess) {
            await cleanup();
            return (await launched.future)!;
          }
          print('Failed to launch app with runtime $runtime: Launch command failed.');
        } catch (e) {
          print('Failed to launch app with runtime $runtime: $e');
        }
      }
    } finally {
      await cleanup();
    }

    // If no runtime was able to start the app:
    final errorString = 'Failed to launch app with any available runtime. Please ensure that a compatible runtime is installed and try again.';
    print(errorString);
    await GuiDialog.error(errorString).result();
    return 1;
  }

  /// Forward signals to compat-launched executable.
  static void _handleQuitSignal(ProcessSignal signal) {
    _currentProcess?.kill(signal);
  }
}