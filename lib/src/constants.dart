import 'dart:io';
import 'package:path/path.dart' as p;

import 'application_identity.dart';

/// Gets the base application data directory.
String getAppDataDirectory() {
  assert(Platform.isLinux);
  final homeDir = Platform.environment['HOME']!;
  return p.join(homeDir, '.local', 'share', 'appsupport', 'win');
}

/// The regex used for normalizing the app publisher and name. Used in
/// [getPrefixDirectoryForApp], for example.
const String appPublisherAndNameRegex = r'[^a-z0-9-_]';

/// The directory where the runtimes are stored.
final String runtimeDirectory = p.join(getAppDataDirectory(), 'runtimes');

/// The directory where the application prefixes are stored.
final String prefixDirectory = p.join(getAppDataDirectory(), 'prefixes');

/// Returns the prefix directory for a specific app based on a [ApplicationIdentity].
String getPrefixDirectoryForApp(ApplicationIdentity appIdentity) {
  var publisher = appIdentity.publisher.toLowerCase().replaceAll(RegExp(appPublisherAndNameRegex), '').trim();
  var appName = appIdentity.name.toLowerCase().replaceAll(RegExp(appPublisherAndNameRegex), '').trim();
  if (publisher.isEmpty && appName.isEmpty) {
    throw Exception('Invalid application identity: both publisher and app name are empty.');
  }
  if (publisher.isEmpty) publisher = 'unknown';
  if (appName.isEmpty) appName = 'unknown';
  return p.join(prefixDirectory, '$publisher.$appName');
}

/// Returns the path to the file where the prefix identity is stored for a
/// prefix - based on the provided [ApplicationIdentity].
String getPrefixIdentityFilePath(ApplicationIdentity appIdentity) {
  final prefixDir = getPrefixDirectoryForApp(appIdentity);
  return p.join(prefixDir, 'prefix.json');
}