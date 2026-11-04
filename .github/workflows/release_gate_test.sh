#!/usr/bin/env bash
# Tests release_gate.sh against a fake gh on PATH. Needs no network and runs in
# seconds: the poll interval and the waits are shortened through RELEASE_GATE_*.
set -o errexit -o nounset -o pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/release_gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tag="v1.2.3"
sha="1111111111111111111111111111111111111111"
other="2222222222222222222222222222222222222222"

# The fake gh serves `gh run list --workflow X` from $FAKE_GH_DIR/X.json, or
# from X.atN.json on the Nth list call for X, and records `gh workflow run`
# calls in $FAKE_GH_DIR/dispatches. A dispatch makes X.dispatched.json (when it
# exists) the X.json that later list calls serve.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
dir="$FAKE_GH_DIR"
case "$1 $2" in
  "run list")
    wf=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = --workflow ]; then wf="$arg"; fi
      prev="$arg"
    done
    calls=$(( $(cat "$dir/$wf.calls" 2>/dev/null || echo 0) + 1 ))
    echo "$calls" >"$dir/$wf.calls"
    if [ -f "$dir/$wf.at$calls.json" ]; then
      cat "$dir/$wf.at$calls.json"
    else
      cat "$dir/$wf.json"
    fi
    ;;
  "workflow run")
    echo "$*" >>"$dir/dispatches"
    if [ -f "$dir/$3.dispatched.json" ]; then
      cp "$dir/$3.dispatched.json" "$dir/$3.json"
    fi
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$work/bin/gh"

# mkrun <id> <event> <headBranch> <headSha> <status> <conclusion or "">
mkrun() {
  local created
  created="$(printf '2026-11-04T00:%02d:00Z' "$1")"
  jq -nc --argjson id "$1" --arg event "$2" --arg branch "$3" --arg sha "$4" \
    --arg status "$5" --arg conclusion "$6" --arg created "$created" '{
      databaseId: $id, createdAt: $created, status: $status,
      conclusion: (if $conclusion == "" then null else $conclusion end),
      event: $event, headBranch: $branch, headSha: $sha,
      url: ("https://github.com/example/repo/actions/runs/" + ($id | tostring))}'
}

# fixture <file> [run JSON...]: writes a JSON array holding the given runs.
fixture() {
  local file="$1"
  shift
  if [ "$#" -eq 0 ]; then
    echo '[]' >"$file"
    return
  fi
  printf '%s\n' "$@" | jq -s . >"$file"
}

# start_case <name>: a fresh fixture directory with no runs for either workflow.
start_case() {
  CASE="$1"
  D="$work/$1"
  failed=0
  mkdir -p "$D"
  fixture "$D/ci.yaml.json"
  fixture "$D/full.yaml.json"
}

fail() {
  echo "FAIL $CASE: $1"
  sed 's/^/    | /' "$D/out"
  failed=1
}

# run_gate [VAR=value ...]: runs the gate on the fixtures; sets RC.
run_gate() {
  RC=0
  env PATH="$work/bin:$PATH" FAKE_GH_DIR="$D" GH_TOKEN=test REPO=example/repo \
    RELEASE_GATE_POLL_SECONDS=0 "$@" bash "$gate" "$tag" "$sha" >"$D/out" 2>&1 || RC=$?
}

dispatch_count() {
  if [ -f "$D/dispatches" ]; then wc -l <"$D/dispatches" | tr -d ' '; else echo 0; fi
}

want_exit() {
  [ "$RC" -eq "$1" ] || fail "exit $RC, want $1"
}

want_dispatches() {
  local n
  n="$(dispatch_count)"
  [ "$n" -eq "$1" ] || fail "$n dispatches, want $1"
}

want_dispatch() {
  grep -qF -- "$1" "$D/dispatches" 2>/dev/null || fail "no dispatch matching: $1"
}

want_no_dispatch_for() {
  if grep -qF -- "run $1 " "$D/dispatches" 2>/dev/null; then fail "unexpected dispatch of $1"; fi
}

want_output() {
  grep -qF -- "$1" "$D/out" || fail "output lacks: $1"
}

finish_case() {
  if [ "$failed" = 0 ]; then
    echo "ok   $CASE"
    PASS=$((PASS + 1))
  else
    FAILS=$((FAILS + 1))
  fi
}

