import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Represents a list of sources for runtime downloads.
class RuntimeSources {
  /// Reads the runtime sources file.
  static Future<RuntimeSources> read(File runtimeSourcesFile) async {
    final jsonString = await runtimeSourcesFile.readAsString();
    final jsonList = jsonDecode(jsonString) as List<dynamic>;
    return decode(jsonList);
  }

  /// Decodes the runtime source from the provided JSON list.
  static RuntimeSources decode(List<dynamic> jsonList) {
    return RuntimeSources(
      sources: jsonList.map((e) => RuntimeSource.decode(e)).toList(),
    );
  }

  /// Encodes the runtime source to a JSON list.
  static List<dynamic> encode(RuntimeSources runtimeSource) {
    return runtimeSource.sources.map((e) => RuntimeSource.encode(e)).toList();
  }

  final List<RuntimeSource> sources;

  const RuntimeSources({
    required this.sources,
  });

  @override
  String toString() {
    return 'RuntimeSources(sources: $sources)';
  }
}

/// Represents a source for runtime downloads.
class RuntimeSource {
  /// Decodes the runtime source from the provided JSON map.
  static RuntimeSource decode(Map<String, dynamic> jsonMap) {
    return RuntimeSource(
      type: RuntimeSourceType.values.byName(jsonMap['type'] as String),
      uri: Uri.parse(jsonMap['uri'] as String),
    );
  }

  /// Encodes the runtime source to a JSON map.
  static Map<String, dynamic> encode(RuntimeSource runtimeSource) {
    return {
      'type': runtimeSource.type.name,
      'uri': runtimeSource.uri.toString(),
    };
  }

  final RuntimeSourceType type;
  final Uri uri;

  const RuntimeSource({
    required this.type,
    required this.uri,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RuntimeSource &&
        other.type == type &&
        other.uri == uri;
  }

  @override
  int get hashCode => Object.hash(type, uri);

  @override
  String toString() {
    return 'RuntimeSource(type: ${type.name}, uri: $uri)';
  }
}

enum RuntimeSourceType {
  static,
  github,
}