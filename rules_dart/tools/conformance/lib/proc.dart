/// Runs one command of a builder, logging it and its output.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The outcome of one command.
class Run {
  Run(this.display, this.exitCode, this.stdout, this.stderr, this.seconds);

  final String display;
  final int exitCode;
  final String stdout;
  final String stderr;
  final double seconds;

  bool get ok => exitCode == 0;

  /// One line that says what went wrong, clipped: see [failureLineOf].
  String failureLine() => failureLineOf('$stderr\n$stdout');
}

/// What went wrong, from a command's output: Bazel's first `ERROR:` line
/// that is not a header ending in `:`, with the compiler's own first error
/// line when it reports a failed action; else the first line mentioning an
/// error with the three lines after it; else the last non-empty line.
String failureLineOf(String output) {
  final List<String> lines = [
    for (final l in const LineSplitter().convert(output))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  String clip(String s) => s.length > 300 ? '${s.substring(0, 300)}...' : s;
  final int bazel = lines.indexWhere(
    (l) => l.startsWith('ERROR:') && !l.endsWith(':'),
  );
  if (bazel >= 0) {
    var line = lines[bazel];
    if (line.contains('failed: (Exit')) {
      line = line.substring(0, line.indexOf('failed: (Exit') + 'failed'.length);
      final String detail = lines
          .skip(bazel + 1)
          .where((l) => !l.startsWith('ERROR:') && !l.startsWith('['))
          .firstWhere(
            (l) => RegExp(r'error', caseSensitive: false).hasMatch(l),
            orElse: () => '',
          );
      if (detail.isNotEmpty) line = '$line: $detail';
    }
    return clip(line);
  }
  final int error = lines.indexWhere(
    (l) => RegExp(r'\berror\b', caseSensitive: false).hasMatch(l),
  );
  if (error >= 0) return clip(lines.skip(error).take(4).join(' '));
  return clip(lines.isEmpty ? '' : lines.last);
}

/// Variables `bazel run` sets for the harness itself, which must not reach
/// the tools it starts: a nested Bazel or `dart test` would read them as
/// their own.
const _runOnly = {
  'BUILD_WORKSPACE_DIRECTORY',
  'BUILD_WORKING_DIRECTORY',
  'RUNFILES_DIR',
  'RUNFILES_MANIFEST_FILE',
  'JAVA_RUNFILES',
  'PYTHON_RUNFILES',
  'TEST_SRCDIR',
};

/// The harness's environment without what `bazel run` added.
Map<String, String> childEnvironment([Map<String, String>? base]) => {
  for (final MapEntry(:key, :value) in (base ?? Platform.environment).entries)
    if (!_runOnly.contains(key)) key: value,
};

/// Runs [cmd] in [cwd], appending the command and its output to [log], and
/// kills it after [timeout].
Future<Run> run(
  List<String> cmd, {
  required String cwd,
  required File log,
  Duration timeout = const Duration(hours: 1),
  Map<String, String>? environment,
}) async {
  final display = cmd.map(_quote).join(' ');
  log.parent.createSync(recursive: true);
  log.writeAsStringSync('\$ (cd $cwd && $display)\n', mode: FileMode.append);
  stderr.writeln('conformance: $display  [in $cwd]');
  final watch = Stopwatch()..start();
  final Process p;
  try {
    p = await Process.start(
      cmd.first,
      cmd.sublist(1),
      workingDirectory: cwd,
      environment: environment ?? childEnvironment(),
      includeParentEnvironment: false,
    );
  } on ProcessException catch (e) {
    log.writeAsStringSync(
      'cannot start: ${e.message}\n',
      mode: FileMode.append,
    );
    return Run(display, 127, '', 'cannot start ${cmd.first}: ${e.message}', 0);
  }
  final Future<String> out = p.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final Future<String> err = p.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final int code = await p.exitCode.timeout(
    timeout,
    onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return 124;
    },
  );
  final result = Run(
    display,
    code,
    await out,
    await err,
    watch.elapsedMilliseconds / 1000,
  );
  log.writeAsStringSync(
    '${result.stdout}\n--- stderr\n${result.stderr}\n--- exit $code, '
    '${result.seconds.toStringAsFixed(1)} s\n\n',
    mode: FileMode.append,
  );
  return result;
}

String _quote(String s) =>
    RegExp(r'^[A-Za-z0-9_./=:@+,%-]+$').hasMatch(s) ? s : "'$s'";

/// Copies [from] into [to] (created), skipping the top-level entries named
/// in [skip] and directories named in [skipAnywhere] at any depth. Symbolic
/// links are copied as the files they point to.
void copyTree(
  Directory from,
  Directory to, {
  Set<String> skip = const {},
  Set<String> skipAnywhere = const {},
}) {
  to.createSync(recursive: true);
  for (final e in from.listSync(followLinks: false)) {
    final String name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (skip.contains(name)) continue;
    _copyEntity(e, '${to.path}/$name', skipAnywhere);
  }
}

void _copyEntity(FileSystemEntity e, String dest, Set<String> skipAnywhere) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(e.path);
  if (type == FileSystemEntityType.directory) {
    Directory(dest).createSync(recursive: true);
    for (final c in Directory(e.path).listSync(followLinks: false)) {
      final String name = c.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (skipAnywhere.contains(name) &&
          FileSystemEntity.isDirectorySync(c.path)) {
        continue;
      }
      _copyEntity(c, '$dest/$name', skipAnywhere);
    }
  } else if (type == FileSystemEntityType.file) {
    final File copy = File(e.path).copySync(dest);
    final int mode = File(e.path).statSync().mode & 0x1ff;
    if (mode & 0x49 != 0) {
      // Keep the executable bits (gradlew, a built program): copySync does
      // not carry the mode.
      Process.runSync('chmod', [mode.toRadixString(8), copy.path]);
    }
  }
}
