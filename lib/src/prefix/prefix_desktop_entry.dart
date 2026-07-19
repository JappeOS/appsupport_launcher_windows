import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../runtime/runtime.dart';
import 'prefix_identity.dart';

sealed class PrefixDesktopEntry {
  static Future<PrefixDesktopEntryWriteResult> write(
    File sourceLnk,
    RuntimePathResolver pathResolver,
    PrefixIdentity prefix,
  ) async {
    final sourceData = await readSourceFile(sourceLnk, pathResolver, prefix);

    File? icon;
    try {
      final iconDir = Directory(p.join(prefix.prefixPath, 'cached_desktop_icon'));
      await iconDir.create();
      icon = await _IconExtractor.extractIcon(
        filePath: sourceData.executableFile.path,
        iconIndex: sourceData.iconIndex,
        outputDir: iconDir,
      );
    } catch (e) {
      print("Icon extraction for desktop entry failed: $e");
    }

    final deEntry = await writeDesktopEntry(sourceData: sourceData, icon: icon);
    return PrefixDesktopEntryWriteResult(
      desktopEntry: deEntry,
      icon: icon,
    );
  }

  static Future<PrefixDesktopEntrySourceData> readSourceFile(
    File sourceLnk,
    RuntimePathResolver pathResolver,
    PrefixIdentity prefix,
  ) async {
    const resultTimeout = Duration(minutes: 1);
    final result = await Process.run('exiftool', ['-j', sourceLnk.path])
        .timeout(resultTimeout, onTimeout: () {
          throw TimeoutException('Failed to read lnk file from ${sourceLnk.path}: exiftool timed out.', resultTimeout);
        });

    if (result.exitCode != 0) {
      throw Exception('Failed to read lnk file from ${sourceLnk.path}: ${result.stderr}');
    }

    final json = jsonDecode(result.stdout as String) as List;
    final jsonMap = json.first as Map<String, dynamic>;

    final name = (jsonMap['FileName'] as String).trim().replaceFirst('.lnk', "");
    if (name.isEmpty) {
      throw Exception('Empty lnk filename');
    }

    final localBasePath = (jsonMap['LocalBasePath'] as String? ?? "").trim();
    final targetFileDosName = (jsonMap['TargetFileDOSName'] as String? ?? "").trim();
    final relativePath = (jsonMap['RelativePath'] as String? ?? "").trim();

    final workdirPath = (jsonMap['WorkingDirectory'] as String? ?? "").trim();

    int iconIndex;
    try {
      iconIndex = (jsonMap['IconIndex'] as int? ?? 0);
    } catch (e) {
      iconIndex = 0;
    }

    String finalPath = "";
    if (localBasePath.isEmpty) {
      if (targetFileDosName.isEmpty) {
        finalPath = pathResolver.toolPathResolveRelativeToNative(
          relativePath,
          sourceLnk.parent.path,
          prefix,
        ) ?? pathResolver.toolPathResolveRelativeToNative(
          relativePath,
          workdirPath,
          prefix,
        ) ?? "";
      } else {
        finalPath = pathResolver.toolPathResolveRelativeToNative(
          targetFileDosName,
          sourceLnk.parent.path,
          prefix,
        ) ?? pathResolver.toolPathResolveRelativeToNative(
          targetFileDosName,
          workdirPath,
          prefix,
        ) ?? "";
      }
    } else {
      finalPath = pathResolver.toolPathToNative(localBasePath, prefix) ?? "";
    }

    if (finalPath.trim().isEmpty) {
      throw Exception('Failed to find executable path of lnk file');
    }

    if (p.extension(finalPath) != '.exe') {
      throw Exception('Invalid executable path on lnk file');
    }

    final description = (jsonMap['Description'] as String? ?? "").trim();
    return PrefixDesktopEntrySourceData(
      executableFile: File(finalPath),
      name: name,
      description: description,
      iconIndex: iconIndex,
    );
  }

