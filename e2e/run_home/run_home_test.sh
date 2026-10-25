#!/usr/bin/env bash
# Every `bazel run` entry point `rules_dart` offers, run under canary HOME
# directories: fails naming the entries that write into a canary or that exit
# other than their registry row expects.
#
# Usage: [BAZEL=/path/to/bazel] [RUN_HOME_SCRATCH=/path/to/scratch] run_home_test.sh
# It takes Bazel from $BAZEL and passes no Bazel startup flags; when $BAZEL is
# unset (CI) it uses `bazel --max_idle_secs=60`. It takes no arguments and reads
# nothing from the caller's HOME: PUB_CACHE lives in the scratch directory
# outside the canaries, BAZELISK_HOME is never redirected (Bazel and every
# toolchain come from the existing pinned caches), and Bazel itself never runs
# with the canary variables.
#
# Resource design: each entry is first built under the caller's environment
# with `bazel run --script_path=<scratch>/<n>.sh <label>` (so Bazel's output
# root and launcher cache never land in a canary), and only the generated
# launcher script runs with the canary environment and the entry's arguments.
# All scratch, the canaries included, lives under one directory the script
# creates inside $RUN_HOME_SCRATCH (default a fresh directory under
# e2e/run_home/.scratch/, which is git-ignored). A trap on EXIT shuts down the
# Bazel server in every workspace used, then deletes the scratch.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKSPACE"
KINDS='dart_binary|dart_test|dart_fix|dart_format|dart_sdk_binary|dart_analysis_test|dart_js_binary|dart_wasm_binary|dart_library|alias'

# shellcheck source=registry.sh
source "$WORKSPACE/registry.sh"

if [[ -n "${BAZEL:-}" ]]; then
  # shellcheck disable=SC2206
  BAZEL_CMD=($BAZEL)
else
  BAZEL_CMD=(bazel --max_idle_secs=60)
fi
run_bazel() { "${BAZEL_CMD[@]}" "$@"; }

