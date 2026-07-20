import 'dart:io';

enum Architecture { x86_64, arm64, unknown }

Architecture? _cached;

Future<Architecture> _detectArchitecture() async {
  if (!Platform.isLinux) {
    throw UnsupportedError('This tool only supports Linux');
  }

  final result = await Process.run('uname', ['-m']);
  if (result.exitCode != 0) {
    // Fall back to the safe default rather than crashing
    return Architecture.x86_64;
  }

  final machine = (result.stdout as String).trim().toLowerCase();

  switch (machine) {
    case 'x86_64':
    case 'amd64':
      return Architecture.x86_64;
    case 'aarch64':
    case 'arm64':
      return Architecture.arm64;
    default:
      // Unknown/exotic arch (e.g. armv7, riscv64) -> default to x86_64
      return Architecture.x86_64;
  }
}

Future<Architecture> getArchitecture() async {
  if (_cached != null) {
    return _cached!;
  }
  _cached = await _detectArchitecture();
  return _cached!;
}