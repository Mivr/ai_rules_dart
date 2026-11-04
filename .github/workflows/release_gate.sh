#!/usr/bin/env bash
# Release gate for a tag. Each of ci.yaml and full.yaml must pass on the tagged
# commit, found in this order:
#   a. a successful `schedule` (nightly) run on that sha, reused as it is;
#   b. otherwise the newest `workflow_dispatch` run on the tag and sha. When
#      there is none, the workflow is dispatched on the tag with
#      `uncached=true`, which runs every job uncached.
# Every poll judges the run's current status, so a rerun of failed jobs can
# turn a failed run into a pass. Exits 0 only when both workflows passed.
#
# Usage: release_gate.sh <tag> <sha>
# Env: GH_TOKEN (for gh) and REPO (owner/name). Tests shorten the waits with:
#   RELEASE_GATE_POLL_SECONDS     (default 60)
#   RELEASE_GATE_DEADLINE_MINUTES (default 350)
#   RELEASE_GATE_APPEAR_SECONDS   (default 300: how long a new dispatch may take
#                                  to show up in the run list)
set -o errexit -o nounset -o pipefail

workflows=(ci.yaml full.yaml)

if [ "$#" -ne 2 ]; then
  echo "usage: release_gate.sh <tag> <sha>" >&2
  exit 2
fi
tag="$1"
sha="$2"
: "${GH_TOKEN:?release_gate: GH_TOKEN is required}"
: "${REPO:?release_gate: REPO is required}"
poll_seconds="${RELEASE_GATE_POLL_SECONDS:-60}"
appear_seconds="${RELEASE_GATE_APPEAR_SECONDS:-300}"
deadline=$(( $(date +%s) + ${RELEASE_GATE_DEADLINE_MINUTES:-350} * 60 ))

# list_runs <workflow>: the workflow's runs on the sha, as a JSON array.
list_runs() {
  gh run list --repo "$REPO" --workflow "$1" --commit "$sha" --limit 50 \
    --json databaseId,createdAt,status,conclusion,event,headBranch,headSha,url
}

# nightly_url <runs>: URL of the newest successful schedule run on the sha.
nightly_url() {
  jq -r --arg sha "$sha" '[.[] | select(.event == "schedule" and .headSha == $sha and .conclusion == "success")] | sort_by(.createdAt) | last | .url // empty' <<<"$1"
}

# dispatch_run <runs>: the newest workflow_dispatch run on the tag and sha. The
# tag may be reported bare or as a full ref; either names the same dispatch.
dispatch_run() {
  jq -c --arg tag "$tag" --arg sha "$sha" '[.[] | select(.event == "workflow_dispatch" and (.headBranch == $tag or .headBranch == ("refs/tags/" + $tag)) and .headSha == $sha)] | sort_by(.createdAt) | last // empty' <<<"$1"
}

passed=()
dispatched_at=()
for _ in "${workflows[@]}"; do
  passed+=(0)
  dispatched_at+=("")
done

while true; do
  waiting=""
  for i in "${!workflows[@]}"; do
    wf="${workflows[$i]}"
    if [ "${passed[$i]}" = 1 ]; then
      continue
    fi
    if ! runs="$(list_runs "$wf")"; then
      echo "release_gate: $wf: listing runs failed; retrying"
      waiting="$waiting $wf"
      continue
    fi
    nightly="$(nightly_url "$runs")"
    if [ -n "$nightly" ]; then
      echo "release_gate: $wf: reusing nightly run $nightly"
      passed[i]=1
      continue
    fi
    run="$(dispatch_run "$runs")"
    if [ -z "$run" ]; then
      if [ -z "${dispatched_at[i]}" ]; then
        gh workflow run "$wf" --repo "$REPO" --ref "$tag" -f uncached=true
        echo "release_gate: $wf: dispatched uncached run on $tag ($sha)"
        dispatched_at[i]="$(date +%s)"
      elif [ "$(date +%s)" -ge $(( dispatched_at[i] + appear_seconds )) ]; then
        echo "release_gate: $wf: the dispatched run did not appear within ${appear_seconds}s"
        exit 1
      fi
      waiting="$waiting $wf"
      continue
    fi
    status="$(jq -r .status <<<"$run")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$run")"
    url="$(jq -r .url <<<"$run")"
    if [ "$status" != completed ]; then
      waiting="$waiting $wf"
    elif [ "$conclusion" = success ]; then
      echo "release_gate: $wf: dispatched run passed: $url"
      passed[i]=1
    else
      echo "release_gate: $wf: run $url concluded '$conclusion'; refusing to release $tag"
      echo "$runs" | jq .
      exit 1
    fi
  done
  if [ -z "$waiting" ]; then
    echo "release_gate: ${workflows[*]} passed for $tag ($sha)"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "release_gate: timed out waiting for:$waiting (tag $tag, $sha)"
    exit 1
  fi
  echo "release_gate: waiting for:$waiting ..."
  sleep "$poll_seconds"
done
