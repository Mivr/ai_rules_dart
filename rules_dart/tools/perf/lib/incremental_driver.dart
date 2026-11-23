/// Driver for resident incremental compiler (frontend_server).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

ProcessStat? _readProcStat(int pid) {
  final statFile = File('/proc/$pid/stat');
  if (!statFile.existsSync()) return null;
  try {
    final text = statFile.readAsStringSync();
    final closeParen = text.lastIndexOf(')');
    if (closeParen == -1) return null;
    final rest = text.substring(closeParen + 2).trim().split(' ');
    return ProcessStat(
      pid: pid,
      utime: int.parse(rest[11]),
      stime: int.parse(rest[12]),
      cutime: int.parse(rest[13]),
      cstime: int.parse(rest[14]),
    );
  } on FileSystemException catch (e) {
    stderr.writeln('Proc stat file read error: $e');
    return null;
  } on FormatException catch (e) {
    stderr.writeln('Proc stat parse error: $e');
    return null;
  } on RangeError catch (e) {
    stderr.writeln('Proc stat range error: $e');
    return null;
  }
}

/// Process statistics from /proc/<pid>/stat.
final class ProcessStat {
  /// Creates a process statistics record.
  const ProcessStat({
    required this.pid,
    required this.utime,
    required this.stime,
    required this.cutime,
    required this.cstime,
  });

  /// Process ID.
  final int pid;

  /// User time ticks.
  final int utime;

  /// System time ticks.
  final int stime;

  /// Cumulative child user ticks.
  final int cutime;

  /// Cumulative child system ticks.
  final int cstime;

  /// Combined ticks.
  int get totalTicks => utime + stime + cutime + cstime;
}

/// On-CPU seconds of every thread of [pid], at nanosecond resolution.
///
/// `/proc/<pid>/stat` counts in clock ticks, too coarse for a recompile of one
/// method body; the scheduler's per-thread counters are not. Null when the
/// counters are unreadable (not Linux, or the process is gone).
double? _readSchedSeconds(int pid) {
  final tasks = Directory('/proc/$pid/task');
  if (!tasks.existsSync()) return null;
  var nanos = 0;
  try {
    for (final task in tasks.listSync(followLinks: false)) {
      final file = File('${task.path}/schedstat');
      if (!file.existsSync()) continue;
      nanos += int.parse(file.readAsStringSync().split(' ').first);
    }
  } on FileSystemException catch (e) {
    stderr.writeln('Schedstat read error: $e');
    return null;
  } on FormatException catch (e) {
    stderr.writeln('Schedstat parse error: $e');
    return null;
  }
  return nanos / 1e9;
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final eq = arg.indexOf('=');
    if (eq != -1) {
      result[arg.substring(2, eq)] = arg.substring(eq + 1);
    } else {
      result[arg.substring(2)] = 'true';
    }
  }
  return result;
}

final class _CompilerSession {
  _CompilerSession(this.process, this.outputDill) {
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    lines.listen((line) {
      if (line.contains('Error: ') || line.contains('Unhandled exception:')) {
        errors.add(line);
      }
      if (line.contains(outputDill)) {
        if (!compileCompleter.isCompleted) {
          compileCompleter.complete(line);
        } else if (recompileCompleter != null &&
            !recompileCompleter!.isCompleted) {
          recompileCompleter!.complete(line);
        }
      }
    });

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => errors.add(line));
  }

  final Process process;
  final String outputDill;
  final errors = <String>[];
  final compileCompleter = Completer<String>();
  Completer<String>? recompileCompleter;

  Future<void> initialCompile(String entrypoint) async {
    process.stdin.writeln('compile $entrypoint');
    await compileCompleter.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException('Initial compile timed out'),
    );
    process.stdin.writeln('accept');
  }

  Future<double> recompile({
    required String entrypoint,
    required String editedFile,
  }) async {
    recompileCompleter = Completer<String>();
    final boundary = 'boundary-${DateTime.now().millisecondsSinceEpoch}';
    final statBefore = _readProcStat(process.pid);
    final schedBefore = _readSchedSeconds(process.pid);
    final stopwatch = Stopwatch()..start();

    process.stdin.writeln('recompile $entrypoint $boundary');
    if (editedFile.isNotEmpty) process.stdin.writeln(editedFile);
    process.stdin.writeln(boundary);

    await recompileCompleter!.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException('Recompile timed out'),
    );
    stopwatch.stop();
    final statAfter = _readProcStat(process.pid);
    final schedAfter = _readSchedSeconds(process.pid);
    process.stdin.writeln('accept');

    if (schedBefore != null && schedAfter != null && schedAfter > schedBefore) {
      return schedAfter - schedBefore;
    }
    if (statBefore != null && statAfter != null) {
      final deltaTicks = statAfter.totalTicks - statBefore.totalTicks;
      return deltaTicks > 0 ? (deltaTicks / 100.0) : 0.001;
    }
    return stopwatch.elapsedMicroseconds / 1000000.0;
  }

  /// Resets the compiler and compiles everything again, untimed.
  ///
  /// A recompile writes only the libraries that changed, and that delta has
  /// no entrypoint of its own. This returns the path of a full kernel of the
  /// edited program, which the VM can run.
  Future<String> compileFull(String entrypoint) async {
    process.stdin.writeln('reset');
    recompileCompleter = Completer<String>();
    process.stdin.writeln('compile $entrypoint');
    await recompileCompleter!.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException('Full compile timed out'),
    );
    process.stdin.writeln('accept');
    return outputDill;
  }

  Future<void> close() async {
    try {
      process.stdin.writeln('quit');
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      stderr.writeln('Frontend server shutdown timed out or failed: $e');
      process.kill();
    }
  }
}

