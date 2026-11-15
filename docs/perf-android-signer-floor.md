# Android signer cold-JVM floor

Item #418 asks for a persistent `ApkSignerTool`. This file measures the cold-JVM floor of the signer, so the
persistent-signing bound is a number and not a guess. It adds no rule change.

## Inputs

- Traces: the `android-profile` artifact of perf-linux.yaml run 43609848752 on Mivr/ai_rules_flutter, arm
  `treatment/android_debug`, flows `core_edit` and `app_edit`, two reps each (`rep1`, `rep2`).
- Signer: `apksigner` from Android SDK build-tools 35.0.0 (the directory name of
  `.../android-sdk/build-tools/35.0.0/apksigner`), run with the OpenJDK 17.0.21 of the same probe SDK on the PATH.
  Its `--version` prints `0.9`.
- The floor is the median of five `<signer> --version` runs (`FLOOR_RUNS = 5` in the tool).

## Command

```sh
python3 -I tools/perf/android_pack_steps.py --signer <build-tools>/35.0.0/apksigner \
  core_edit=<art>/ab-results/treatment/sol/android_debug/core_edit/rep1/trace.json.gz \
  core_edit=<art>/ab-results/treatment/sol/android_debug/core_edit/rep2/trace.json.gz \
  app_edit=<art>/ab-results/treatment/sol/android_debug/app_edit/rep1/trace.json.gz \
  app_edit=<art>/ab-results/treatment/sol/android_debug/app_edit/rep2/trace.json.gz
```

## Result

Cold-JVM floor of the signer: 0.101418 s (`jvm_floor_s`).

| flow      | flow wall | sign median wall | floor (`jvm_start_s`) | persistent-signing bound | percent of flow | verdict    |
| --------- | --------- | ---------------- | --------------------- | ------------------------ | --------------- | ---------- |
| core_edit | 3.869 s   | 0.767 s (19.8%)  | 0.101 s               | 0.666 s                  | 17.2%           | later_item |
| app_edit  | 4.270 s   | 0.793 s (18.6%)  | 0.101 s               | 0.692 s                  | 16.2%           | later_item |

Unrounded, as the tool prints them: `core_edit` sign 0.767264 s, floor 0.101418 s, bound
(`signing_work_s`) 0.665846 s, `percent_of_flow` 17.209. `app_edit` sign 0.793095 s, floor 0.101418 s, bound
0.691677 s, `percent_of_flow` 16.199.

The floor is only the JVM start plus the `--version` path. A resident signer still digests the APK bytes for the v1
and v2 schemes, so the bound is an upper bound on what a persistent signer saves, not a promise: the tool counts
everything above the floor as removable.

## Verdict

By the roadmap rule (`docs/design/perf-roadmap.md`, "Rules for every item"), a bound of 10% of a flow or more makes
the fix a later item. Both bounds are above 10% (17.2% and 16.2%), so this item does not close. The persistent signer
is a later item, blocked on this measurement, with these constraints:

- Release signing stays byte-identical.
- A persistent signer needs a new tool whose version and sha256 are pinned in the contract.
- One resident JVM's RSS is reported against the dev-build-speed budget (`docs/design/dev-build-speed.md`, "Goal
  and budget").

## Not measured

- RSS of a resident signer: no persistent signer exists yet.
- The JDK that Bazel's `ApkSignerTool` action uses on the CI runner. The floor used the probe SDK's JDK 17.0.21 on
  this host, not the runner's, so it is a floor for this host's JVM start.
