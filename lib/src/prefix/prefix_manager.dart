import 'dart:io';

import '../application_identity.dart';
import '../constants.dart';
import '../runtime/runtime.dart';
import 'prefix_desktop_entry.dart';
import 'prefix_identity.dart';

/// Manages application prefixes. Prefixes are directories where the data
/// for each application is stored in. It is like a virtual Windows OS environment.
sealed class PrefixManager {
  static const _kMetaKeyDesktopEntry = "prefixmanager.desktop_entry";
  static const _kMetaKeyIcon = "prefixmanager.icon";

  /// Returns the prefix identity for the given application identity,
  /// or null if it doesn't exist. Throws an exception if the prefix exists,
  /// but cannot be read.
  static Future<PrefixIdentity?> getPrefix(ApplicationIdentity appIdentity) async {
    final prefixPath = Directory(getPrefixDirectoryForApp(appIdentity));

    if (!await prefixPath.exists()) {
      return null;
    }

    PrefixIdentity? ident;
    try {
      ident = await PrefixIdentity.read(prefixPath, File(getPrefixIdentityFilePath(appIdentity)));
    } on PathNotFoundException {
      return null;
    }

    return ident;
  }

  /// Similar to [getPrefix], but checks if the given [appPath] executable
  /// resides inside an already-made prefix. If the executable alredy resides
  /// inside a prefix, we should run it within that prefix.
  static Future<PrefixIdentity?> getPrefixForExecutable(
    ApplicationIdentity appIdentity,
    String appPath,
  ) async {
    await for (final ent in Directory(prefixDirectory).list()) {
      if (ent is! Directory) continue;
      if (await isReallyInside(ent, File(appPath))) {
        try {
          return PrefixIdentity.read(ent, File(getPrefixIdentityFilePath(appIdentity)));
        } on PathNotFoundException {
          continue;
        }
      }
    }

    return getPrefix(appIdentity);
  }

  /// Creates a new prefix for the given application identity and runtime.
  /// If a prefix already exists, it will throw an exception unless
  /// [overwrite] is true.
  /// [mode] has three options:
  /// - [CreatePrefixMode.createIfNotExists]: Creates a fresh prefix only if a
  ///   current one does not exist.
  /// - [CreatePrefixMode.overwriteMetadata]: Overwrites only metadata of an
  ///   existing prefix, or creates a fully fresh prefix if none exists. Will
  ///   **only** write metadata if the prefix directory exists already,
  ///   regardless of contents.
  /// - [CreatePrefixMode.overwriteAll]: Creates a fresh prefix regardless of
  ///   whether one exists already.
  static Future<PrefixIdentity> createPrefix(
    Runtime runtime,
    ApplicationIdentity appIdentity,
    [CreatePrefixMode mode = CreatePrefixMode.createIfNotExists]
  ) async {
    final prefixPath = getPrefixDirectoryForApp(appIdentity);
    final prefixDirectory = Directory(prefixPath);
    final prefixDirectoryExists = await prefixDirectory.exists();
    final overwriteAll
        = mode == CreatePrefixMode.overwriteAll || !prefixDirectoryExists;

    if (mode == CreatePrefixMode.createIfNotExists &&
        prefixDirectoryExists
    ) {
      throw Exception('Prefix already exists for application ${appIdentity.name} by ${appIdentity.publisher}.');
    }

    final prefixIdentity = PrefixIdentity(
      prefixPath: prefixPath,
      identity: appIdentity,
      runtimeIdentity: runtime.identity,
    );

    try {
      await prefixDirectory.create(recursive: true);
      await PrefixIdentity.write(File(getPrefixIdentityFilePath(appIdentity)), prefixIdentity);
      if (overwriteAll) {
        await runtime.createPrefix(prefixDirectory);
      }
    } catch (e) {
      // Clean up if something went wrong during prefix creation
      if (prefixDirectoryExists &&
          overwriteAll
      ) {
        await prefixDirectory.delete(recursive: true);
      }
      rethrow;
    }

    print("Created prefix mode ${mode.name} for application ${appIdentity.name} by ${appIdentity.publisher} at $prefixPath with runtime ${runtime.identity.name} version ${runtime.identity.version}.");
    return prefixIdentity;
  }

  /// Deletes the prefix for the given application identity.
  /// Throws an exception if the prefix directory does not exist.
  static Future<void> deletePrefix(ApplicationIdentity appIdentity) async {
    final prefixPath = getPrefixDirectoryForApp(appIdentity);
    final prefixDirectory = Directory(prefixPath);

    if (!await prefixDirectory.exists()) {
      throw Exception('Prefix does not exist for application ${appIdentity.name} by ${appIdentity.publisher}.');
    }

    final ident = await getPrefix(appIdentity);
    if (ident != null) {
      await deleteDesktopEntry(ident);
    }

    await prefixDirectory.delete(recursive: true);
    print("Deleted prefix for application ${appIdentity.name} by ${appIdentity.publisher} at $prefixPath.");
  }

