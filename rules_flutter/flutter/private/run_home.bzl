"""Shared HOME-hermeticity constants for shell-template launchers (RT37-flutter:02).

`flutter/private/tools/run_home.dart` is the source of truth; this file is
its shell counterpart for launchers that are shell templates and cannot
import Dart. `RUN_HOME_SUPPRESS_ANALYTICS` must equal the Dart
`suppressAnalyticsFlag`, and `RUN_HOME_SH` must implement the same policy as
the Dart `runHomePolicy`: command form keeps the caller env and prepends the
analytics flag; a program file or an argv with no positional argument runs
under a private home. `//flutter/private/tools/test/run_home_test.dart`
asserts the flag, the classification markers, and a shared table of cases
agree, so update them together.
"""

visibility(["//flutter/..."])

RUN_HOME_SUPPRESS_ANALYTICS = "--suppress-analytics"

RUN_HOME_SH = """\
# run_home counterpart: exec a tool CLI either in command form, keeping the
# caller env (so PUB_CACHE and credentials resolve) and suppressing CLI
# telemetry writes with the global flag, or under a fresh private home when
# the flag cannot give that guarantee. Mirrors runHomePolicy in
# flutter/private/tools/run_home.dart:
# * a leading --no-suppress-analytics asks for analytics, so it runs under a
#   private home and the caller's directories stay clean;
# * a program file (first non-flag argument ending in
#   .dart/.dill/.snapshot/.aot/.jit, any case) runs under a private home: the
#   VM rejects the flag there (exit 255);
# * an argv with no positional argument (a bare CLI or global flags only,
#   such as --help or --verbose) also runs under a private home: dartdev
#   writes telemetry for --verbose even when the flag is present;
# * every other argv is command form: exec dart with --suppress-analytics
#   before the command unless a leading --suppress-analytics is already
#   there. Nothing is duplicated or reordered.
RUN_HOME_PRIVATE_DIR=""
run_home_private_exec() {
  local bin="$1"; shift
  local dir rc
  dir="$(mktemp -d "${TMPDIR:-/tmp}/run-home.XXXXXX")" || {
    echo "run_home: cannot create a private home under ${TMPDIR:-/tmp}" >&2
    exit 1
  }
  RUN_HOME_PRIVATE_DIR="$dir"
  trap 'rm -rf "$RUN_HOME_PRIVATE_DIR"' EXIT
  export HOME="$dir"
  export USERPROFILE="$dir"
  export APPDATA="$dir"
  export LOCALAPPDATA="$dir"
  export XDG_CONFIG_HOME="$dir"
  export XDG_CACHE_HOME="$dir"
  export XDG_DATA_HOME="$dir"
  "$bin" "$@"
  rc=$?
  rm -rf "$RUN_HOME_PRIVATE_DIR"
  trap - EXIT
  exit "$rc"
}

run_home_exec() {
  local bin="$1"; shift
  local rest=("$@") i=0 n=$#
  local arg first="" already=0 private=0
  while (( i < n )) && [[ "${rest[i]}" == -* ]]; do
    arg="${rest[i]}"
    if [[ "$arg" == "--suppress-analytics" ]]; then
      already=1
    elif [[ "$arg" == "--no-suppress-analytics" ]]; then
      private=1
    fi
    (( ++i ))
  done
  if (( i < n )); then
    # tr, not ${var,,}: the launcher also runs under macOS bash 3.2.
    first="$(printf '%s' "${rest[i]}" | tr '[:upper:]' '[:lower:]')"
    case "$first" in
      *.dart|*.dill|*.snapshot|*.aot|*.jit) private=1 ;;
    esac
  else
    private=1
  fi
  if (( private )); then
    run_home_private_exec "$bin" "$@"
  elif (( already )); then
    exec "$bin" "$@"
  else
    exec "$bin" --suppress-analytics "$@"
  fi
}
"""
