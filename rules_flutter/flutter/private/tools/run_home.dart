/// Shared HOME-hermeticity helper for runnable targets (RT37-flutter:02).
///
/// Every entry point a user can `bazel run` routes through here. The Dart CLI
/// writes dartdev telemetry (`.dart-tool/CLIENT_ID`,
/// `dart-flutter-telemetry*`, the dismissed-surveys file) whenever its front
/// end runs, and the global `--suppress-analytics` flag stops that write only
/// for command form. The launcher therefore uses one of two policies, chosen
/// by [runHomePolicy]:
///
/// * caller-home-suppressed: a command (`dart pub ...`, `dart format ...`,
///   `dart help`) keeps the caller's environment so `PUB_CACHE` and
///   credentials resolve, and [suppressAnalyticsFlag] is placed before the
///   command. The flag is global, so it must precede the command.
/// * private: a program file (`dart program.dart`) and an argv with no
///   positional argument at all (`dart`, `dart --help`, `dart --verbose`,
///   `dart --version`) run under a fresh directory for every home-locating
///   key ([privateHomeEnv]), removed afterwards ([createPrivateHome]). The VM
///   rejects the suppression flag for a program file (exit 255), and dartdev
///   still writes telemetry for `--verbose` even when the flag is present, so
///   a private home is the guarantee that holds for both.
///
/// An argv that already carries [noSuppressAnalyticsFlag] states that the
/// caller wants analytics; it still runs under a private home so the caller's
/// directories stay untouched. User app/test code keeps the caller env; only
/// rule-owned launchers and tool CLIs are routed through this library (plus
/// its shell counterpart `RUN_HOME_SH` in
/// `//flutter/private:run_home.bzl`, used where the launcher is a shell
/// template).
library;

import 'dart:io';

/// Env keys through which the dart CLI, pub, flutter_tools, or the Dart VM
/// locate per-user state (telemetry, credentials, caches), on POSIX and on
/// Windows.
const homeEnvKeys = <String>[
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'XDG_CONFIG_HOME',
  'XDG_CACHE_HOME',
  'XDG_DATA_HOME',
];

/// Global dart/flutter CLI flag disabling analytics and telemetry writes.
///
/// Command-form only: the flag must precede the command (`dart
/// --suppress-analytics pub ...`). The Dart VM rejects it for file-form
/// executions (`dart program.dart` exits 255), which run under a private home
/// instead ([runHomePolicy]). Verified against the pinned toolchain: `dart
/// --suppress-analytics pub token list` exits 0, writes nothing under
/// `$HOME`, and still prints the caller's `XDG_CONFIG_HOME/dart/pub-tokens.json`
/// credentials. `dart --suppress-analytics --verbose` still writes telemetry,
/// so an argv with no command gets a private home rather than the flag alone.
const suppressAnalyticsFlag = '--suppress-analytics';

/// Explicit opt-out twin of [suppressAnalyticsFlag]: an argument list holding
/// either flag already states its analytics policy. A leading opt-out routes
/// the run to a private home so the caller's directories stay clean; the flag
/// itself is never duplicated and nothing is reordered.
const noSuppressAnalyticsFlag = '--no-suppress-analytics';

/// Suffixes naming a runnable program file for the `dart` CLI, matched
/// case-insensitively against the first non-flag argument.
const programFileSuffixes = <String>[
  '.dart',
  '.dill',
  '.snapshot',
  '.aot',
  '.jit',
];

/// The home policy a launcher must apply for one `dart` argv.
enum RunHomePolicy {
  /// Command form: keep the caller env and prepend [suppressAnalyticsFlag].
  callerHomeSuppressed,

  /// Program file or flags with no command: use a fresh private home and
  /// pass the arguments through unchanged.
  privateHome,
}

/// The leading dash arguments of [args], before the first non-flag argument.
List<String> _leadingFlags(List<String> args) {
  final flags = <String>[];
  for (final arg in args) {
    if (!arg.startsWith('-')) break;
    flags.add(arg);
  }
  return flags;
}

/// The arguments from the first non-flag argument onwards.
List<String> _positionalArgs(List<String> args) =>
    args.sublist(_leadingFlags(args).length);