  /// Writes a valid freedesktop.org `.desktop` entry for [sourceData] and,
  /// if provided, an [icon] file.
  ///
  /// - Uses `writeLaunchCommand` (returns `Future<List<String>>`) and quotes
  ///   the resulting argv correctly for the `Exec=` key, per the Desktop
  ///   Entry Specification's quoting rules.
  /// - Escapes reserved characters in `Name=`/`Comment=`/`Icon=`.
  /// - Sanitizes the entry's filename.
  /// - Marks the resulting file executable (best-effort; required by some
  ///   desktop environments, e.g. GNOME/Nautilus, before they'll trust and
  ///   launch a `.desktop` file).
  static Future<File> writeDesktopEntry({
    required PrefixDesktopEntrySourceData sourceData,
    File? icon,
  }) async {
    final String rawName = sourceData.name;
    final String description = sourceData.description;
    final String executablePath = sourceData.executableFile.path;

    if (rawName.trim().isEmpty) {
      throw DesktopEntryException('sourceData.name must not be empty');
    }

    final desktopDir = getDesktopEntryDirectory();
    final fileName = '${_sanitizeFileName(rawName)}.desktop';
    final deEntry = File(p.join(desktopDir, fileName));

    final List<String> execArgv;
    try {
      execArgv = await writeLaunchCommand(LaunchCommand(executablePath));
    } catch (e) {
      throw DesktopEntryException('Failed to build launch command', e);
    }

    if (execArgv.isEmpty) {
      throw DesktopEntryException(
          'writeLaunchCommand returned an empty argument list');
    }

    final buffer = StringBuffer()
      ..writeln('[Desktop Entry]')
      ..writeln('Version=1.0')
      ..writeln('Type=Application')
      ..writeln('Name=${_escapeDesktopString(rawName)}')
      ..writeln('Exec=${_buildExecValue(execArgv)}')
      ..writeln('Terminal=false');

    if (description.trim().isNotEmpty) {
      buffer.writeln('Comment=${_escapeDesktopString(description)}');
    }

    if (icon != null) {
      buffer.writeln('Icon=${_escapeDesktopString(icon.path)}');
    }

    try {
      await deEntry.parent.create(recursive: true);
      await deEntry.writeAsString(buffer.toString(), flush: true);
    } catch (e) {
      throw DesktopEntryException(
          'Failed to write desktop entry to ${deEntry.path}', e);
    }

    await _makeExecutable(deEntry);

    return deEntry;
  }

  /// Replaces characters that are unsafe or ambiguous in a filename
  /// (path separators, control characters, null bytes) with `_`, and
  /// trims surrounding whitespace/dots.
  static String _sanitizeFileName(String name) {
    var sanitized = name.trim().replaceAll(RegExp(r'[\\/\x00-\x1F]'), '_');
    // Avoid leading dots (hidden files) or empty results after trimming.
    sanitized = sanitized.replaceFirst(RegExp(r'^\.+'), '');
    if (sanitized.isEmpty) {
      throw DesktopEntryException(
          'sourceData.name did not contain any valid filename characters');
    }
    return sanitized;
  }

