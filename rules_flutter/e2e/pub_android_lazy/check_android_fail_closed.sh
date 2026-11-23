#!/usr/bin/env bash
# The Dart build must stay green while the Android path fails closed.
set -euo pipefail

bazel build //:app

# `--keep_going` makes Skyframe evaluate the aggregator's `exports` edge through
# the spoke's `android:lib` alias into the plugin's Android repository even when
# an unrelated toolchain target (such as the Android SDK) fails first. The
# diagnostics below must come from this very fetch, never from a direct fetch.
set +e
out=$(bazel fetch @deps//android:all_android_plugin_libs --keep_going 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "expected the Android plugin fetch to fail, but it succeeded"
  echo "$out"
  exit 1
fi

# The reader reports the `group:artifact` key it could not map, so the
# versioned declaration in the fixture surfaces as `com.example:lazy-unmapped`.
if ! grep -Fq 'com.example:lazy-unmapped:1.0' lazy_plugin/android/build.gradle; then
  echo "fixture lost the unmapped coordinate"
  exit 1
fi
for needle in \
  'deps__lazy_plugin//android:lib' \
  'lazy_plugin' \
  'android/build.gradle' \
  'declares Android dependencies rules_flutter cannot translate to Bazel labels' \
  'com.example:lazy-unmapped'; do
  if ! grep -Fq "$needle" <<<"$out"; then
    echo "Android fetch failed without the expected diagnostic: $needle"
    echo "$out"
    exit 1
  fi
done

echo "ok: Dart build skipped the Gradle model; the Android path refused the unmapped coordinate"