/// Command-line flag that makes the runner binary act as this driver.
const incrementalDriverFlag = '--incremental_driver';

/// Parsed command line of the incremental driver.
final class _DriverOptions {
  _DriverOptions(Map<String, String> flags)
    : sdkRoot = flags['sdk-root'] ?? '',
      dartaotruntime =
          flags['dartaotruntime'] ??
          '${flags['sdk-root'] ?? ''}/bin/dartaotruntime',
      frontendServer = flags['frontend-server'] ?? '',
      platform = flags['platform'] ?? '',
      entrypoint = flags['entrypoint'] ?? '',
      outputDill = flags['output-dill'] ?? '',
      editedFile = flags['edited-file'] ?? '',
      editedUri = flags['edited-uri'] ?? flags['edited-file'] ?? '',
      preEditFile = flags['pre-edit-file'] ?? '',
      packages = flags['packages'] ?? '',
      scheme = flags['filesystem-scheme'] ?? '',
      roots = (flags['filesystem-roots'] ?? '')
          .split(',')
          .where((r) => r.isNotEmpty)
          .toList(),
      mode = flags['mode'] ?? 'body';

  final String sdkRoot;
  final String dartaotruntime;
  final String frontendServer;
  final String platform;
  final String entrypoint;
  final String outputDill;
  final String editedFile;
  final String editedUri;
  final String preEditFile;
  final String packages;
  final String scheme;
  final List<String> roots;
  final String mode;

  bool get isComplete =>
      sdkRoot.isNotEmpty &&
      frontendServer.isNotEmpty &&
      entrypoint.isNotEmpty &&
      outputDill.isNotEmpty;

  List<String> get serverArguments => [
    frontendServer,
    '--sdk-root=$sdkRoot',
    '--incremental',
    '--platform=$platform',
    if (packages.isNotEmpty) '--packages=$packages',
    if (scheme.isNotEmpty) '--filesystem-scheme=$scheme',
    for (final root in roots) '--filesystem-root=$root',
    '--output-dill=$outputDill',
    '--target=vm',
  ];
}

/// Runs the untimed first compile on the pre-edit source, then the timed
/// recompile after the edit, and finally an untimed full-kernel recompile.
Future<void> _runSession(_CompilerSession session, _DriverOptions o) async {
  final editedPath = o.editedFile;
  final editedText = editedPath.isEmpty
      ? null
      : File(editedPath).readAsStringSync();
  try {
    if (editedText != null && o.preEditFile.isNotEmpty) {
      File(editedPath)
          .writeAsStringSync(File(o.preEditFile).readAsStringSync());
    }
    await session.initialCompile(o.entrypoint);
    if (editedText != null) File(editedPath).writeAsStringSync(editedText);
    var cpuSeconds = 0.0;
    if (o.mode != 'compile-only') {
      cpuSeconds = await session.recompile(
        entrypoint: o.entrypoint,
        editedFile: o.editedUri,
      );
    }
    final fullDill = o.mode == 'compile-only'
        ? o.outputDill
        : await session.compileFull(o.entrypoint);
    await session.close();
    stdout.writeln(
      jsonEncode({
        'status': 'ok',
        'cpuSeconds': cpuSeconds,
        'outputDill': fullDill,
      }),
    );
  } on Object catch (e) {
    if (editedText != null) File(editedPath).writeAsStringSync(editedText);
    await session.close();
    stdout.writeln(
      jsonEncode({
        'status': 'error',
        'reason':
            'Incremental compilation error: $e (errors: ${session.errors})',
      }),
    );
    exit(1);
  }
}

/// Entry point of the incremental driver, given its `--key=value` [args].
Future<void> runIncrementalDriver(List<String> args) async {
  final options = _DriverOptions(_parseArgs(args));
  if (!options.isComplete) {
    stdout.writeln(
      jsonEncode({
        'status': 'error',
        'reason': 'Missing required arguments for incremental driver',
      }),
    );
    exit(1);
  }
  final proc = await Process.start(
    options.dartaotruntime,
    options.serverArguments,
  );
  await _runSession(_CompilerSession(proc, options.outputDill), options);
}