RUN_HOME_SCRATCH="${RUN_HOME_SCRATCH:-$WORKSPACE/.scratch}"
mkdir -p "$RUN_HOME_SCRATCH"
# Absolute scratch paths: a relative HOME resolves against whatever cwd the
# entry leaves its process in, so a relative canary would let writes land
# outside the checked directory and escape the test.
SCRATCH="$(mktemp -d "$RUN_HOME_SCRATCH/run.XXXXXX")"
cleanup() {
  (cd "$WORKSPACE" && run_bazel shutdown >/dev/null 2>&1) || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
# PUB_CACHE lives in the scratch directory, outside the canaries below.
export PUB_CACHE="$SCRATCH/pubcache"
mkdir -p "$PUB_CACHE"
ulimit -c 0

pass=0
fail=0
failed_entries=()

note_pass() { pass=$((pass + 1)); echo "PASS $1"; }
note_fail() { fail=$((fail + 1)); failed_entries+=("$1"); echo "FAIL $1: $2"; }
# An entry verdict: records the failure and shows the run's last lines, so a
# failing entry can be diagnosed from this log alone. Uses $out.
fail_entry() {
  note_fail "$1" "$2"
  printf '%s\n' "$out" | tail -8 | sed 's/^/  | /'
}

# --- 1. enumeration: the registry must match `bazel query` exactly ---
mapfile -t repo_targets < <(
  run_bazel query \
    "visible(//..., kind(\"$KINDS\", @rules_dart//...))" 2>/dev/null | sort
)
mapfile -t ws_targets < <(
  run_bazel query "kind(\"$KINDS\", //...)" 2>/dev/null \
    | sort
)
declare -A queried
for t in "${repo_targets[@]}" "${ws_targets[@]}"; do queried["$t"]=1; done
declare -A registered
declare -A registry_expect
declare -A seen_row
for row in "${RUN_HOME_ENTRIES[@]}"; do
  label="${row%%|*}"
  rest="${row#*|}"
  expect="${rest#*|*|}"
  expect="${expect%%|*}"
  # One label may own several rows with different arguments (the SDK
  # pass-through runs both clean and leaking commands); only an identical
  # row twice is a mistake.
  if [[ -n "${seen_row["$row"]:-}" ]]; then
    note_fail "$label" "registry lists the same row twice"
    continue
  fi
  seen_row["$row"]=1
  registered["$label"]=1
  if [[ -z "${registry_expect["$label"]:-}" ]]; then
    registry_expect["$label"]="$expect"
  fi
done
for t in "${repo_targets[@]}" "${ws_targets[@]}"; do
  if [[ -z "${registered["$t"]:-}" ]]; then
    note_fail "$t" "bazel query finds it but the registry does not list it"
  fi
done
for label in "${!registered[@]}"; do
  if [[ -z "${queried["$label"]:-}" && "${registry_expect["$label"]}" != "refuse" ]]; then
    note_fail "$label" "registry lists it but bazel query finds no such runnable target"
  fi
done

plant_credentials() {
  mkdir -p "$1/dart"
  cat >"$1/dart/pub-tokens.json" <<'EOF'
{"version":1,"hosted":[{"url":"https://pub-cache-token.example.com","token":"canary-token"}]}
EOF
}

snapshot() {
  (cd "$1" && find . -type f | sort | xargs md5sum 2>/dev/null || true)
}

# --- 2./3. build each entry's launcher, then run it under a canary HOME ---
n=0
for row in "${RUN_HOME_ENTRIES[@]}"; do
  IFS='|' read -r label args _policy expect check <<<"$row"
  entry="$label${args:+ -- $args}"
  args="${args//\{WORKSPACE\}/$WORKSPACE}"
  # A `changed-file:` check names a workspace file the run must rewrite (so
  # the entry really exercises the tool) and that is restored afterwards, so
  # the test leaves the workspace as it found it.
  restore_file=""
  restore_saved=""
  if [[ "${check:-}" == changed-file:* ]]; then
    restore_file="${check#changed-file:}"
    restore_saved="$SCRATCH/restore_file.bak"
    cp "$restore_file" "$restore_saved"
  fi
  n=$((n + 1))
  launcher="$SCRATCH/$n.sh"
  # Built under the caller's environment: Bazel's output root and launcher
  # cache must never land in a canary. The build is expected to fail for
  # `refuse` rows; `||` keeps `set -e` from treating that as this death.
  code=0
  # shellcheck disable=SC2086
  out="$(run_bazel run --script_path="$launcher" "$label" </dev/null 2>&1)" || code=$?
  if [[ "$expect" == "refuse" ]]; then
    if [[ $code -ne 0 && "$out" == *"ot executable"* ]]; then
      note_pass "$entry"
    else
      fail_entry "$entry" "expected a run refusal, exited $code"
    fi
    if [[ -n "$restore_file" ]]; then cp "$restore_saved" "$restore_file"; fi
    continue
  fi
  if [[ $code -ne 0 ]]; then
    fail_entry "$entry" "building the run launcher failed, exited $code"
    if [[ -n "$restore_file" ]]; then cp "$restore_saved" "$restore_file"; fi
    continue
  fi
  canary="$(mktemp -d "$SCRATCH/canary.XXXXXX")"
  mkdir -p "$canary/home" "$canary/cfg" "$canary/cache" "$canary/xc" "$canary/xd"
  for d in home cfg cache xc xd; do echo marker >"$canary/$d/MARKER"; done
  plant_credentials "$canary/cfg"
  before="$(snapshot "$canary")"
  # Only the generated launcher runs with the canary environment, with the
  # entry's arguments. The run is expected to fail for most rows; `||` keeps
  # `set -e` from treating the entry's own exit code as the script's death.
  code=0
  # shellcheck disable=SC2086
  out="$(
    env HOME="$canary/home" USERPROFILE="$canary/home" APPDATA="$canary/home" \
      LOCALAPPDATA="$canary/home" XDG_CONFIG_HOME="$canary/cfg" \
      XDG_CACHE_HOME="$canary/xc" XDG_DATA_HOME="$canary/xd" \
      timeout 600 "$launcher" $args </dev/null 2>&1
  )" || code=$?
  after="$(snapshot "$canary")"
  # Restored before any verdict, so every path below leaves the workspace as
  # the run found it. `file_changed` records whether the run rewrote it.
  file_changed=""
  if [[ -n "$restore_file" ]]; then
    if cmp -s "$restore_file" "$restore_saved"; then
      file_changed="no"
    fi
    cp "$restore_saved" "$restore_file"
  fi
  if [[ "$expect" == exit:* ]]; then
    wanted="${expect#exit:}"
    if [[ $code -ne "$wanted" ]]; then
      fail_entry "$entry" "expected exit $wanted, exited $code"
      rm -rf "$canary"
      continue
    fi
  elif [[ $code -eq 0 ]]; then
    fail_entry "$entry" "expected a nonzero exit, exited 0"
    rm -rf "$canary"
    continue
  fi
  if [[ "${check:-}" == stdout:* && "$out" != *"${check#stdout:}"* ]]; then
    fail_entry "$entry" "expected output not found: ${check#stdout:}"
    rm -rf "$canary"
    continue
  fi
  if [[ "$before" != "$after" ]]; then
    fail_entry "$entry" "wrote under the canary HOME: $(comm -13 \
      <(echo "$before" | cut -d' ' -f3- | sort) \
      <(echo "$after" | cut -d' ' -f3- | sort) | head -5)"
    rm -rf "$canary"
    continue
  fi
  if [[ "$file_changed" == "no" ]]; then
    fail_entry "$entry" "$restore_file unchanged: the tool did no work"
    rm -rf "$canary"
    continue
  fi
  note_pass "$entry"
  rm -rf "$canary"
done

echo "run_home: $pass passed, $fail failed"
if [[ $fail -ne 0 ]]; then
  printf 'failing entries:\n  %s\n' "${failed_entries[@]}"
  exit 1
fi
