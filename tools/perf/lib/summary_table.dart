/// Step summary table generator for GitHub step summary and stdout.
library;

import 'result_writer.dart';

/// Formats a markdown table showing both replay and toolchain floor ratios.
String formatStepSummaryTable(Map<String, dynamic> summary) {
  final flows = summary['flows'] as Map<String, dynamic>? ?? const {};
  final buffer = StringBuffer();
  buffer.writeln(
    '| Flow | Bazel (s) | Replay Sol (s) | Replay Ratio | Toolchain Floor (s) | Floor Ratio | Status |',
  );
  buffer.writeln('| :--- | :--- | :--- | :--- | :--- | :--- | :--- |');

  for (final key in expectedFlowKeys) {
    final flow = flows[key] as Map<String, dynamic>?;
    if (flow == null) continue;
    final bazel = flow['bazel'] as num?;
    final sol = flow['sol'] as num?;
    final floor = flow['toolchain_floor'] as num?;
    final replayRatio = (bazel != null && sol != null && sol > 0)
        ? '${(bazel / sol).toStringAsFixed(2)}x'
        : '-';
    final floorRatio = (bazel != null && floor != null && floor > 0)
        ? '${(bazel / floor).toStringAsFixed(2)}x'
        : (flow['toolchain_floor_ratio'] != null
              ? '${(flow['toolchain_floor_ratio'] as num).toStringAsFixed(2)}x'
              : '-');
    final bazelStr = bazel != null ? bazel.toStringAsFixed(6) : '-';
    final solStr = sol != null ? sol.toStringAsFixed(6) : '-';
    final floorStr = floor != null ? floor.toStringAsFixed(6) : '-';
    final okStatus =
        flow['reason'] == 'ok' &&
        (flow['floor_reason'] == null || flow['floor_reason'] == 'ok');
    final status = okStatus ? 'ok' : 'fail';
    buffer.writeln(
      '| $key | $bazelStr | $solStr | $replayRatio | $floorStr | $floorRatio | $status |',
    );
  }

  return buffer.toString();
}
