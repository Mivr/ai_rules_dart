#!/usr/bin/env bash
# Building the Android library of a hosted plugin reaches its lazy Android
# repository and refuses on unmapped Maven coordinates, while the spoke's
# non-Android query succeeds without evaluating android/build.gradle.
set -euo pipefail

bazel --max_idle_secs=60 query @deps__google_mlkit_commons//:all

set +e
out=$(bazel --max_idle_secs=60 build @deps__google_mlkit_commons//android:lib 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "expected building @deps__google_mlkit_commons//android:lib to fail, but it succeeded"
  echo "$out"
  exit 1
fi

for needle in \
  'flutter.pub spoke for "google_mlkit_commons"' \
  'declares Android dependencies rules_flutter cannot translate to Bazel labels' \
  'com.google.mlkit:vision-common'; do
  if ! grep -Fq "$needle" <<<"$out"; then
    echo "Android build failed without expected diagnostic: $needle"
    echo "$out"
    exit 1
  fi
done

echo "ok: spoke query succeeded and lazy Android build failed with expected diagnostic"
