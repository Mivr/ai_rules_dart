#!/usr/bin/env bash
#
# run_home_test.sh — HOME-hermeticity gate for runnable targets.
#
# Covers the RT37-flutter:02 class: runnable targets letting the dart CLI,
# pub, flutter_tools, or the Dart VM write telemetry/state into the
# caller's HOME. For every row in registry.tsv the script either runs the
# target under canary HOME dirs (mode `run`) or builds it (mode `build`).
#
# Resource model (binding): Bazel itself never runs with the canary
# variables, or its output root and launcher cache would land in the
# canary. Each run row is therefore staged first under the caller's
# environment with `bazel run --script_path=<scratch>/<n>/stage.sh
# <label>`, and only the generated stage script runs with the canary
# HOME/USERPROFILE/APPDATA/LOCALAPPDATA/XDG_* dirs plus the entry's args.
# BAZELISK_HOME is never set and the Bazel binary never lives under a
# canary or a fresh directory: Bazel and every toolchain come from the
# existing pinned, sha256-checked caches, so no run downloads anything.
# PUB_CACHE points at a sibling dir outside the canaries (the tools under
# test must resolve their package cache outside HOME-derived defaults).
# Caller-home rows additionally seed the caller credential at
# XDG_CONFIG_HOME/dart/pub-tokens.json — the location `pub token list`
# reads — and the script asserts the tool prints it while writing nothing
# else. After the stage script exits the script snapshots every canary
# dir and fails naming the entry if anything was created, changed, or
# removed. Bazel never ran under the canary, so there is no output-base
# allowlist: every write is the entry's own leak, and target telemetry
# (.dart-tool, .config/dart, ...) always fails.
#
# Usage: ./run_home_test.sh (runs from this directory)
# Env:   BAZEL (default: `bazel --max_idle_secs=60`) — the Bazel binary;
#        no startup flags are passed when $BAZEL is set.
#        RUN_HOME_SCRATCH (default: e2e/run_home/.scratch/) — parent dir
#        for the per-run scratch holding stage scripts and canaries.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$HERE/registry.tsv"
AUDIT="$HERE/audit.tsv"
# Fake hosted credential planted in the caller-env XDG_CONFIG_HOME (at
# dart/pub-tokens.json, the location `pub token list` reads). The URL
# (never the token) is asserted on the tool's stdout to prove credential
# lookup still resolves from the caller env while HOME stays clean.
FAKE_HOST="https://pub.example.com"
FAILURES=""

# Bazel entry point: the manager and fix agents export $BAZEL at a wrapper
# that takes a heavy-job slot and bounds the server's idle time itself (it
# rejects startup throttles such as --max_idle_secs), so pass no startup
# flags there. With $BAZEL unset (CI) fall back to plain bazel with a
# bounded idle time. Never --output_user_root.
if [[ -n "${BAZEL:-}" ]]; then
  BAZ=("$BAZEL")
else
  BAZ=(bazel --max_idle_secs=60)
fi

# All scratch — stage scripts, canaries, pub cache, logs — lives under one
# fresh dir inside $RUN_HOME_SCRATCH (default .scratch/, git-ignored).
# Never bare /tmp, and TMPDIR is never pointed at bare /tmp either: the
# runs below point it at a non-canary sibling inside the scratch instead.
SCRATCH_PARENT="${RUN_HOME_SCRATCH:-$HERE/.scratch}"
mkdir -p "$SCRATCH_PARENT"
SCRATCH="$(mktemp -d "$SCRATCH_PARENT/run-home.XXXXXX")"
STAGED=0

cleanup() {
  # One EXIT trap for the whole script: shut down every server started in
  # this workspace under the caller's environment (never the canary
  # variables), then remove the scratch, the canary dirs included.
  cd "$HERE"
  "${BAZ[@]}" shutdown >/dev/null 2>&1 || true
  if [[ -n "${SCRATCH:-}" && -d "${SCRATCH:-}" ]]; then
    chmod -R u+w "$SCRATCH" 2>/dev/null || true
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  FAILURES="$FAILURES $1"
}

registry_rows() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$REGISTRY"
}

