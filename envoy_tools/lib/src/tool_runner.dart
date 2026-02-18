import 'dart:io';

import 'package:envoy/envoy.dart';
import 'package:path/path.dart' as p;

/// Manages per-tier runner projects that give dynamic tools access to
/// `package:` libraries appropriate for their declared [ToolPermission].
///
/// Each permission tier gets its own minimal Dart project under
/// `<workspace>/.envoy/runners/<tier>/`. Dynamic tool scripts live in
/// `<tier>/tools/` and inherit that project's `pubspec.yaml` via
/// Dart's pubspec walk, so they can only import packages that tier allows.
///
/// Package grants by tier:
/// | Tier        | Extra packages          |
/// |-------------|-------------------------|
/// | compute     | none (dart: core only)  |
/// | readFile    | package:path            |
/// | writeFile   | package:path            |
/// | network     | package:http, path      |
/// | process     | package:http, path      |
class ToolRunner {
  /// Returns the runner project directory for [permission].
  static String runnerDir(String workspaceRoot, ToolPermission permission) =>
      p.join(workspaceRoot, '.envoy', 'runners', permission.name);

  /// Returns the tools directory for [permission].
  ///
  /// Tool scripts are stored here so they inherit the runner's pubspec.
  static String toolsDir(String workspaceRoot, ToolPermission permission) =>
      p.join(runnerDir(workspaceRoot, permission), 'tools');

  /// Ensures the runner project for [permission] is initialized.
  ///
  /// Creates the `pubspec.yaml` if absent, then runs `dart pub get` if
  /// `.dart_tool/package_config.json` doesn't exist yet. Idempotent —
  /// fast on every call after the first.
  ///
  /// Returns `null` on success or an error message on failure.
  static Future<String?> ensure(
    String workspaceRoot,
    ToolPermission permission,
  ) async {
    final dir = Directory(runnerDir(workspaceRoot, permission));
    await dir.create(recursive: true);

    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      await pubspecFile.writeAsString(_pubspecContent(permission));
    }

    final packageConfig = File(
      p.join(dir.path, '.dart_tool', 'package_config.json'),
    );
    if (!await packageConfig.exists()) {
      final result = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: dir.path,
      );
      if (result.exitCode != 0) {
        final detail = '${result.stdout}${result.stderr}'.trim();
        return 'dart pub get failed for ${permission.name} tier:\n$detail';
      }
    }

    return null;
  }

  // ── Pubspec content per tier ─────────────────────────────────────────────

  static String _pubspecContent(ToolPermission permission) {
    final deps = _depsFor(permission);
    return [
      'name: envoy_tool_runner_${permission.name}',
      'description: Package context for ${permission.name}-tier Envoy dynamic tools.',
      'publish_to: none',
      '',
      'environment:',
      "  sdk: '>=3.0.0 <4.0.0'",
      if (deps.isNotEmpty) ...[
        '',
        'dependencies:',
        ...deps,
      ],
    ].join('\n');
  }

  static List<String> _depsFor(ToolPermission permission) =>
      switch (permission) {
        ToolPermission.compute => [],
        ToolPermission.readFile || ToolPermission.writeFile => [
            '  path: ^1.9.0',
          ],
        ToolPermission.network || ToolPermission.process => [
            '  http: ^1.1.0',
            '  path: ^1.9.0',
          ],
      };
}
