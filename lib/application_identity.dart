import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Contains all necessary information to identify an application.
class ApplicationIdentity {
  /// Reads the application identity from the provided appPath.
  /// The appPath is expected to point to an *.exe file.
  static Future<ApplicationIdentity> readFromExe(String appPath) async {
    const resultTimeout = Duration(minutes: 1);
    final result = await Process.run('exiftool', ['-j', appPath])
        .timeout(resultTimeout, onTimeout: () {
          throw TimeoutException('Failed to read application identity from $appPath: exiftool timed out.', resultTimeout);
        });

    if (result.exitCode != 0) {
      throw Exception('Failed to read application identity from $appPath: ${result.stderr}');
    }

    final json = jsonDecode(result.stdout as String) as List;
    final jsonMap = json.first as Map<String, dynamic>;

    return ApplicationIdentity(
      name: jsonMap['ProductName'] as String,
      version: jsonMap['ProductVersion'].toString(),
      publisher: jsonMap['CompanyName'] as String,
      legalTrademarks: jsonMap["LegalTrademarks"] as String? ?? "",
    );
  }

  /// Decodes the application identity from the provided JSON map.
  static ApplicationIdentity decode(Map<String, dynamic> jsonMap) {
    return ApplicationIdentity(
      name: jsonMap['name'] as String,
      version: jsonMap['version'] as String,
      publisher: jsonMap['publisher'] as String,
      legalTrademarks: jsonMap["legalTrademarks"] as String,
    );
  }

  /// Encodes the application identity to a JSON map.
  static Map<String, dynamic> encode(ApplicationIdentity applicationIdentity) {
    return {
      'name': applicationIdentity.name,
      'version': applicationIdentity.version,
      'publisher': applicationIdentity.publisher,
      'legalTrademarks': applicationIdentity.legalTrademarks,
    };
  }

  final String name;
  final String version;
  final String publisher;
  final String legalTrademarks;

  ApplicationIdentity({
    required this.name,
    required this.version,
    required this.publisher,
    required this.legalTrademarks,
  });

  @override
  String toString() {
    return 'ApplicationIdentity(name: $name, version: $version, publisher: $publisher, legalTrademarks: $legalTrademarks)';
  }
}