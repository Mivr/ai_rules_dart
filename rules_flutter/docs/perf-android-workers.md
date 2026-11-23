# Android persistent workers: result

Decision: no flag. The consumer preset (`tools/preset.bazelrc`) and
`e2e/android_example/.bazelrc` do not enable the Android persistent
(multiplex) workers.

## Measurement

Not taken. The environment this item ran in has no Android SDK or NDK
(`ANDROID_HOME` and `ANDROID_NDK_HOME` are unset and no `aapt2` or
`build-tools` directory exists), so `android-debug-clean` and the
one-plugin-edit flow at the plugin tier of the scale bench could not be built
with or without the workers. No number exists for either arm.

## Reason

A flag goes into the preset only when a measurement in one session shows a gain
and the outputs with and without it are byte-identical. Neither was observed,
so the hypothesis stays unconfirmed and the defaults stay as they were. This
is not a finding that the workers are slow or incorrect.

## To redo it

On a host with the SDK and NDK, run the scale bench's Android flows (see
[perf-ios-bench.md](perf-ios-bench.md), "Scale bench") twice in one session,
once with `--bazel_flags` carrying the Android worker flags and once without,
then compare the action times and the APK bytes. If the workers win and the
APKs match, add the flags through `tools/BUILD.bazel` and regenerate the
preset with `bazel run //tools:preset.update`.
