/// Shared host-Python driving for the iOS screenshot helpers.
///
/// `screenshot` and `tunneld` run their programs through a host `python3`
/// (see `screenshot.dart` for why), so both need the same lookup, the same
/// missing-interpreter diagnostic, and the same spawn plumbing. Dependency-
/// free (`dart:io` only) so the helpers stay standalone `dart_binary` targets.
import 'dart:io';

typedef _Launch = ({
  List<String> arguments,
  Map<String, String> environment,
  String program,
});

/// Names tried on PATH, most preferred first. `python` is a fallback for
/// machines where only that name exists (notably Windows); `python3` stays
/// first so a Python 2 `python` elsewhere on PATH never shadows it.
List<String> get _pythonNames => Platform.isWindows
    ? const ['python', 'python3']
    : const ['python3', 'python'];

/// Candidate file names for [name] in one PATH entry.
List<String> _candidates(String dir, String name) {
  if (Platform.isWindows) {
    return ['$dir\\$name.exe', '$dir\\$name.bat', '$dir\\$name.cmd'];
  }
  return ['$dir/$name'];
}

/// The host Python interpreter to run, or null when there is none.
///
/// Searches each PATH entry for the preferred names (specific files, never
/// a bare name handed to the shell), mirroring the `HostTool` lookup the
/// dev tool uses for `adb` and friends: absence is reported, not guessed.
String? findHostPython() {
  final String path = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  for (final String name in _pythonNames) {
    for (final String dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final String candidate in _candidates(dir, name)) {
        if (FileSystemEntity.isFileSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

/// Diagnostic for a missing interpreter, naming what to install.
String missingPythonMessage({required String purpose}) {
  final String names = _pythonNames.join(' or ');
  return 'Could not find $names on PATH, which is needed for $purpose.\n'
      'Install Python 3 (https://www.python.org/downloads/) and pymobiledevice3:\n'
      '  python3 -m pip install pymobiledevice3';
}

/// Preamble prepended to every program this package runs.
///
/// Python puts the current working directory first on `sys.path` for both
/// launch forms used here (`python -` reads the program from stdin,
/// `python -c` takes it as an argument: `sys.path[0]` is `''` either way).
/// A module sitting in the directory the user runs from would then shadow
/// the real one, and the tunnel daemon runs as root, so this drops the
/// directory entries before the program's own imports run. Only `sys` is
/// imported before the drop, because it is a builtin module: importing
/// anything else first could itself resolve through the hostile directory.
///
/// Defense in depth with [guardedPythonEnvironment]'s `PYTHONSAFEPATH`: that
/// variable only exists from Python 3.11, while this preamble runs on every
/// version down to 3.8. The launcher's working directory is left alone, so a
/// relative screenshot output path still names a file under the directory the
/// user ran from.
const String _pythonPathGuard = r'''
def _flutter_bazel_guard_sys_path():
    import sys as _sys

    for _entry in list(_sys.path):
        if _entry == '' or _entry == '.':
            _sys.path.remove(_entry)
    # The placeholder is gone, so this resolves to the real stdlib.
    import os as _os

    try:
        _cwd = _os.getcwd()
    except OSError:
        return
    for _entry in list(_sys.path):
        try:
            _absolute = _os.path.abspath(_entry)
        except OSError:
            continue
        if _os.path.normcase(_absolute) == _os.path.normcase(_cwd):
            _sys.path.remove(_entry)


_flutter_bazel_guard_sys_path()
del _flutter_bazel_guard_sys_path
''';

/// [program] with the current-directory import guard prepended.
///
/// The single place both launchers ([runPythonProgram] and
/// [runPythonProgramInteractive]) get the protection from: neither keeps its
/// own copy.
String guardPythonProgram(String program) => '$_pythonPathGuard\n$program';

/// Environment variables never forwarded to a guarded host-Python child,
/// with why each one is dropped. The child must resolve its standard library
/// from the interpreter's own installed prefix, whatever the caller holds.
const Map<String, String> _droppedPythonVariables = {
  // A directory the tool did not choose must not outrank the installed
  // packages either.
  'PYTHONPATH': 'untrusted directory outranks installed packages',
  // CPython locates its standard library from this prefix instead of the
  // interpreter's own install, so a tree carrying a hostile `argparse.py`
  // would run attacker code on the payload's own `import argparse`.
  'PYTHONHOME': 'relocates the standard library to a caller-chosen tree',
  // Replaces the platform library directory name under the prefix (`lib`
  // by default), steering the platform standard library the same way.
  'PYTHONPLATLIBDIR': 'relocates the platform standard library directory',
  // Startup file for interactive sessions. Neither launch form below is
  // interactive (`python -` reads from a pipe, `python -c` takes an
  // argument), so nothing the helpers run can need it.
  'PYTHONSTARTUP': 'runs caller-chosen code at interpreter startup',
};

/// The environment a guarded host-Python child runs with.
///
/// Starts from [overrides] over this process's environment, then drops every
/// variable in [_droppedPythonVariables] (so neither an ambient value nor one
/// a caller passes in reaches the child) and sets `PYTHONSAFEPATH=1`
/// (honoured from Python 3.11, ignored before, where the preamble above does
/// the work). User-site installs and virtualenvs keep working: nothing here
/// touches `site`, `PYTHONUSERBASE`, or the interpreter's own prefix, and the
/// macOS `__PYVENV_LAUNCHER__` lookup stays in place. `PYTHONNOUSERSITE` is
/// forwarded untouched: the guard never widens what loads, so a user who
/// switched the user site off keeps it off. Pass with
/// `includeParentEnvironment: false` so the dropped variables stay dropped.
Map<String, String> guardedPythonEnvironment([
  Map<String, String>? overrides,
]) {
  final env = Map<String, String>.from(Platform.environment);
  if (overrides != null) env.addAll(overrides);
  for (final String name in _droppedPythonVariables.keys) {
    env.remove(name);
  }
  env['PYTHONSAFEPATH'] = '1';
  return env;
}

/// Whether this process runs as root (POSIX `id -u`; always false where
/// that question has no meaning).
bool isRoot() {
  if (Platform.isWindows) return false;
  try {
    final ProcessResult result = Process.runSync('id', ['-u']);
    return result.exitCode == 0 && (result.stdout as String).trim() == '0';
  } on ProcessException {
    return false;
  }
}

/// A guarded host-Python launch: the interpreter arguments carrying [program],
/// the environment the child runs with, and the guarded program text itself.
///
/// The single place both launchers ([runPythonProgram] and
/// [runPythonProgramInteractive]) get all three from: neither builds its own
/// arguments or environment. [interactive] selects the carrier: `false`
/// sends the program on stdin (`python - ...`, for the short-lived helper
/// whose stdin is free) and `true` sends it as an argument (`python -c ...`,
/// for the long-lived daemon whose stdin is the terminal). [environment] is
/// passed through to [guardedPythonEnvironment], so a caller-supplied
/// `PYTHONHOME` is dropped exactly like an ambient one.
({List<String> arguments, Map<String, String> environment, String program})
guardedPythonLaunch(
  String program,
  List<String> args, {
  required bool interactive,
  Map<String, String>? environment,
}) {
  final String guarded = guardPythonProgram(program);
  return (
    arguments: [
      if (interactive) '-c' else '-',
      if (interactive) guarded,
      ...args,
    ],
    environment: guardedPythonEnvironment(environment),
    program: guarded,
  );
}

/// Runs [program] with [python], forwarding its stdout/stderr and returning
/// its exit code. The program travels on stdin (`python - ...`), so no
/// source file is staged anywhere; [args] reach it as `sys.argv[1:]`.
///
/// When the run fails because `pymobiledevice3` is not installed, the
/// interpreter's own `ModuleNotFoundError` is followed by the install
/// remedy (the program's other diagnostics pass through verbatim, since
/// callers match on them).
Future<int> runPythonProgram(
  String python,
  String program,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final _Launch launch = guardedPythonLaunch(
    program,
    args,
    interactive: false,
    environment: environment,
  );
  final Process process = await Process.start(
    python,
    launch.arguments,
    workingDirectory: workingDirectory,
    environment: launch.environment,
    includeParentEnvironment: false,
  );
  process.stdin.write(launch.program);
  await process.stdin.close();
  final stderrBytes = <int>[];
  await Future.wait([
    stdout.addStream(process.stdout),
    process.stderr.listen((chunk) {
      stderr.add(chunk);
      stderrBytes.addAll(chunk);
    }).asFuture<void>(),
  ]);
  final int exitCode = await process.exitCode;
  if (exitCode != 0) {
    final stderrText = String.fromCharCodes(stderrBytes);
    if (stderrText.contains('ModuleNotFoundError') &&
        stderrText.contains('pymobiledevice3')) {
      stderr.writeln(
        "pymobiledevice3 is not installed for $python, which iOS device commands need.\n"
        'Install it:\n'
        '  $python -m pip install pymobiledevice3',
      );
    }
  }
  return exitCode;
}

/// Runs [program] with [python] as a long-lived foreground process: stdio
/// is the terminal's, and the program travels as `python -c` (stdin is
/// taken, so it cannot carry the program). Returns the exit code.
Future<int> runPythonProgramInteractive(
  String python,
  String program,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final _Launch launch = guardedPythonLaunch(
    program,
    args,
    interactive: true,
    environment: environment,
  );
  final Process process = await Process.start(
    python,
    launch.arguments,
    mode: ProcessStartMode.inheritStdio,
    workingDirectory: workingDirectory,
    environment: launch.environment,
    includeParentEnvironment: false,
  );
  return process.exitCode;
}
