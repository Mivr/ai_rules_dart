// Home-directory policies for subprocesses that start the Dart CLI.
//
// Two different programs can receive a `dart` argument list. The VM handles a
// program file (`dart program.dart`, `dart app.dill`, ...) and a bare
// `dart --version` itself, and writes nothing under HOME. Every other form
// reaches dartdev, the CLI frontend: commands (`pub`, `format`, ...), but also
// a bare `dart`, `dart --help`, `dart -h`, `dart --verbose` and `dart help`,
// which print usage. dartdev records telemetry state under the user's home
// (`.dart-tool/CLIENT_ID`, `dart-flutter-telemetry.*`, the dismissed-surveys
// file) whenever it runs.
//
// Rule-owned launchers must write nothing under the caller's HOME, so every
// spawn of the Dart CLI goes through one of the three policies here:
//
// * Pass-through ([DartCliPolicy.callerHome]): the VM handles the arguments
//   and writes nothing; the child keeps the caller's environment.
// * Suppression ([DartCliPolicy.suppressAnalytics]): a command form, where the
//   global `--suppress-analytics` flag stops the telemetry write while the
//   child keeps the caller's environment — pub cache, credentials, proxy
//   configuration.
// * Private ([DartCliPolicy.privateHome]): a form that reaches dartdev without
//   a command (a bare CLI, help or verbose flags alone, the `help` command).
//   The flag alone does not cover those on the pinned SDK: a `--verbose` after
//   it re-enables the write. The child gets a fresh directory for HOME and
//   every variable the CLI consults for one, removed afterwards, on success
//   and on failure.
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
  'XDG_STATE_HOME': home,
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
    _removePrivateHome(home);
  }
}

/// Runs [action] with a fresh private home, removed afterwards.
///
/// The asynchronous counterpart of [withPrivateHome], for a child process
/// whose exit must be awaited before the directory can be deleted. [action]
/// gets the environment entries pointing at the fresh directory; the
/// directory is removed when the returned future completes and when it fails.
Future<T> withPrivateHomeAsync<T>(
  String prefix,
  Future<T> Function(Map<String, String> env) action,
) async {
  final home = Directory.systemTemp.createTempSync(prefix);
  try {
    return await action(privateHomeEnv(home.path));
  } finally {
    _removePrivateHome(home);
  }
}

/// Deletes a private home created by [withPrivateHome] or
/// [withPrivateHomeAsync].
///
/// A failed recursive delete on Windows (a child still holds the directory)
/// must not mask the child's own result; the directory lives under the system
/// temp directory, so the OS reclaims it later.
void _removePrivateHome(Directory home) {
  if (!home.existsSync()) return;
  try {
    home.deleteSync(recursive: true);
  } on FileSystemException {
    // Ignore cleanup errors; see the documentation above.
  }
}

/// How the SDK launcher must run a `dart` argument list so it writes nothing
/// under the caller's home directories.
enum DartCliPolicy {
  /// The VM handles the arguments (a program file, or `--version` on its own)
  /// and writes nothing; keep the caller's environment and arguments.
  callerHome,

  /// dartdev runs a command and honours the global `--suppress-analytics`
  /// flag; keep the caller's environment and add that flag.
  suppressAnalytics,

  /// dartdev runs without a command, where the flag alone is not enough; run
  /// with a fresh private home.
  privateHome,
}

/// Suffixes that make the first positional argument a program the VM runs
/// directly instead of a command dartdev handles.
const List<String> _programSuffixes = [
  '.dart',
  '.dill',
  '.snapshot',
  '.aot',
  '.jit',
];

/// The number of leading global options in [args], before the first
/// positional argument.
///
/// Global options start with `-`; the first argument that does not is the
/// program file or command dartdev dispatches on.
int _globalOptionCount(List<String> args) {
  var count = 0;
  while (count < args.length && args[count].startsWith('-')) {
    count++;
  }
  return count;
}

/// Whether [arg] names a program file the VM executes directly.
bool _isProgramFile(String arg) {
  final lower = arg.toLowerCase();
  for (final suffix in _programSuffixes) {
    if (lower.endsWith(suffix)) return true;
  }
  return false;
}

/// Whether [globals] asks only for the SDK version, with optional verbose
/// output.
///
/// The VM answers this form itself, so it writes no telemetry. Adding a help
/// flag or any other option sends the arguments to dartdev instead.
bool _isVersionInvocation(Iterable<String> globals) {
  var version = false;
  for (final option in globals) {
    if (option == '--version') {
      version = true;
    } else if (option != '-v' && option != '--verbose') {
      return false;
    }
  }
  return version;
}

/// Which HOME policy a `dart` argument list needs.
///
/// Dart routes an argument list to the VM when its first positional argument
/// names a program file ([_programSuffixes]) or when the list is `--version`
/// with optional verbose flags. Every other list reaches dartdev: commands run
/// with the suppression flag, while a bare CLI, a help or verbose flag with no
/// command, and the `help` command print usage through dartdev and get a
/// private home. A leading global `--suppress-analytics` is kept as the caller
/// wrote it, never duplicated.
DartCliPolicy dartCliPolicy(List<String> args) {
  final globalCount = _globalOptionCount(args);
  final globals = args.take(globalCount);
  if (globalCount == args.length) {
    return _isVersionInvocation(globals)
        ? DartCliPolicy.callerHome
        : DartCliPolicy.privateHome;
  }
  final first = args[globalCount];
  if (_isProgramFile(first)) return DartCliPolicy.callerHome;
  if (first == 'help') return DartCliPolicy.privateHome;
  if (globals.contains('--suppress-analytics')) {
    return DartCliPolicy.callerHome;
  }
  return DartCliPolicy.suppressAnalytics;
}

/// [args] with analytics suppressed for a command-form `dart` invocation.
///
/// Inserts the global `--suppress-analytics` flag before the first argument,
/// which stops that run's telemetry write while the process keeps the caller's
/// environment — pub cache, credentials, proxy configuration. Only for an
/// argument list [dartCliPolicy] classified as
/// [DartCliPolicy.suppressAnalytics]: file-form and VM invocations reject the
/// flag, and a usage form needs a private home instead. A leading global
/// `--suppress-analytics` passes through unchanged, never duplicated; nothing
/// else is ever reordered.
List<String> suppressAnalyticsArgv(List<String> args) {
  final globals = args.take(_globalOptionCount(args));
  if (globals.contains('--suppress-analytics')) return args;
  return ['--suppress-analytics', ...args];
}

/// [env] without this ruleset's own `RULES_DART_*` control variables.
///
/// A launcher that keeps the caller's environment for the program it starts
/// still strips these: a nested launcher would otherwise mistake the parent's
/// config paths and runner settings for its own. Dart merges an
/// `environment:` map over the parent environment, so the stripped variables
/// reach the child anyway unless the spawn passes this map with
/// `includeParentEnvironment: false`.
Map<String, String> withoutRulesDartControls(Map<String, String> env) => {
  for (final entry in env.entries)
    if (!entry.key.startsWith('RULES_DART_')) entry.key: entry.value,
};
