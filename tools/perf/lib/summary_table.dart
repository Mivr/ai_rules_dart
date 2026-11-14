/// Step summary table generator for GitHub step summary and stdout.
library;

import 'dart:math';

import 'result_writer.dart';

/// Formats a markdown table showing both replay and toolchain floor ratios.
String formatStepSummaryTable(Map<String, dynamic> summary) {
  final flows = summary['flows'] as Map<String, dynamic>? ?? const {};
  final buffer = StringBuffer();
  buffer.writeln(
    '| Flow | Bazel (s) | Replay Sol (s) | Replay Ratio | Toolchain Floor (s) | Floor Ratio | Peak RSS (MiB) | Wall (s) | Status |',
  );
  buffer.writeln(
    '| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |',
  );

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
    final peak = flow['peak_rss_mb'] as num?;
    final peakStr = peak != null ? peak.toStringAsFixed(1) : '-';
    final wall = flow['wall_seconds'] as num?;
    final wallStr = wall != null ? wall.toStringAsFixed(3) : '-';
    final okStatus =
        flow['reason'] == 'ok' &&
        (flow['floor_reason'] == null || flow['floor_reason'] == 'ok');
    final status = okStatus ? 'ok' : 'fail';
    buffer.writeln(
      '| $key | $bazelStr | $solStr | $replayRatio | $floorStr | $floorRatio | $peakStr | $wallStr | $status |',
    );
  }

  return buffer.toString();
}

/// One arm's medians of a flow in an A/B pair.
final class AbArm {
  /// Creates an arm record.
  const AbArm({this.wall, this.peak, this.linkCheck});

  /// Median wall seconds.
  final double? wall;

  /// Median peak RSS in MiB.
  final double? peak;

  /// Median `DartLinkCheck` wall seconds, for an arm that opted in.
  final double? linkCheck;
}

/// One flow's paired `link_modules` off/on comparison.
final class AbFlow {
  /// Creates a paired flow record.
  const AbFlow({
    required this.key,
    required this.off,
    required this.on,
    this.wallRatio,
    this.peakRatio,
  });

  /// Flow name.
  final String key;

  /// The off arm.
  final AbArm off;

  /// The on arm.
  final AbArm on;

  /// Geomean over repeats of the paired wall ratio on/off.
  final double? wallRatio;

  /// Median over repeats of the paired peak RSS ratio on/off.
  final double? peakRatio;
}

/// Geometric mean of positive [values], or null when empty.
double? geometricMean(List<double> values) {
  if (values.isEmpty) return null;
  final logs = values.map(log).reduce((a, b) => a + b);
  return exp(logs / values.length);
}

Map<int, RepeatResult> _byIndex(List<RepeatResult> repeats) => {
  for (final r in repeats) r.repeatIndex: r,
};

List<double> _pairedRatios(
  String key,
  (Map<int, RepeatResult>, Map<int, RepeatResult>) arms,
  double? Function(FlowResult) pick,
) {
  final (off, on) = arms;
  final ratios = <double>[];
  for (final index in off.keys.where(on.containsKey)) {
    final base = off[index]!.flows[key] == null
        ? null
        : pick(off[index]!.flows[key]!);
    final head = on[index]!.flows[key] == null
        ? null
        : pick(on[index]!.flows[key]!);
    if (base != null && head != null && base > 0 && head > 0) {
      ratios.add(head / base);
    }
  }
  return ratios;
}

AbArm _armOf(String key, List<RepeatResult> repeats) {
  final flows = [
    for (final r in repeats)
      if (r.flows[key] != null) r.flows[key]!,
  ];
  List<double> collect(double? Function(FlowResult) pick) => [
    for (final f in flows)
      if (pick(f) != null) pick(f)!,
  ];
  return AbArm(
    wall: calculateMedian(collect((f) => f.extras.wallSeconds)),
    peak: calculateMedian(collect((f) => f.peakRssMb)),
    linkCheck: calculateMedian(collect((f) => f.extras.linkCheckWallSeconds)),
  );
}

/// Pairs each flow of the off and on arms by repeat index.
List<AbFlow> pairArms(List<RepeatResult> off, List<RepeatResult> on) {
  final arms = (_byIndex(off), _byIndex(on));
  return [
    for (final key in expectedFlowKeys)
      AbFlow(
        key: key,
        off: _armOf(key, off),
        on: _armOf(key, on),
        wallRatio: geometricMean(
          _pairedRatios(key, arms, (f) => f.extras.wallSeconds),
        ),
        peakRatio: calculateMedian(
          _pairedRatios(key, arms, (f) => f.peakRssMb),
        ),
      ),
  ];
}

String? _stdoutFailure(int index, RepeatResult off, RepeatResult on) {
  final base = off.flows['dart-app-clean']?.extras.appStdout;
  final head = on.flows['dart-app-clean']?.extras.appStdout;
  if (base == null || head == null) {
    return 'repeat $index: dart-app-clean has no app stdout in the '
        '${base == null ? 'off' : 'on'} arm';
  }
  if (base != head) {
    return 'repeat $index: app stdout differs between arms: '
        'off=${_quote(base)} on=${_quote(head)}';
  }
  return null;
}

/// Quotes [text] for a failure message.
String _quote(String text) => '"${text.replaceAll('\n', r'\n')}"';

bool _hasLinkData(List<RepeatResult> repeats) =>
    repeats.any((r) => r.flows.values.any((f) => f.extras.linked != null));

/// Lists why the off and on arms are not a trustworthy pair (empty if ok).
List<String> abFailures(List<RepeatResult> off, List<RepeatResult> on) {
  final failures = <String>[];
  final offIndex = _byIndex(off);
  final onIndex = _byIndex(on);
  final offKeys = offIndex.keys.toList()..sort();
  final onKeys = onIndex.keys.toList()..sort();
  if (offKeys.join(',') != onKeys.join(',')) {
    failures.add('arms ran different repeats: off $offKeys on $onKeys');
  }
  if (_hasLinkData(off)) failures.add('the off arm carries link_modules data');
  if (!_hasLinkData(on))
    failures.add('the on arm did not opt in to link_modules');
  for (final index in offKeys.where(onIndex.containsKey)) {
    final failure = _stdoutFailure(index, offIndex[index]!, onIndex[index]!);
    if (failure != null) failures.add(failure);
  }
  return failures;
}

String _fixed(double? value, int digits) =>
    value == null ? '-' : value.toStringAsFixed(digits);

/// Formats the paired off/on table: per flow the geomean paired wall ratio,
/// the median paired peak RSS ratio and both arms' medians.
String formatAbTable(List<AbFlow> flows) {
  final buffer = StringBuffer()
    ..writeln(
      '| Flow | Wall on/off (geomean) | Peak RSS on/off (median) | '
      'Wall off (s) | Wall on (s) | Peak off (MiB) | Peak on (MiB) | '
      'DartLinkCheck on (s) |',
    )
    ..writeln('| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |');
  for (final f in flows) {
    buffer.writeln(
      '| ${f.key} | ${_fixed(f.wallRatio, 3)} | ${_fixed(f.peakRatio, 3)} | '
      '${_fixed(f.off.wall, 3)} | ${_fixed(f.on.wall, 3)} | '
      '${_fixed(f.off.peak, 1)} | ${_fixed(f.on.peak, 1)} | '
      '${_fixed(f.on.linkCheck, 3)} |',
    );
  }
  return buffer.toString();
}
