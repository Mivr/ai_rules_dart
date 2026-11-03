// Registers every lint rule `analyzer_summary` checks projects against.
//
// The vendored SDK lints (`package:linter/src/rules.dart`) plus the wave-1
// project rules (`package:rules_dart_project_lints`). A `file:` library (no
// `package_name`), so the analyzer's own implementation import below stays an
// internal detail of this tool rather than a public API surface.
import 'package:analyzer/src/lint/registry.dart';
import 'package:linter/src/rules.dart';
import 'package:rules_dart_project_lints/rules_dart_project_lints.dart';

/// Registers the vendored SDK lint rules and the wave-1 project lint rules.
void registerAllLintRules() {
  registerLintRules();
  rulesDartProjectLints().forEach(Registry.ruleRegistry.registerLintRule);
}
