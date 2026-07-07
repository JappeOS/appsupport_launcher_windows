import 'dart:io';

import '../application_identity.dart';
import '../constants.dart';
import '../runtime/runtime.dart';
import 'prefix_identity.dart';

/// Manages application prefixes. Prefixes are directories where the data
/// for each application is stored in. It is like a virtual Windows OS environment.
sealed class PrefixManager {
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

  /// Creates a new prefix for the given application identity and runtime.
  /// If a prefix already exists, it will throw an exception unless
  /// [overwrite] is true.
  static Future<PrefixIdentity> createPrefix(
    Runtime runtime,
    ApplicationIdentity appIdentity,
    [bool overwrite = false]
  ) async {
    final prefixPath = getPrefixDirectoryForApp(appIdentity);
    final prefixDirectory = Directory(prefixPath);

    if (!overwrite && await prefixDirectory.exists()) {
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
      await runtime.createPrefix(prefixDirectory);
    } catch (e) {
      // Clean up if something went wrong during prefix creation
      if (await prefixDirectory.exists()) {
        await prefixDirectory.delete(recursive: true);
      }
      rethrow;
    }

    print("Created prefix for application ${appIdentity.name} by ${appIdentity.publisher} at $prefixPath with runtime ${runtime.identity.name} version ${runtime.identity.version}.");
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
}