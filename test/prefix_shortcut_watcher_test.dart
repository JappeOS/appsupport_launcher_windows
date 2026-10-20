import 'dart:async';
import 'dart:io';

import 'package:appsupport_launcher_windows/src/prefix/prefix_shortcut_watcher.dart';
import 'package:test/test.dart';

void main() {
  late Directory prefix;
  late File shortcut;
  late PrefixShortcutWatcher watcher;
  late List<Object> errors;

  setUp(() async {
    prefix = await Directory.systemTemp.createTemp('prefix-watcher-test-');
    shortcut = File(
      '${prefix.path}/drive_c/ProgramData/Microsoft/Windows/'
      'Start Menu/Programs/Notepad++.lnk',
    );
    await shortcut.parent.create(recursive: true);
    errors = [];
  });

  tearDown(() async {
    await watcher.stop().timeout(const Duration(seconds: 5));
    await prefix.delete(recursive: true);
    expect(errors, isEmpty);
  });

  test('finds shortcuts already present when watching starts', () async {
    await shortcut.writeAsString('ready');
    var found = false;
    watcher = PrefixShortcutWatcher(
      prefix.path,
      scan: () async {
        found = await shortcut.exists();
        return found;
      },
      onError: errors.add,
    );
    await watcher.start();
    expect(found, isTrue);
  });

  test('rescans modified shortcuts after unrelated writes', () async {
    await shortcut.writeAsString('incomplete');
    final found = Completer<void>();
    watcher = PrefixShortcutWatcher(
      prefix.path,
      scan: () async {
        if (await shortcut.readAsString() != 'ready') return false;
        if (!found.isCompleted) found.complete();
        return true;
      },
      onError: errors.add,
    );
    await watcher.start();
    await shortcut.writeAsString('ready');
    await File('${prefix.path}/user.reg').writeAsString('registry update');
    await found.future.timeout(const Duration(seconds: 5));
    // Successful scans must also allow shutdown to finish without deadlocking.
    await watcher.stop().timeout(const Duration(seconds: 5));
  });

  test('scans newly created Start Menu directories', () async {
    await shortcut.parent.delete(recursive: true);
    final found = Completer<void>();
    watcher = PrefixShortcutWatcher(
      prefix.path,
      scan: () async {
        if (!await shortcut.exists()) return false;
        if (!found.isCompleted) found.complete();
        return true;
      },
      onError: errors.add,
    );
    await watcher.start();
    await shortcut.parent.create(recursive: true);
    await shortcut.writeAsString('ready');
    await found.future.timeout(const Duration(seconds: 5));
  });

  test('flushes changes on exit before debounce fires', () async {
    var found = false;
    watcher = PrefixShortcutWatcher(
      prefix.path,
      scan: () async {
        found = await shortcut.exists();
        return found;
      },
      onError: errors.add,
      debounce: const Duration(minutes: 1),
    );
    await watcher.start();
    await shortcut.writeAsString('ready');
    await watcher.stop().timeout(const Duration(seconds: 5));
    expect(found, isTrue);
  });

  test(
    'shutdown waits for an active scan then performs a final scan',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var scans = 0;
      var active = 0;
      watcher = PrefixShortcutWatcher(
        prefix.path,
        scan: () async {
          expect(++active, 1);
          scans++;
          if (scans == 1) {
            entered.complete();
            await release.future;
          }
          active--;
          return false;
        },
        onError: errors.add,
      );
      final starting = watcher.start();
      await entered.future;
      final stopping = watcher.stop();
      release.complete();
      await Future.wait([starting, stopping]);
      expect(scans, 2);
    },
  );
}
