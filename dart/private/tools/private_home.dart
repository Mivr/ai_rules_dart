// Home-directory policies for subprocesses that start the Dart CLI.
//
// The Dart CLI records telemetry state under the user's home
// (`.dart-tool/CLIENT_ID`, `dart-flutter-telemetry.*`) whenever it runs in
// command form (`dart analyze`, `dart format`, `pub token list`, ...). A bare
// `dart --version` and a file-form execution (`dart program.dart`,
// `dart app.dill`) write nothing. Rule-owned launchers must write nothing
// under the caller's HOME, so every spawn of the Dart CLI goes through one of
// the two policies here:
//
// * Private ([withPrivateHome]): the child gets a fresh directory for HOME
//   and every variable the CLI consults for one, removed afterwards, on
//   success and on failure. For runners whose child needs no caller state
//   (format, fix, analyze, web compile).
// * Caller-home ([suppressAnalyticsArgv]): the child keeps the caller's
//   environment — pub cache, credentials, proxy configuration — and the
//   global `--suppress-analytics` flag is placed before the command, which
//   stops the telemetry write for that run. Only for command-form
//   invocations: the flag is rejected for file-form executions (exit 255),
//   which need no suppression anyway.
import 'dart:io';

/// Home variables pointed at [home] for a Dart CLI run.
///
/// Every variable the Dart CLI (and, on Windows, the .NET-style host paths it
/// inherits) consults for a home or per-user state directory.
Map<String, String> privateHomeEnv(String home) => {
  'HOME': home,
  'USERPROFILE': home,
  'LOCALAPPDATA': home,
  'APPDATA': home,
  'XDG_CONFIG_HOME': home,
  'XDG_CACHE_HOME': home,
  'XDG_DATA_HOME': home,
};

/// Runs [action] with a fresh private home, removed afterwards.
///
/// [action] gets the environment entries pointing at the fresh directory. The
/// directory is removed when [action] returns and when it throws.
T withPrivateHome<T>(
  String prefix,
  T Function(Map<String, String> env) action,
) {
  final home = Directory.systemTemp.createTempSync(prefix);
  try {
    return action(privateHomeEnv(home.path));
  } finally {
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
}

/// Whether [args] to the `dart` CLI is a file-form execution.
///
/// File-form is a program path (`program.dart`, `app.dill`, `app.aot`,
/// `app.snapshot`, `app.jit`), an empty argument list, or global flags only
/// (`--version`, `--verbose` with no command). Everything else names a
/// command (`pub`, `format`, `analyze`, ...) whose run writes telemetry under
/// HOME unless suppressed.
bool isFileExecution(List<String> args) {
  if (args.isEmpty) return true;
  final first = args.first;
  if (first.startsWith('-')) return true;
  const programSuffixes = ['.dart', '.dill', '.snapshot', '.aot', '.jit'];
  for (final suffix in programSuffixes) {
    if (first.toLowerCase().endsWith(suffix)) return true;
  }
  return false;
}

/// [args] with analytics suppressed for a command-form `dart` invocation.
///
/// Inserts the global `--suppress-analytics` flag before the command, which
/// stops that run's telemetry write while the process keeps the caller's
/// environment — pub cache, credentials, proxy configuration. File-form
/// executions pass through unchanged: the flag is rejected there, and they
/// never touch HOME anyway. An [args] that already suppresses analytics is
/// returned unchanged.
List<String> suppressAnalyticsArgv(List<String> args) {
  if (isFileExecution(args)) return args;
  if (args.contains('--suppress-analytics') ||
      args.contains('--no-suppress-analytics')) {
    return args;
  }
  return ['--suppress-analytics', ...args];
}

/// [env] without this ruleset's own `RULES_DART_*` control variables.
///
/// A launcher that keeps the caller's environment for the program it starts
/// still strips these: a nested launcher would otherwise mistake the parent's
/// config paths and runner settings for its own.
Map<String, String> withoutRulesDartControls(Map<String, String> env) => {
  for (final entry in env.entries)
    if (!entry.key.startsWith('RULES_DART_')) entry.key: entry.value,
};
