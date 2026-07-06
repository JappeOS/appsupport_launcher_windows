class ApplicationRuntimeIdentity {
  /// Decodes the application runtime identity from the provided JSON map.
  static ApplicationRuntimeIdentity decode(Map<String, dynamic> jsonMap) {
    return ApplicationRuntimeIdentity(
      name: jsonMap['name'] as String,
      version: jsonMap['version'] as String,
      type: jsonMap['type'] as String,
    );
  }

  /// Encodes the application runtime identity to a JSON map.
  static Map<String, dynamic> encode(ApplicationRuntimeIdentity applicationRuntimeIdentity) {
    return {
      'name': applicationRuntimeIdentity.name,
      'version': applicationRuntimeIdentity.version,
      'type': applicationRuntimeIdentity.type,
    };
  }

  final String name;
  final String version;
  final String type;

  const ApplicationRuntimeIdentity({
    required this.name,
    required this.version,
    required this.type,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ApplicationRuntimeIdentity &&
        other.name == name &&
        other.version == version &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(name, version, type);

  @override
  String toString() {
    return 'ApplicationRuntimeIdentity(runtimeName: $name, runtimeVersion: $version, runtimeType: $type)';
  }
}