PASS=0
FAILS=0
dispatch_pass="$(mkrun 21 workflow_dispatch "$tag" "$sha" completed success)"
dispatch_fail="$(mkrun 22 workflow_dispatch "$tag" "$sha" completed failure)"
dispatch_busy="$(mkrun 23 workflow_dispatch "$tag" "$sha" in_progress "")"

start_case nightly_both_reused
fixture "$D/ci.yaml.json" "$(mkrun 11 schedule main "$sha" completed success)"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
run_gate
want_exit 0
want_dispatches 0
want_output "release_gate: ci.yaml: reusing nightly run https://github.com/example/repo/actions/runs/11"
want_output "release_gate: full.yaml: reusing nightly run https://github.com/example/repo/actions/runs/12"
finish_case

start_case no_runs_dispatched_and_pass
fixture "$D/ci.yaml.dispatched.json" "$dispatch_pass"
fixture "$D/full.yaml.dispatched.json" "$dispatch_pass"
run_gate
want_exit 0
want_dispatches 2
want_dispatch "run ci.yaml --repo example/repo --ref $tag -f uncached=true"
want_dispatch "run full.yaml --repo example/repo --ref $tag -f uncached=true"
finish_case

start_case dispatch_fails
fixture "$D/ci.yaml.dispatched.json" "$dispatch_pass"
fixture "$D/full.yaml.dispatched.json" "$dispatch_fail"
run_gate
want_exit 1
want_dispatches 2
want_output "refusing to release $tag"
finish_case

start_case existing_dispatch_reused_when_done
fixture "$D/ci.yaml.json" "$dispatch_pass"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
run_gate
want_exit 0
want_dispatches 0
finish_case

start_case existing_dispatch_reused_while_running
fixture "$D/ci.yaml.json" "$dispatch_busy"
fixture "$D/ci.yaml.at2.json" "$dispatch_pass"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
run_gate
want_exit 0
want_dispatches 0
finish_case

start_case rerun_of_failed_jobs_passes_on_release_rerun
fixture "$D/ci.yaml.json" "$dispatch_fail"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
run_gate
want_exit 1
# The run's jobs are rerun in place; re-running Release then judges the new status.
fixture "$D/ci.yaml.json" "$dispatch_pass"
run_gate
want_exit 0
want_dispatches 0
finish_case

start_case schedule_on_other_sha_does_not_count
fixture "$D/ci.yaml.json" "$(mkrun 11 schedule main "$other" completed success)"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$other" completed success)"
fixture "$D/ci.yaml.dispatched.json" "$dispatch_pass"
fixture "$D/full.yaml.dispatched.json" "$dispatch_pass"
run_gate
want_exit 0
want_dispatches 2
finish_case

start_case failed_schedule_does_not_count
fixture "$D/ci.yaml.json" "$(mkrun 11 schedule main "$sha" completed failure)"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
fixture "$D/ci.yaml.dispatched.json" "$dispatch_pass"
run_gate
want_exit 0
want_dispatches 1
want_dispatch "run ci.yaml --repo example/repo --ref $tag -f uncached=true"
want_no_dispatch_for full.yaml
finish_case

start_case mixed_only_full_dispatched
fixture "$D/ci.yaml.json" "$(mkrun 11 schedule main "$sha" completed success)"
fixture "$D/full.yaml.dispatched.json" "$dispatch_pass"
run_gate
want_exit 0
want_dispatches 1
want_dispatch "run full.yaml --repo example/repo --ref $tag -f uncached=true"
want_no_dispatch_for ci.yaml
want_output "release_gate: ci.yaml: reusing nightly run"
finish_case

start_case dispatched_run_never_completes_times_out
fixture "$D/ci.yaml.dispatched.json" "$dispatch_busy"
fixture "$D/full.yaml.dispatched.json" "$dispatch_busy"
run_gate RELEASE_GATE_DEADLINE_MINUTES=0
want_exit 1
want_output "timed out waiting for"
finish_case

start_case existing_dispatch_reported_as_a_full_tag_ref
fixture "$D/ci.yaml.json" "$(mkrun 21 workflow_dispatch "refs/tags/$tag" "$sha" completed success)"
fixture "$D/full.yaml.json" "$(mkrun 12 schedule main "$sha" completed success)"
run_gate
want_exit 0
want_dispatches 0
finish_case

start_case dispatched_run_never_appears
run_gate RELEASE_GATE_APPEAR_SECONDS=0
want_exit 1
want_output "did not appear"
finish_case

echo "release_gate_test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
