#!/usr/bin/env bash
# Logs free disk space and the sizes of the Bazel directories at one point of
# the job. Usage: ci_disk_report.sh <label>. A missing directory is named, never
# skipped silently.
set -u
label="${1:?usage: ci_disk_report.sh <label>}"
echo "===== disk report: ${label} ====="
df -h /
dirs=(
  "${RUNNER_TEMP:-/tmp}/bazel-servers"
  "${HOME}/.cache/bazel"
  "${HOME}/.cache/bazel-disk-cache"
  "${HOME}/.cache/bazel-repo"
  "${HOME}/.cache/bazelisk"
)
for d in "${dirs[@]}"; do
  if [ -d "$d" ]; then
    du -sh "$d"
    if [ "$d" = "${RUNNER_TEMP:-/tmp}/bazel-servers" ]; then
      du -sh "$d"/* 2>/dev/null || echo "no output bases under $d"
    fi
  else
    echo "missing: $d"
  fi
done
