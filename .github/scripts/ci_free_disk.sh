#!/usr/bin/env bash
# Frees preinstalled toolchains the job never uses (Ubuntu runners only).
# A missing path is skipped and named; a path that exists but cannot be
# removed fails the step with that path in the error.
set -u
paths=(
  /usr/share/dotnet
  /usr/local/lib/android
  /opt/ghc
  /opt/hostedtoolcache/CodeQL
)
echo "::group::df -h / before cleanup"
df -h /
echo "::endgroup::"
status=0
for p in "${paths[@]}"; do
  if [ ! -e "$p" ]; then
    echo "skip: $p does not exist"
    continue
  fi
  echo "removing $p"
  if ! sudo rm -rf "$p"; then
    echo "::error::cannot remove $p"
    status=1
  fi
done
echo "::group::df -h / after cleanup"
df -h /
echo "::endgroup::"
exit "$status"