  /// Escapes a plain "string" type value per the Desktop Entry Specification:
  /// backslash, newline, tab, and carriage return must be represented via
  /// their escape sequences.
  static String _escapeDesktopString(String input) {
    return input
        .replaceAll('\\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }

  /// Characters that, per the spec, require an Exec argument to be wrapped
  /// in double quotes if present.
  static const _execReservedChars = [
    ' ', '\t', '\n', '"', "'", '\\', '>', '<', '~', '|', '&',
    ';', r'$', '*', '?', '#', '(', ')', '`',
  ];

  /// Quotes/escapes a single argv entry for use inside an `Exec=` value.
  ///
  /// Rules (Desktop Entry Specification):
  /// - Backslashes are always escaped as `\\` first.
  /// - If the argument contains any reserved character, the whole argument
  ///   is wrapped in double quotes, and `"`, `` ` ``, and `$` are escaped
  ///   with a backslash inside the quotes.
  static String _quoteExecArg(String arg) {
    if (arg.isEmpty) return '""';

    final needsQuoting = _execReservedChars.any(arg.contains);

    // Backslash escaping must happen first, before other escapes are added.
    var value = arg.replaceAll('\\', r'\\');

    if (needsQuoting) {
      value = value
          .replaceAll('"', r'\"')
          .replaceAll(r'$', r'\$')
          .replaceAll('`', r'\`');
      return '"$value"';
    }

    return value;
  }

  /// Joins a quoted argv into the final `Exec=` value.
  static String _buildExecValue(List<String> argv) {
    return argv.map(_quoteExecArg).join(' ');
  }

  /// Best-effort chmod +x. Desktop entry "trust" semantics vary by desktop
  /// environment/distro, but making the file executable is required by some
  /// (e.g. GNOME/Nautilus) before the entry will be launched without a
  /// security prompt. Failures here are non-fatal.
  static Future<void> _makeExecutable(File file) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;

    try {
      final result = await Process.run('chmod', ['755', file.path]);
      if (result.exitCode != 0) {
        stderr.writeln(
            'Warning: failed to chmod +x ${file.path}: ${result.stderr}');
      }
    } catch (e) {
      stderr.writeln('Warning: failed to chmod +x ${file.path}: $e');
    }
  }
}

class PrefixDesktopEntrySourceData {
  final File executableFile;
  final String name;
  final String description;
  final int iconIndex;

  const PrefixDesktopEntrySourceData({
    required this.executableFile,
    required this.name,
    required this.description,
    required this.iconIndex,
  });
}

class PrefixDesktopEntryWriteResult {
  final File desktopEntry;
  final File? icon;

  const PrefixDesktopEntryWriteResult({
    required this.desktopEntry,
    required this.icon,
  });
}

/// Thrown when a desktop entry could not be written for some reason.
class DesktopEntryException implements Exception {
  DesktopEntryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'DesktopEntryException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// Minimal PE (.exe/.dll) resource-section reader, used to pull RT_ICON (3)
/// and RT_GROUP_ICON (14) resources directly, bypassing wrestool/icotool -
/// both of which trust a "bytes in resource" field that can be stale/wrong
/// in some (e.g. Electron-repackaged) executables.
class _PeResourceReader {
  final Uint8List bytes;
  late final ByteData bd;
  late final int numberOfSections;
  late final int sectionsOffset;
  late final int resourceRva;
  late final int resourceSize;

  _PeResourceReader(this.bytes) {
    bd = ByteData.sublistView(bytes);
    if (bytes.length < 0x40 || bytes[0] != 0x4D || bytes[1] != 0x5A) {
      throw Exception('Not a valid PE file (missing MZ header)');
    }
    final peOffset = bd.getUint32(0x3C, Endian.little);
    if (bytes.length < peOffset + 24 ||
        bd.getUint32(peOffset, Endian.little) != 0x00004550) {
      throw Exception('Not a valid PE file (missing PE header)');
    }

    numberOfSections = bd.getUint16(peOffset + 6, Endian.little);
    final optionalHeaderSize = bd.getUint16(peOffset + 20, Endian.little);
    final optHeaderOffset = peOffset + 24;
    final magic = bd.getUint16(optHeaderOffset, Endian.little);

    final dataDirOffset =
        optHeaderOffset + (magic == 0x20b ? 112 : 96); // PE32+ vs PE32

    // DataDirectory[2] = Resource Table
    final resourceDirEntryOffset = dataDirOffset + 2 * 8;
    resourceRva = bd.getUint32(resourceDirEntryOffset, Endian.little);
    resourceSize = bd.getUint32(resourceDirEntryOffset + 4, Endian.little);

    sectionsOffset = optHeaderOffset + optionalHeaderSize;

    if (resourceRva == 0 || resourceSize == 0) {
      throw Exception('PE file has no resource section');
    }
  }