audit_patterns() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$AUDIT" | cut -f1
}

# True if $1 is covered by audit.tsv (exact label or `prefix/...` subtree).
audited() {
  local label="$1" pattern
  while IFS= read -r pattern; do
    if [[ "$pattern" == *"/..." ]]; then
      [[ "$label" == "${pattern%/...}"* ]] && return 0
    elif [[ "$label" == "$pattern" ]]; then
      return 0
    fi
  done < <(audit_patterns)
  return 1
}

registered() {
  local label="$1" row l
  while IFS=$'\t' read -r l _ _ _ _; do
    [[ "$l" == "$label" ]] && return 0
  done < <(registry_rows)
  return 1
}

check_enumeration() {
  echo "== enumeration: replaying the registry queries"
  local got="" missing=0 label q one
  for q in \
    'kind(flutter_sdk_binary, @rules_flutter//dart/...)' \
    'kind(flutter_pub, @rules_flutter//flutter/...)' \
    'kind(test, //...)' \
    'kind(test_suite, //...)' \
    'kind(".*_binary rule", //...)' \
    'kind(".*_binary rule", @rules_flutter//dart/...)' \
    'kind(".*_binary rule", @rules_flutter//flutter/...)' \
    'kind(test, @rules_flutter//dart/...)' \
    'kind(test, @rules_flutter//flutter/...)'; do
    one=""
    if ! one="$("${BAZ[@]}" query "$q" 2>/dev/null)"; then
      fail "enumeration query failed: $q"
      missing=1
      continue
    fi
    got="$got$one"$'\n'
  done
  # //tools/... does not load from a downstream workspace, so its audit
  # rows are only re-enumerated when these queries happen to succeed.
  local tools_got=""
  if tools_got="$("${BAZ[@]}" query \
    'kind(".*_binary rule", @rules_flutter//tools/...)' \
    'kind(test, @rules_flutter//tools/...)' 2>/dev/null)"; then
    got="$got$tools_got"$'\n'
  else
    echo "note: //tools/... is not queryable from this workspace; its $(grep -c '^@rules_flutter//tools/' "$AUDIT" || true) audit rows are attested, not re-enumerated"
  fi
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    if ! registered "$label" && ! audited "$label"; then
      fail "unregistered runnable target: $label"
      missing=1
    fi
  done <<<"$(sort -u <<<"$got")"
  # Every registry row must still resolve.
  while IFS=$'\t' read -r label _ _ _ _; do
    if [[ -z "$("${BAZ[@]}" query "$label" 2>/dev/null)" ]]; then
      fail "registry entry does not resolve: $label"
      missing=1
    fi
  done < <(registry_rows)
  if [[ "$missing" -eq 0 ]]; then
    echo "enumeration: all runnable targets registered"
  fi
}

snapshot_tree() {
  local dir="$1" out="$2"
  (cd "$dir" && find . -mindepth 1 | LC_ALL=C sort >"$out.files")
  (cd "$dir" && find . -mindepth 1 -type f -exec sha256sum -- {} + | LC_ALL=C sort >"$out.sums")
}

# Prints diff lines (unified, one per changed path) between two snapshots.
# Bazel never runs under the canary, so there is no output-base
# allowlist: any change is the entry's own leak.
unsanctioned_changes() {
  local before="$1" after="$2"
  { diff -u "$before.files" "$after.files"; diff -u "$before.sums" "$after.sums"; } | grep -E '^[+-][^+-]' || true
}