  /// Updates the prefix identity for the given application identity.
  /// Throws an exception if the prefix directory does not exist.
  static Future<void> updatePrefix(PrefixIdentity prefixIdentity) async {
    final prefixPath = Directory(prefixIdentity.prefixPath);
    if (!await prefixPath.exists()) {
      throw Exception('Prefix directory does not exist at ${prefixIdentity.prefixPath}.');
    }

    await PrefixIdentity.write(File(getPrefixIdentityFilePath(prefixIdentity.identity)), prefixIdentity);
    print("Updated prefix identity for application ${prefixIdentity.identity.name} by ${prefixIdentity.identity.publisher} at ${prefixIdentity.prefixPath}.");
  }

  /// Gets the desktop entry associated with a [PrefixIdentity], if any.
  /// Throws an exception if the prefix directory does not exist.
  static Future<String?> getDesktopEntry(PrefixIdentity prefixIdentity) async {
    final prefixPath = Directory(prefixIdentity.prefixPath);
    if (!await prefixPath.exists()) {
      throw Exception('Prefix directory does not exist at ${prefixIdentity.prefixPath}.');
    }
    return prefixIdentity.readMetadata(_kMetaKeyDesktopEntry) as String?;
  }

  /// Updates an existing desktop entry for the specified [PrefixIdentity], at
  /// the specific [sourceLnk]. [sourceLnk] needs to point to a valid source file for
  /// a desktop entry, a.k.a an .lnk file.
  /// Throws an exception if the prefix directory does not exist, or if
  /// desktop entry creation fails.
  static Future<void> updateDesktopEntry(
    PrefixIdentity prefixIdentity,
    File sourceLnk,
    RuntimePathResolver pathResolver,
  ) async {
    final prefixPath = Directory(prefixIdentity.prefixPath);
    if (!await prefixPath.exists()) {
      throw Exception('Prefix directory does not exist at ${prefixIdentity.prefixPath}.');
    }

    final res = await PrefixDesktopEntry.write(
      sourceLnk,
      pathResolver,
      prefixIdentity,
    );

    prefixIdentity.writeMetadata(_kMetaKeyDesktopEntry, res.desktopEntry.path);
    prefixIdentity.writeMetadata(_kMetaKeyIcon, res.icon?.path ?? "");
    await updatePrefix(prefixIdentity);
    print("Updated desktop entry for application ${prefixIdentity.identity.name} by ${prefixIdentity.identity.publisher} at $prefixPath.");
  }

  /// Deletes a desktop entry associated with a [PrefixIdentity], if any.
  /// Returns false if no desktop entry was associated with this [PrefixIdentity],
  /// or if the file did not exist. Returns true otherwise.
  /// Throws an exception if the prefix directory does not exist or deletion
  /// fails.
  static Future<bool> deleteDesktopEntry(PrefixIdentity prefixIdentity) async {
    final prefixPath = Directory(prefixIdentity.prefixPath);
    if (!await prefixPath.exists()) {
      throw Exception('Prefix directory does not exist at ${prefixIdentity.prefixPath}.');
    }

    final entryPath = prefixIdentity.readMetadata(_kMetaKeyDesktopEntry) as String?;
    final iconPath = prefixIdentity.readMetadata(_kMetaKeyIcon) as String?;
    if (entryPath == null && iconPath == null) {
      return false;
    }

    bool anyDeleted = false;

    if (entryPath != null && entryPath.isNotEmpty) {
      final entryFile = File(entryPath);
      if (await entryFile.exists()) {
        await entryFile.delete();
        anyDeleted = true;
      }
    }

    if (iconPath != null && iconPath.isNotEmpty) {
      final iconFile = File(iconPath);
      if (await iconFile.exists()) {
        await iconFile.delete();
        anyDeleted = true;
      }
    }

    if (!anyDeleted) {
      return false;
    }

    print("Deleted desktop entry for application ${prefixIdentity.identity.name} by ${prefixIdentity.identity.publisher} at $prefixPath.");
    return true;
  }
}

enum CreatePrefixMode {
  /// Only creates a prefix if it does not exist.
  createIfNotExists,

  /// Only overwrites prefix metadata, like runtime identity.
  overwriteMetadata,

  /// Overwrites a prefix completely: deletes an existing one,
  /// then creates a new one on top.
  overwriteAll,
}