import 'dart:io';

/// Probe for the `run_home` hermeticity gate: the kernel launcher must start
/// this program without any `RULES_DART_*` control variable while keeping
/// the caller's own environment (ledger row opus-2026-10-26:L-3).
void main() {
  final leaked =
      Platform.environment.keys
          .where((key) => key.startsWith('RULES_DART_'))
          .toList()
        ..sort();
  for (final key in leaked) {
    stdout.writeln('leaked:$key');
  }
  stdout.writeln("caller_path=${Platform.environment['PATH'] ?? ''}");
  if (leaked.isNotEmpty) exit(1);
  if ((Platform.environment['PATH'] ?? '').isEmpty) exit(2);
}
