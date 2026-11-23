# Run-HOME hermeticity

No runnable target may let the dart CLI, pub, flutter_tools, or the Dart
VM write telemetry or state into the caller's `HOME` (RT37-flutter:02:
`CLIENT_ID` and `dart-flutter-telemetry-*` appearing under `~/.dart-tool`
after `bazel run //flutter:pub`).

## The two policies

The policy is chosen per argv by `runHomePolicy`, not by a short list of
reported spellings:

- Caller-home: a command the dart CLI handles in command form (`dart pub
  ...`, `dart format ...`, `dart help`) must resolve the caller's
  `PUB_CACHE` and credentials, so the parent environment is kept and the
  global `--suppress-analytics` flag is placed before the command. Applies
  to `//dart:dart` (SDK pass-through) and `//flutter:pub`.
- Private: the spawned program gets a fresh dir for `HOME`,
  `USERPROFILE`, `LOCALAPPDATA`, `APPDATA`, `XDG_CONFIG_HOME`,
  `XDG_CACHE_HOME`, and `XDG_DATA_HOME`, removed afterwards. Applies to a
  program file (`dart program.dart`), an argv with no positional argument
  (`dart`, `dart --help`, `dart --verbose`, `dart --version`), an explicit
  `--no-suppress-analytics`, the `flutter_tester` spawn, and the web/Linux
  integration launchers (browser profile, Xvfb, desktop app).

User app and test code keeps the caller env; only rule-owned launchers
and tool CLIs are routed through the helper.

## The helper

`flutter/private/tools/run_home.dart` is the single source: `homeEnvKeys`,
`suppressAnalyticsFlag`, `runHomePolicy`, `withSuppressedAnalytics` (the
flag before the command for command form only, never duplicated),
`isFileForm` (a program file only), `createPrivateHome`, `privateHomeEnv`.
The integration launchers' old per-launcher scrubs fold into it — there is
one copy of the key list.

The flag is command-form only: the Dart VM rejects `--suppress-analytics`
for a program-file execution (`dart program.dart` exits 255), so a program
file runs under a private HOME with its arguments unchanged. An argv with
no positional argument also runs under a private HOME: dartdev runs its
front end and writes telemetry, and the flag does not stop every form —
`dart --suppress-analytics --verbose` still writes on the pinned SDK.
`--version`, `dart --help`, `-h`, `--verbose` and the combinations of the
help and verbose flags therefore all get the private HOME. An explicit
`--no-suppress-analytics` asks for analytics, so it also gets a private
HOME: the caller's directories stay clean and the flag is not duplicated.
Leading dash-arguments are skipped before deciding: `--verbose pub get`
still takes the suppression flag, while `--enable-asserts hello.dart`
stays a program-file run.

Launchers that are shell templates cannot import Dart, so
`flutter/private/run_home.bzl` carries the shell counterpart
(`RUN_HOME_SH`, plus `RUN_HOME_SUPPRESS_ANALYTICS` for the Windows
launcher). The two copies are asserted equal by
`//flutter/private/tools:run_home_test`; update them together.

## The gate

`e2e/run_home` is a self-contained workspace with one instance of every
`bazel run`-capable entry point. `registry.tsv` records label, args, and
HOME policy per entry; `audit.tsv` records every other executable target
with the reason it is out of class. `run_home_test.sh` replays the
registry's `bazel query` enumeration (an unregistered or missing entry
fails the run), then executes each entry under canary home dirs and fails
naming any entry that creates, changes, or removes canary content. That
includes the file-form probe and every help/verbose/version shape: each
one pins both its exit code and output and leaves every canary dir
unchanged. It runs in Linux CI.

## Adding an entry point

1. Add a runnable instance to `e2e/run_home/BUILD.bazel` (or record why
   the target cannot run headless).
2. Add the row to `registry.tsv` (run rows) or `audit.tsv`
   (out-of-class, with reason), using the shared helper for its launcher.
3. The gate fails until the new entry is both registered and clean.

Bazel itself never runs with the canary variables: each entry is staged
first under the caller's environment (`bazel run --script_path=...`), and
only the generated stage script runs under the canaries.