  int _rvaToOffset(int rva) {
    for (var i = 0; i < numberOfSections; i++) {
      final base = sectionsOffset + i * 40;
      final virtualSize = bd.getUint32(base + 8, Endian.little);
      final virtualAddress = bd.getUint32(base + 12, Endian.little);
      final sizeOfRawData = bd.getUint32(base + 16, Endian.little);
      final pointerToRawData = bd.getUint32(base + 20, Endian.little);

      final size = virtualSize != 0 ? virtualSize : sizeOfRawData;
      if (rva >= virtualAddress && rva < virtualAddress + size) {
        return pointerToRawData + (rva - virtualAddress);
      }
    }
    throw Exception('RVA $rva not found in any section');
  }

  /// Returns every resource of [typeId] (3=RT_ICON, 14=RT_GROUP_ICON),
  /// keyed by numeric resource id, with their REAL byte length.
  Map<int, Uint8List> getResourcesOfType(int typeId) {
    final resBase = _rvaToOffset(resourceRva);
    final result = <int, Uint8List>{};

    int u16(int off) => bd.getUint16(off, Endian.little);
    int u32(int off) => bd.getUint32(off, Endian.little);

    final topTotal = u16(resBase + 12) + u16(resBase + 14);

    int? typeDirRelOffset;
    for (var i = 0; i < topTotal; i++) {
      final entryOff = resBase + 16 + i * 8;
      final name = u32(entryOff);
      if ((name & 0x80000000) != 0) continue; // named, not numeric - skip
      final offsetToData = u32(entryOff + 4);
      if (name == typeId && (offsetToData & 0x80000000) != 0) {
        typeDirRelOffset = offsetToData & 0x7FFFFFFF;
        break;
      }
    }
    if (typeDirRelOffset == null) return result;

    final nameDirOffset = resBase + typeDirRelOffset;
    final nameTotal = u16(nameDirOffset + 12) + u16(nameDirOffset + 14);

    for (var i = 0; i < nameTotal; i++) {
      final entryOff = nameDirOffset + 16 + i * 8;
      final name = u32(entryOff);
      if ((name & 0x80000000) != 0) continue; // named - skip
      final offsetToData = u32(entryOff + 4);
      if ((offsetToData & 0x80000000) == 0) continue; // malformed

      final langDirOffset = resBase + (offsetToData & 0x7FFFFFFF);
      final langTotal = u16(langDirOffset + 12) + u16(langDirOffset + 14);
      if (langTotal == 0) continue;

      // Take the first language variant.
      final leafOffsetToData = u32(langDirOffset + 16 + 4);
      if ((leafOffsetToData & 0x80000000) != 0) continue;

      final dataEntryOffset = resBase + leafOffsetToData;
      final dataRva = u32(dataEntryOffset);
      final dataSize = u32(dataEntryOffset + 4); // REAL size, trustworthy

      final fileOffset = _rvaToOffset(dataRva);
      if (fileOffset + dataSize > bytes.length) continue;

      result[name] = bytes.sublist(fileOffset, fileOffset + dataSize);
    }

    return result;
  }
}

sealed class _IconExtractor {
  static Future<File?> extractIcon({
    required String filePath,
    int iconIndex = 0,
    required Directory outputDir,
  }) async {
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    Future<void> clearIcons([File? but]) async {
      await for (final ent in outputDir.list()) {
        if (ent is File && ent.path != but?.path) {
          await ent.delete();
        }
      }
    }

    await clearIcons();

    final lower = filePath.toLowerCase();

    try {
      List<int>? icoBytes;

      if (lower.endsWith('.ico')) {
        icoBytes = await File(filePath).readAsBytes();
      } else if (lower.endsWith('.exe') || lower.endsWith('.dll')) {
        icoBytes = await _extractIcoBytesFromPe(
          filePath: filePath,
          iconIndex: iconIndex,
        );
      } else {
        return null;
      }

      if (icoBytes == null || icoBytes.isEmpty) return null;

      final pngFile = await _decodeIcoToLargestPng(
        icoBytes: icoBytes,
        outputDir: outputDir,
      );

      await clearIcons(pngFile);
      return pngFile;
    } catch (e) {
      await clearIcons();
      rethrow;
    }
  }

