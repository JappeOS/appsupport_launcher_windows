import 'dart:convert';
import 'dart:io';

import '../application_identity.dart';
import '../runtime/application_runtime_identity.dart';

/// Contains all prefix-specific metadata and identification info.
class PrefixIdentity {
  /// Reads the prefix identity from the provided prefixPath.
  static Future<PrefixIdentity> read(Directory prefixPath, File prefixIdentityFile) async {
    final jsonString = await prefixIdentityFile.readAsString();
    final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
    return decode(prefixPath, jsonMap);
  }

  /// Decodes the prefix identity from the provided JSON map.
  static PrefixIdentity decode(Directory prefixPath, Map<String, dynamic> jsonMap) {
    return PrefixIdentity(
      prefixPath: prefixPath.path,
      identity: ApplicationIdentity.decode(jsonMap['identity'] as Map<String, dynamic>),
      runtimeIdentity: ApplicationRuntimeIdentity.decode(jsonMap['runtimeIdentity'] as Map<String, dynamic>),
      metadata: jsonMap['metadata'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Writes the prefix identity to the provided prefixPath.
  static Future<void> write(File prefixPath, PrefixIdentity prefixIdentity) async {
    final jsonString = jsonEncode(encode(prefixIdentity));
    await prefixPath.writeAsString(jsonString);
  }

  /// Encodes the prefix identity to a JSON map.
  static Map<String, dynamic> encode(PrefixIdentity prefixIdentity) {
    return {
      'identity': ApplicationIdentity.encode(prefixIdentity.identity),
      'runtimeIdentity': ApplicationRuntimeIdentity.encode(prefixIdentity.runtimeIdentity),
      'metadata': prefixIdentity._metadata,
    };
  }

  final String prefixPath;
  final ApplicationIdentity identity;
  final ApplicationRuntimeIdentity runtimeIdentity;
  final Map<String, dynamic> _metadata;

  PrefixIdentity({
    required this.prefixPath,
    required this.identity,
    required this.runtimeIdentity,
    Map<String, dynamic> metadata = const {},
  }) : _metadata = Map<String, dynamic>.from(metadata);

  bool writeMetadata(String key, dynamic value) {
    if (_metadata[key] == value) {
      return false;
    }
    _metadata[key] = value;
    return true;
  }

  dynamic readMetadata(String key) {
    return _metadata[key];
  }

  bool removeMetadata(String key) {
    return _metadata.remove(key) != null;
  }

  @override
  String toString() {
    return 'PrefixIdentity(identity: $identity, runtimeIdentity: $runtimeIdentity)';
  }
}
