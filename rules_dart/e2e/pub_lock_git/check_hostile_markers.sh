#!/usr/bin/env bash
# Re-verifies the hostile-host fetch markers at test time.
#
# Each marker was written by a `git_hostile_fetch_probe`,
# `git_fsck_fetch_probe` or `git_export_subst_probe` repository that
# already failed its fetch loudly on any deviation; this script pins the
# contract a second time from the test side: the observed fetch mode must
# equal the expected one, and the hostile materialized archive digest must
# equal the clean control's (the pinned SHA fixes the tree id, so only the
# archive bytes can still differ across hosts). Arguments are marker runfiles paths
# (`$(rlocationpath ...)`), resolved below so the test also works where
# runfiles arrive via a manifest instead of a symlink tree (Windows).
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }
f=
set -e
# --- end runfiles.bash initialization v3 ---

fail=0
for rloc in "$@"; do
  marker="$(rlocation "$rloc")"
  if [[ -z "$marker" || ! -f "$marker" ]]; then
    echo "FAIL: $rloc: marker file missing (resolved to '${marker:-<empty>}')"
    fail=1
    continue
  fi
  expect=$(grep '^expect=' "$marker" | cut -d= -f2)
  mode=$(grep '^mode=' "$marker" | cut -d= -f2)
  clean=$(grep '^clean=' "$marker" | cut -d= -f2)
  hostile=$(grep '^hostile=' "$marker" | cut -d= -f2)
  if [[ "$mode" != "$expect" ]]; then
    echo "FAIL: $marker: expected fetch mode '$expect' but observed '$mode'"
    fail=1
    continue
  fi
  if [[ -z "$clean" || "$clean" != "$hostile" ]]; then
    echo "FAIL: $marker: hostile tree '$hostile' differs from clean tree '$clean'"
    fail=1
    continue
  fi
  echo "OK: $marker: mode=$mode tree=$clean"
done
exit $fail