  static Future<List<int>?> _extractIcoBytesFromPe({
    required String filePath,
    required int iconIndex,
  }) async {
    final peBytes = await File(filePath).readAsBytes();
    final reader = _PeResourceReader(peBytes);

    final groupIcons = reader.getResourcesOfType(14); // RT_GROUP_ICON
    final icons = reader.getResourcesOfType(3); // RT_ICON
    if (groupIcons.isEmpty || icons.isEmpty) return null;

    final groupIds = groupIcons.keys.toList()..sort();

    final selectedGroupId = iconIndex < 0
        ? (groupIds.contains(-iconIndex) ? -iconIndex : groupIds.first)
        : (iconIndex < groupIds.length
            ? groupIds[iconIndex]
            : groupIds.first);

    return _buildIcoFromGroupIcon(groupIcons[selectedGroupId]!, icons);
  }

  /// Hand-assembles a standard .ico from a raw RT_GROUP_ICON resource plus
  /// its referenced RT_ICON resources, using each RT_ICON's REAL extracted
  /// length rather than the group's declared (possibly stale) size field.
  static List<int>? _buildIcoFromGroupIcon(
    Uint8List grpBytes,
    Map<int, Uint8List> icons,
  ) {
    final gbd = ByteData.sublistView(grpBytes);
    if (gbd.getUint16(2, Endian.little) != 1) return null; // idType
    final count = gbd.getUint16(4, Endian.little);
    if (count == 0) return null;

    final images = <Uint8List>[];
    final meta = <List<int>>[]; // [width, height, colorCount, reserved, planes, bitCount]

    for (var i = 0; i < count; i++) {
      final base = 6 + i * 14; // GRPICONDIRENTRY = 14 bytes
      if (base + 14 > grpBytes.length) break;

      final width = grpBytes[base];
      final height = grpBytes[base + 1];
      final colorCount = grpBytes[base + 2];
      final reserved = grpBytes[base + 3];
      final planes = gbd.getUint16(base + 4, Endian.little);
      final bitCount = gbd.getUint16(base + 6, Endian.little);
      final nId = gbd.getUint16(base + 12, Endian.little);
      // dwBytesInRes at base+8 intentionally ignored - unreliable.

      final iconData = icons[nId];
      if (iconData == null) continue;

      images.add(iconData);
      meta.add([width, height, colorCount, reserved, planes, bitCount]);
    }

    if (images.isEmpty) return null;

    final out = BytesBuilder();

    final header = ByteData(6);
    header.setUint16(2, 1, Endian.little); // idType = icon
    header.setUint16(4, images.length, Endian.little);
    out.add(header.buffer.asUint8List());

    var dataOffset = 6 + images.length * 16;
    for (var i = 0; i < images.length; i++) {
      final m = meta[i];
      final realSize = images[i].length; // the trustworthy size

      final entry = ByteData(16);
      entry.setUint8(0, m[0]);
      entry.setUint8(1, m[1]);
      entry.setUint8(2, m[2]);
      entry.setUint8(3, m[3]);
      entry.setUint16(4, m[4], Endian.little);
      entry.setUint16(6, m[5], Endian.little);
      entry.setUint32(8, realSize, Endian.little);
      entry.setUint32(12, dataOffset, Endian.little);
      out.add(entry.buffer.asUint8List());

      dataOffset += realSize;
    }

    for (final image in images) {
      out.add(image);
    }

    return out.toBytes();
  }

  static Future<File?> _decodeIcoToLargestPng({
    required List<int> icoBytes,
    required Directory outputDir,
  }) async {
    final decoded = img.IcoDecoder().decode(Uint8List.fromList(icoBytes));
    if (decoded == null) return null;

    final frames = decoded.frames.isNotEmpty ? decoded.frames : [decoded];

    img.Image best = frames.first;
    int bestArea = best.width * best.height;
    for (final frame in frames) {
      final area = frame.width * frame.height;
      if (area > bestArea) {
        best = frame;
        bestArea = area;
      }
    }

    final pngPath = '${outputDir.path}/icon.png';
    final pngFile = File(pngPath);
    await pngFile.writeAsBytes(img.encodePng(best));
    return pngFile;
  }
}