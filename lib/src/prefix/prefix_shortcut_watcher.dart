import 'dart:async';

import 'package:watcher/watcher.dart';

/// Serializes shortcut scans after prefix changes and once more at shutdown.
class PrefixShortcutWatcher {
  final DirectoryWatcher _watcher;
  final Future<bool> Function() _scan;
  final void Function(Object) _onError;
  final Duration debounce;

  StreamSubscription<WatchEvent>? _subscription;
  Timer? _timer;
  Future<void>? _running;
  bool _pending = false;
  bool _stopped = false;
  bool _complete = false;

  PrefixShortcutWatcher(
    String path, {
    required Future<bool> Function() scan,
    required void Function(Object) onError,
    this.debounce = const Duration(milliseconds: 300),
  }) : _watcher = DirectoryWatcher(path),
       _scan = scan,
       _onError = onError;

  Future<void> start() async {
    _subscription = _watcher.events.listen((event) {
      // Any event can follow a shortcut creation, including unrelated writes.
      // Do not let the final event in a burst determine whether we scan.
      if (_stopped || _complete) return;
      _timer?.cancel();
      _timer = Timer(debounce, () {
        _pending = true;
        unawaited(_drain());
      });
    }, onError: (Object error) => _onError(error));
    await _watcher.ready;
    _pending = true;
    await _drain();
  }

  Future<void> _drain() {
    if (_running != null) return _running!;
    // Schedule the work so _running is assigned before the scan can finish.
    return _running = Future(() async {
      try {
        while (_pending && !_complete) {
          _pending = false;
          try {
            _complete = await _scan();
          } catch (error) {
            _onError(error);
          }
          if (_complete) {
            _timer?.cancel();
            // Cancel notifications without waiting on our own scan future.
            await _subscription?.cancel();
            _subscription = null;
          }
        }
      } finally {
        _running = null;
      }
    });
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await _running;
    // The process can exit before the debounce fires or the watcher delivers
    // its final event. Scan the filesystem itself before shutting down.
    _pending = true;
    await _drain();
  }
}