/// Whether [arg] names a program file for the `dart` CLI.
bool _isProgramFile(String arg) {
  final String first = arg.toLowerCase();
  return programFileSuffixes.any(first.endsWith);
}

/// Whether [args] to the `dart` CLI run a program file.
///
/// Skips leading arguments starting with `-` (global flags such as
/// `--enable-asserts`), then the first non-flag argument is a program file
/// when it ends, case-insensitively, in a [programFileSuffixes] entry
/// (`program.dart`, `app.dill`, ...). An argv with no positional argument is
/// not a program file: the dart CLI then runs its front end (`dart`,
/// `dart --help`, `dart --verbose`), which can write telemetry on its own.
/// A command (`pub`, `format`, `help`, ...) is not a program file either.
/// Mirrors the shell launcher (`RUN_HOME_SH` in
/// `//flutter/private:run_home.bzl` and the Windows `.bat` in
/// `//flutter/private:flutter_sdk_binary.bzl`).
bool isFileForm(List<String> args) {
  final List<String> rest = _positionalArgs(args);
  if (rest.isEmpty) return false;
  return _isProgramFile(rest.first);
}

/// Whether [args] name a command the `dart` CLI handles in command form.
///
/// The remaining case after [isFileForm] and an argv with no positional
/// argument: the first non-flag argument is a command such as `pub`, `format`
/// or `help`.
bool _isCommandForm(List<String> args) {
  final List<String> rest = _positionalArgs(args);
  return rest.isNotEmpty && !_isProgramFile(rest.first);
}

/// The home policy for [args] that guarantees nothing is written under the
/// caller's home directories.
///
/// * A leading [noSuppressAnalyticsFlag] asks for analytics, so the run gets a
///   private home; the flag is left where the caller put it.
/// * An argv with no positional argument (`dart`, `dart --help`,
///   `dart --verbose`, `dart --version`) gets a private home: dartdev runs and
///   the flag does not stop every form (`--verbose` still writes telemetry).
/// * A program file ([isFileForm]) gets a private home: the VM rejects the
///   suppression flag (exit 255).
/// * Everything else is command form ([_isCommandForm]): the caller env is
///   kept and [withSuppressedAnalytics] prepends the flag.
RunHomePolicy runHomePolicy(List<String> args) {
  if (_leadingFlags(args).contains(noSuppressAnalyticsFlag)) {
    return RunHomePolicy.privateHome;
  }
  if (isFileForm(args)) return RunHomePolicy.privateHome;
  if (!_isCommandForm(args)) return RunHomePolicy.privateHome;
  return RunHomePolicy.callerHomeSuppressed;
}

/// Returns [args] with [suppressAnalyticsFlag] inserted before the command,
/// unless the run already carries an analytics policy.
///
/// The flag is global, so it must precede the command (`dart
/// --suppress-analytics pub ...`); appending it after the command would make
/// pub reject it. Only a [RunHomePolicy.callerHomeSuppressed] argv takes the
/// flag. Program files and argv with no command ([runHomePolicy] returns a
/// private home for those) pass through unchanged: the VM rejects the flag
/// there (exit 255), and dartdev still writes telemetry for `--verbose` when
/// the flag is present. An argv holding a leading [suppressAnalyticsFlag] or
/// [noSuppressAnalyticsFlag] states its analytics policy already; nothing is
/// duplicated and nothing else is ever reordered.
List<String> withSuppressedAnalytics(List<String> args) {
  if (runHomePolicy(args) != RunHomePolicy.callerHomeSuppressed) return args;
  if (_leadingFlags(args).contains(suppressAnalyticsFlag)) return args;
  return <String>[suppressAnalyticsFlag, ...args];
}

/// Creates a fresh private home dir under [parent]. The caller removes it
/// afterwards; integration launchers use their own scratch lifecycle, while
/// single spawns (such as `flutter_tester`) delete it once the child exits.
Directory createPrivateHome(String parent) =>
    Directory(parent).createTempSync('run-home-');

/// Env overrides routing every home-locating key at [dir]. Merge over the
/// launcher's env (or the parent env for single spawns); everything else is
/// inherited unchanged.
Map<String, String> privateHomeEnv(String dir) => <String, String>{
  for (final key in homeEnvKeys) key: dir,
};
