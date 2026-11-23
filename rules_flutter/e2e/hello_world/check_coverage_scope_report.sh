#!/usr/bin/env bash
# Runs `bazel coverage //:hello_coverage_scope_test` and checks its report:
# it names hello_test.dart, holds at least one record, and carries no SF: line
# for a Flutter framework script.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
bazel="${BAZEL:-bazel}"

"$bazel" coverage //:hello_coverage_scope_test --test_output=errors
report="$("$bazel" info bazel-testlogs)/hello_coverage_scope_test/coverage.dat"

if [[ ! -s "$report" ]]; then
  echo "FAIL: no coverage report at $report" >&2
  exit 1
fi
if ! grep -q '^SF:.*hello_test\.dart$' "$report"; then
  echo "FAIL: report does not name hello_test.dart" >&2
  exit 1
fi
if [[ "$(grep -c '^end_of_record$' "$report")" -lt 1 ]]; then
  echo "FAIL: report holds no record" >&2
  exit 1
fi
if grep -E '^SF:(package:(flutter|flutter_test|sky_engine|test_api)/|.*/flutter/packages/)' "$report"; then
  echo "FAIL: report names Flutter framework scripts (listed above)" >&2
  exit 1
fi
echo "OK: coverage report is scoped to the test's own code"
