# Android overlay phases

Question (queue item 419): how much of the 0.777 s that `FlutterApkOverlay`
takes in a debug Dart edit is avoidable? `apk_overlay.dart` does not
recompress base entries: it copies the base's local entries as one slice and
re-emits the central records. Only the payload (the `flutter_assets` files and
the `native_libs.jar` entries) is encoded. So the cost is split into phases and
measured, instead of assumed.

## What was run

Host: 2 CPUs, shared with other jobs. Every command ran under the shared
Bazel `flock`, so no other build ran at the same time. The numbers are small
and noisy, and they are not the CI runner's numbers.

```
bazel --max_idle_secs=60 build //flutter/private/tools:android_bundle
python3 tools/perf/android_overlay_phases.py <bazel-bin>/flutter/private/tools/android_bundle
python3 tools/perf/android_overlay_phases.py <bazel-bin>/flutter/private/tools/android_bundle --base-kib 131072 --asset-kib 1024
```

The script generates a synthetic unsigned base APK (stored random entries),
a kernel blob, compressible JSON-like assets and a jar of stored `.so`
entries in a temp directory. It runs `apk-overlay ... --debug` five times per
arm and takes the median wall. The arms are: (1) tiny base and kernel only,
the process floor; (2) full base and kernel only; (3) as 2 plus compressible
assets; (4) as 3 plus a native-libs jar. Arms 1 to 3 pass an empty jar,
because the base shape of the CLI requires one.

## Medians, default sizes

Size flags: `--runs 5 --tiny-base-kib 16 --base-kib 65536 --kernel-kib 16384
--asset-files 40 --asset-kib 256 --so-count 3 --so-kib 8192`.

| arm | median wall (s) | share of the flow (%) |
|---|---|---|
| 1 tiny base, kernel only (process floor) | 0.090 | 28.5 |
| 2 full base, kernel only (adds base read and write) | 0.166 | 24.1 (added) |
| 3 full base, kernel and assets (adds deflate) | 0.207 | 12.9 (added) |
| 4 as 3 plus native libs | 0.316 | 34.6 (added) |

"Share of the flow" here is the share of arm 4, the whole synthetic action:
the floor, then each phase's added time.

## Medians, larger sizes (sensitivity)

Size flags: as above with `--base-kib 131072 --asset-kib 1024`.

| arm | median wall (s) | share of the flow (%) |
|---|---|---|
| 1 tiny base, kernel only (process floor) | 0.076 | 15.1 |
| 2 full base, kernel only | 0.246 | 34.0 (added) |
| 3 full base, kernel and assets | 0.399 | 30.5 (added) |
| 4 as 3 plus native libs | 0.502 | 20.4 (added) |

## Verdict by the roadmap rule

The avoidable share is the time arms 2 and 3 add over arm 1, as a fraction of
arm 4, scaled to the 0.777 s of #409 (`docs/perf-android-packaging.md`). The
bar is 10% of the core_edit flow: 0.387 s of 3.869 s. (The roadmap file named
in the item, `docs/design/perf-roadmap.md`, is not in this tree; the rule is
taken from the item text.)

| sizes | avoidable (s, raw) | fraction of arm 4 | scaled to 0.777 s (s) | share of the flow (%) | verdict |
|---|---|---|---|---|---|
| default | 0.117 | 0.370 | 0.287 | 7.4 | under 10%: close with the numbers |
| larger | 0.324 | 0.645 | 0.501 | 12.9 | at or above 10%: later item |

The two size choices land on different sides of the bar, so the verdict
depends on the real mix of base size and asset size, and neither could be
measured here: no real debug APK exists on this host, and the byte sizes of
the CI APKs are not in #409's tables. Not measured: the real base APK size,
the real asset volume, and wall on the CI runner. The larger run uses 128 MiB
of base and 40 MiB of deflated assets, which is probably above a debug Dart
app's assets. The default sizes are the stated basis of the verdict: the item
closes with the numbers. The fix would still need a cache across actions or a
split of the action, because base entries are already copied raw.

## If a later item is opened

If the real sizes put the avoidable share at or above 10%, the later item is
blocked on this one and needs this proof: a test that runs the old and the new
code on the same inputs and compares today's output bytes with the new output
bytes exactly, once for a debug overlay and once for a release overlay. A
release APK must stay byte-identical, and storing assets (instead of
deflating them) would change the bytes, so it does not qualify.
