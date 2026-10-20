#!/bin/sh
# Re-verifies the hostile-host fetch markers at test time.
#
# Each marker was written by a `git_hostile_fetch_probe` repository that
# already failed its fetch loudly on any deviation; this script pins the
# contract a second time from the test side: the observed fetch mode must
# equal the expected one, and the hostile commit tree must equal the clean
# control's tree (plain-host bytes). Arguments are marker file paths.
set -eu

fail=0
for marker in "$@"; do
  expect=$(grep '^expect=' "$marker" | cut -d= -f2)
  mode=$(grep '^mode=' "$marker" | cut -d= -f2)
  clean=$(grep '^clean=' "$marker" | cut -d= -f2)
  hostile=$(grep '^hostile=' "$marker" | cut -d= -f2)
  if [ "$mode" != "$expect" ]; then
    echo "FAIL: $marker: expected fetch mode '$expect' but observed '$mode'"
    fail=1
  fi
  if [ -z "$clean" ] || [ "$clean" != "$hostile" ]; then
    echo "FAIL: $marker: hostile tree '$hostile' differs from clean tree '$clean'"
    fail=1
  fi
  echo "OK: $marker: mode=$mode tree=$clean"
done
exit $fail
