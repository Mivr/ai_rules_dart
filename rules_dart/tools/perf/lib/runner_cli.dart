/// Command-line driver for `runner`: runs repeats and reports their health.
library;

import 'dart:convert';
import 'dart:io';

import 'cli_args.dart';
import 'result_writer.dart';
import 'runner.dart';

/// Runs one repeat, as [executeRepeat] does.
typedef RepeatExecutor = RepeatResult Function({
  required String pristineWorkspace,
  required int repeatIndex,
  required String tempRoot,
});

const String _usage =
    'Usage: runner --workspace=<ws> --repeat=<n> --out=<result.json> [--floor=<on|off>]';

/// Returns an error message if a repeat count flag is present but not >= 1.
String? _invalidCountFlag(Map<String, List<String>> flags) {
  for (final names in const [
    ['repeat', 'repeat-index', 'repeat_index'],
    ['repeats'],
  ]) {
    final raw = lastFlagValue(flags, names);
    if (raw == null) continue;
    final value = int.tryParse(raw);
    if (value == null || value < 1) {
      return '--${names.first} must be an integer >= 1, got "$raw"';
    }
  }
  return null;
}

/// Executes [repeat] and writes its result to [outPath]; returns health.
bool _runSingleRepeat({
  required RepeatExecutor executor,
  required String workspace,
  required int repeat,
  required String outPath,
  required String tempRoot,
  bool floorEnabled = true,
}) {
  RepeatResult result;
  try {
    try {
      result = (executor as dynamic)(
        pristineWorkspace: workspace,
        repeatIndex: repeat,
        tempRoot: tempRoot,
        floorEnabled: floorEnabled,
      ) as RepeatResult;
    } on NoSuchMethodError catch (e) {
      stderr.writeln('Executor without floorEnabled invoked: $e');
      result = executor(
        pristineWorkspace: workspace,
        repeatIndex: repeat,
        tempRoot: tempRoot,
      );
    }
  } catch (e, st) {
    // A crashed repeat is recorded as an unhealthy (flow-less) result so the
    // remaining repeats still run and the exit code reports the failure.
    stderr.writeln('Repeat $repeat crashed: $e\n$st');
    result = RepeatResult(repeatIndex: repeat, flows: const {});
  }
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('${jsonEncode(result.toJson())}\n');
  stdout.writeln('Repeat $repeat finished, written to $outPath');
  final healthy = isRepeatHealthy(result);
  if (!healthy) stderr.writeln('Repeat $repeat is not healthy.');
  return healthy;
}

/// Runs the `runner` CLI and returns its exit code.
///
/// Returns 1 for invalid usage (including a repeat count below 1) and after
/// writing every planned repeat file if any repeat is not healthy.
int runRunnerCli(List<String> args, {RepeatExecutor executor = executeRepeat}) {
  final flags = parseCliFlags(args);
  final invalid = _invalidCountFlag(flags);
  if (invalid != null) {
    stderr.writeln('$invalid\n$_usage');
    return 1;
  }
  final floorRaw = lastFlagValue(flags, const ['floor'])?.toLowerCase() ?? 'on';
  if (floorRaw != 'on' && floorRaw != 'off') {
    stderr.writeln('--floor must be "on" or "off", got "$floorRaw"\n$_usage');
    return 1;
  }
  final floorEnabled = floorRaw == 'on';
  final rawWorkspace = lastFlagValue(flags, const ['workspace', 'ws']);
  final plannedOutputs = resolveRunnerOutputs(flags);
  if (rawWorkspace == null || rawWorkspace.isEmpty || plannedOutputs.isEmpty) {
    stderr.writeln(_usage);
    return 1;
  }

  final workspace = resolveCliPath(rawWorkspace);
  final tempRoot = Directory.systemTemp.createTempSync('rd_perf_').path;
  var allHealthy = true;
  try {
    for (final (repeatIndex, outPath) in plannedOutputs) {
      final healthy = _runSingleRepeat(
        executor: executor,
        workspace: workspace,
        repeat: repeatIndex,
        outPath: outPath,
        tempRoot: tempRoot,
        floorEnabled: floorEnabled,
      );
      allHealthy = allHealthy && healthy;
    }
  } finally {
    try {
      forceDeleteDirectorySync(Directory(tempRoot));
    } on FileSystemException catch (e) {
      stderr.writeln('Temp cleanup error: $e');
    } on ProcessException catch (e) {
      stderr.writeln('Error cleaning temp directory: $e');
    }
  }
  return allHealthy ? 0 : 1;
}