run_row() {
  local label="$1" args="$2" policy="$3"
  echo "== run: $label -- $args ($policy)"
  STAGED=$((STAGED + 1))
  local root="$SCRATCH/$STAGED" stage sub out changes rc=0 row_failed=0
  mkdir -p "$root"
  stage="$root/stage.sh"
  # Stage under the caller's environment so the output root, the launcher
  # cache and any toolchain resolution stay out of the canaries.
  # --script_path writes the run script instead of executing the target.
  if ! "${BAZ[@]}" run --script_path="$stage" "$label" >"$root/stage.log" 2>&1; then
    fail "$label staging failed"
    tail -n 30 "$root/stage.log" >&2 || true
    return
  fi
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    mkdir -p "$root/$sub"
    echo "run-home canary for $label" >"$root/$sub/.run-home-marker"
  done
  mkdir -p "$root/ext/pubcache" "$root/tmp" "$root/xdg-config/dart"
  printf '{"version":1,"hosted":[{"url":"%s","token":"run-home-fake-token"}]}' \
    "$FAKE_HOST" >"$root/xdg-config/dart/pub-tokens.json"
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    snapshot_tree "$root/$sub" "$root/$sub.before"
  done
  out="$root/stdout.log"
  # Only the stage script runs with the canary variables; Bazel never
  # does. PUB_CACHE and TMPDIR point at non-canary siblings of the
  # canaries, inside the same scratch.
  if [[ "$args" == "-" ]]; then
    env HOME="$root/home" USERPROFILE="$root/userprofile" APPDATA="$root/appdata" \
      LOCALAPPDATA="$root/localappdata" XDG_CONFIG_HOME="$root/xdg-config" \
      XDG_CACHE_HOME="$root/xdg-cache" XDG_DATA_HOME="$root/xdg-data" \
      PUB_CACHE="$root/ext/pubcache" TMPDIR="$root/tmp" \
      "$stage" >"$out" 2>&1 || rc=$?
  else
    # Word-split the registry args: they are simple tokens, never quoted.
    # shellcheck disable=SC2086
    env HOME="$root/home" USERPROFILE="$root/userprofile" APPDATA="$root/appdata" \
      LOCALAPPDATA="$root/localappdata" XDG_CONFIG_HOME="$root/xdg-config" \
      XDG_CACHE_HOME="$root/xdg-cache" XDG_DATA_HOME="$root/xdg-data" \
      PUB_CACHE="$root/ext/pubcache" TMPDIR="$root/tmp" \
      "$stage" $args >"$out" 2>&1 || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail "$label exited $rc (expected 0)"
    tail -n 30 "$out" >&2 || true
    return
  fi
  if [[ "$args" == *"token list"* ]] && ! grep -q -F "$FAKE_HOST" "$out"; then
    fail "$label hid the caller XDG credential ($FAKE_HOST not on stdout)"
    row_failed=1
  fi
  # The file-form probe must print its own output: on a launcher that
  # prepends --suppress-analytics to program files the VM exits 255 before
  # reaching rc 0, and a launcher that drops the program's stdout breaks
  # the pass-through contract the other way.
  if [[ "$args" == *hello.dart* ]] && ! grep -q -F "run-home hello" "$out"; then
    fail "$label did not print the file-form probe output"
    row_failed=1
  fi
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    snapshot_tree "$root/$sub" "$root/$sub.after"
    changes="$(unsanctioned_changes "$root/$sub.before" "$root/$sub.after")"
    if [[ -n "$changes" ]]; then
      fail "$label wrote under canary $sub:$changes"
      row_failed=1
    fi
  done
  if [[ "$row_failed" -eq 0 ]]; then
    echo "ok: $label left every canary dir unchanged"
  else
    echo "forensics for $label: stdout tail:" >&2
    tail -n 30 "$out" >&2 || true
  fi
}

build_row() {
  local label="$1"
  echo "== build (not-run): $label"
  if ! "${BAZ[@]}" build "$label" >"$SCRATCH/build.log" 2>&1; then
    fail "$label failed to build"
    tail -n 30 "$SCRATCH/build.log" >&2 || true
  else
    echo "ok: $label built"
  fi
}

main() {
  cd "$HERE"
  check_enumeration
  local label args policy mode
  while IFS=$'\t' read -r label args policy mode _; do
    case "$mode" in
      run) run_row "$label" "$args" "$policy" ;;
      build) build_row "$label" ;;
      *) fail "registry row with unknown mode: $label" ;;
    esac
  done < <(registry_rows)
  if [[ -n "$FAILURES" ]]; then
    echo "FAILING ENTRIES:$FAILURES" >&2
    exit 1
  fi
  echo "run_home: all entries clean"
}

main "$@"
