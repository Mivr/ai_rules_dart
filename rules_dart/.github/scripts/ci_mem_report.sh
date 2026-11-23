#!/usr/bin/env bash
# Logs memory use at one point of the job. Usage: ci_mem_report.sh <label>.
# A missing `free` fails the step and names the label.
set -euo pipefail
label="${1:?usage: ci_mem_report.sh <label>}"
echo "===== memory report: ${label} ====="
if ! command -v free >/dev/null 2>&1; then
  echo "ci_mem_report.sh (${label}): free not found" >&2
  exit 1
fi
free -m
