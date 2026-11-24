// The wave-1 project lint rules (`rules_dart_project_lints`).
//
// Custom `AnalysisRule`s enforcing repository-wide invariants of the
// build-action workers and tools, hosted in `analyzer_summary` alongside the
// vendored SDK lints. Each rule checks only production compilation units (see
// [isProductionProjectLintPath]).
import 'package:analyzer/analysis_rule/analysis_rule.dart';

import 'package:rules_dart_project_lints/no_home_env_reads.dart';
import 'package:rules_dart_project_lints/no_stdout_in_worker.dart';
import 'package:rules_dart_project_lints/no_wall_clock_in_actions.dart';
import 'package:rules_dart_project_lints/process_requires_environment.dart';

export 'package:rules_dart_project_lints/no_home_env_reads.dart';
export 'package:rules_dart_project_lints/no_stdout_in_worker.dart';
export 'package:rules_dart_project_lints/no_wall_clock_in_actions.dart';
export 'package:rules_dart_project_lints/process_requires_environment.dart';
export 'package:rules_dart_project_lints/project_lint_scope.dart';

/// The wave-1 project lint rules, in registration order.
///
/// The analyzer registers each rule under its lowercase name, enabled through
/// `linter.rules` in `analysis_options.yaml`.
List<AnalysisRule> rulesDartProjectLints() {
  return <AnalysisRule>[
    NoHomeEnvReads(),
    NoStdoutInWorker(),
    NoWallClockInActions(),
    ProcessRequiresEnvironment(),
  ];
}
