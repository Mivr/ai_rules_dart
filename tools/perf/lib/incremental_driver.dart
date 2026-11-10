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
    process.stdin.writeln('accept');

    if (statBefore != null && statAfter != null) {
      final deltaTicks = statAfter.totalTicks - statBefore.totalTicks;
      return deltaTicks > 0 ? (deltaTicks / 100.0) : 0.001;
    }
    return stopwatch.elapsedMicroseconds / 1000000.0;
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

Future<void> _runSession({
  required _CompilerSession session,
  required String entrypoint,
  required String editedFile,
  required String outputDill,
  required String mode,
}) async {
  try {
    await session.initialCompile(entrypoint);
    if (mode == 'compile-only') {
      await session.close();
      stdout.writeln(
        jsonEncode({
          'status': 'ok',
          'cpuSeconds': 0.0,
          'outputDill': outputDill,
        }),
      );
      return;
    }

    final cpuSeconds = await session.recompile(
      entrypoint: entrypoint,
      editedFile: editedFile,
    );
    await session.close();

    final incDill = '$outputDill.incremental.dill';
    final finalDill = File(incDill).existsSync() ? incDill : outputDill;

    stdout.writeln(
      jsonEncode({
        'status': 'ok',
        'cpuSeconds': cpuSeconds,
        'outputDill': finalDill,
      }),
    );
  } on Object catch (e) {
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

Future<void> main(List<String> args) async {
  final flags = _parseArgs(args);
  final sdkRoot = flags['sdk-root'] ?? '';
  final dartaotruntime =
      flags['dartaotruntime'] ?? '$sdkRoot/bin/dartaotruntime';
  final frontendServer = flags['frontend-server'] ?? '';
  final platform = flags['platform'] ?? '';
  final entrypoint = flags['entrypoint'] ?? '';
  final outputDill = flags['output-dill'] ?? '';
  final editedFile = flags['edited-file'] ?? '';
  final packages = flags['packages'];
  final mode = flags['mode'] ?? 'body';

  if (sdkRoot.isEmpty ||
      frontendServer.isEmpty ||
      entrypoint.isEmpty ||
      outputDill.isEmpty) {
    stdout.writeln(
      jsonEncode({
        'status': 'error',
        'reason': 'Missing required arguments for incremental driver',
      }),
    );
    exit(1);
  }

  final proc = await Process.start(dartaotruntime, [
    frontendServer,
    '--sdk-root=$sdkRoot',
    '--incremental',
    '--platform=$platform',
    if (packages != null && packages.isNotEmpty) '--packages=$packages',
    '--output-dill=$outputDill',
    '--target=vm',
  ]);

  final session = _CompilerSession(proc, outputDill);
  await _runSession(
    session: session,
    entrypoint: entrypoint,
    editedFile: editedFile,
    outputDill: outputDill,
    mode: mode,
  );
}
