import 'dart:io';

import 'package:path/path.dart' as p;

class Lock {
  static Future<Lock> acquire(Directory dir) async {
    final inst = Lock._(dir);
    await inst._open();
    return inst;
  }

  final Directory dir;
  RandomAccessFile? _raf;

  Lock._(this.dir);

  Future<void> _open() async {
    if (_raf != null) {
      throw StateError("Cannot open lock: lock is already opened.");
    }

    final file = File(p.join(dir.path, ".lock"));
    await file.create(recursive: true);
    _raf = await file.open(mode: FileMode.write);
    await _raf!.lock();
  }

  Future<void> close() async {
    if (_raf == null) {
      throw StateError("Cannot close lock: lock is not opened.");
    }

    await _raf!.unlock();
    await _raf!.close();
    _raf = null;
  }

  Future<bool> tryClose() async {
    try {
      await close();
    } catch (e) {
      return false;
    }
    return true;
  }
}