import 'dart:io';

import 'package:path/path.dart' as p;

/// Manages the "tool runner" project — a minimal Dart project inside the
/// workspace that gives dynamic tools access to `package:` libraries.
///
/// The runner lives at `<workspace>/.envoy/`, alongside the tool scripts in
/// `.envoy/tools/`. Because `dart run` resolves packages by walking up the
/// directory tree for a `pubspec.yaml`, any `.dart` file in `.envoy/tools/`
/// automatically sees the runner's dependencies after initialization.
///
/// Available packages (see [_pubspec]):
/// - `package:http` — HTTP client
/// - `package:path` — path manipulation
class ToolRunner {
  static const _pubspec = '''name: envoy_tool_runner
description: Package context for Envoy dynamic tools.
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  http: ^1.1.0
  path: ^1.9.0
''';

  /// Ensures the runner project is initialized at `<workspaceRoot>/.envoy/`.
  ///
  /// - Creates the `pubspec.yaml` if absent
  /// - Runs `dart pub get` if `.dart_tool/package_config.json` doesn't exist
  ///
  /// Safe to call on every [RegisterToolTool] invocation — it is a no-op
  /// if already initialized. Returns `null` on success, or an error message.
  static Future<String?> ensure(String workspaceRoot) async {
    final runnerDir = Directory(p.join(workspaceRoot, '.envoy'));
    await runnerDir.create(recursive: true);

    final pubspecFile = File(p.join(runnerDir.path, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      await pubspecFile.writeAsString(_pubspec);
    }

    final packageConfig = File(
      p.join(runnerDir.path, '.dart_tool', 'package_config.json'),
    );
    if (!await packageConfig.exists()) {
      final result = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: runnerDir.path,
      );
      if (result.exitCode != 0) {
        final detail = '${result.stdout}${result.stderr}'.trim();
        return 'dart pub get failed:\n$detail';
      }
    }

    return null;
  }
}
