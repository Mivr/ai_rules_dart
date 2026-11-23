# Android packaging after a Dart edit: per-step wall

After a Dart edit in a debug modular Android app, three actions rewrite the
whole APK in a chain: `FlutterApkOverlay` ("Injecting Flutter payload into
base APK"), `AndroidZipAlign` and `ApkSignerTool` ("Signing APK with Flutter
payload"). `tools/perf/android_pack_steps.py` reads Bazel profile traces and
reports each step's wall, its share of the flow, and the bounded gain of three
candidate fixes under the roadmap 10% rule.

Decision: no fix is built from this item. Two candidates reach the 10% line
for a Dart edit that rebuilds the kernel (core edit): reusing unchanged
payload entries (bound 20% of the flow) and persistent signing (bound 20%).
Skipping zipalign stays under it (5.7%). Each of the first two is a later
item that needs its own measurement of the part still unmeasured below.

## Result

Source: perf-linux.yaml run 43609848752 (rules_flutter `afa3fdeb`, 500k
lines, `ab=flags`, `debug_modular_app=true`), `android_debug` flows `core_edit`
(core body edit) and `app_edit`, two reps each, warm. Wall is the
`Initialize command` to `Complete build` span of the profile; each step is the
median of the `action processing` event over the two reps. The table is what
the tool prints (`control` is the arm without the flags, `treatment` the arm
with them):

### control/android_debug/core_edit (wall 5.388 s, 2 trace(s))

| group | step | median s | share of flow | apk bytes |
|---|---|---|---|---|
| full | overlay | 0.942 | 17.5% |  |
| full | sign | 0.879 | 16.3% |  |
| full | zipalign | 0.264 | 4.9% |  |

| candidate (full) | bound s | percent of flow | verdict |
|---|---|---|---|
| reuse_payload_entries | 0.942 | 17.5% | later_item |
| persistent_signing | 0.879 | 16.3% | later_item |
| skip_zipalign | 0.264 | 4.9% | close_with_numbers |

### control/android_debug/app_edit (wall 17.570 s, 2 trace(s))

| group | step | median s | share of flow | apk bytes |
|---|---|---|---|---|
| full | overlay | 0.946 | 5.4% |  |
| full | sign | 0.865 | 4.9% |  |
| full | zipalign | 0.261 | 1.5% |  |

| candidate (full) | bound s | percent of flow | verdict |
|---|---|---|---|
| reuse_payload_entries | 0.946 | 5.4% | close_with_numbers |
| persistent_signing | 0.865 | 4.9% | close_with_numbers |
| skip_zipalign | 0.261 | 1.5% | close_with_numbers |

### treatment/android_debug/core_edit (wall 3.869 s, 2 trace(s))

| group | step | median s | share of flow | apk bytes |
|---|---|---|---|---|
| full | kernel_compile | 0.780 | 20.2% |  |
| full | kernel_link | 0.173 | 4.5% |  |
| full | overlay | 0.777 | 20.1% |  |
| full | sign | 0.767 | 19.8% |  |
| full | zipalign | 0.220 | 5.7% |  |

| candidate (full) | bound s | percent of flow | verdict |
|---|---|---|---|
| reuse_payload_entries | 0.777 | 20.1% | later_item |
| persistent_signing | 0.767 | 19.8% | later_item |
| skip_zipalign | 0.220 | 5.7% | close_with_numbers |

### treatment/android_debug/app_edit (wall 4.270 s, 2 trace(s))

| group | step | median s | share of flow | apk bytes |
|---|---|---|---|---|
| full | kernel_compile | 1.215 | 28.4% |  |
| full | kernel_link | 0.245 | 5.7% |  |
| full | overlay | 0.781 | 18.3% |  |
| full | sign | 0.793 | 18.6% |  |
| full | zipalign | 0.215 | 5.0% |  |

| candidate (full) | bound s | percent of flow | verdict |
|---|---|---|---|
| persistent_signing | 0.793 | 18.6% | later_item |
| reuse_payload_entries | 0.781 | 18.3% | later_item |
| skip_zipalign | 0.215 | 5.0% | close_with_numbers |

Treatment core edit, as the Bazel critical path shows it (3.85-3.9 s wall):
inject 0.77-0.85 s, zipalign 0.22-0.30 s, sign 0.76-0.85 s, together about
2.0 s (51%).

Reading the table:

- Bounds are upper bounds. A fix cannot remove more than the step's whole
  wall, so a candidate under 10% of the flow is `close_with_numbers` and one at
  or above it is `later_item`.
- `app_edit` runs a longer kernel step, so the same three steps are a smaller
  share (18-19% for inject and sign) there.
- Bounds are not additive: each bounds one fix on its own.
- `clean` and `android_release` flows are in the same run but are not a Dart
  edit of a debug app; their packaging steps are under 2% of the flow.

## Not measured

- The `payload_apk` and `base_apk` output groups the dev tool builds
  (`split_apk_groups`): their overlay, zipalign and sign steps have no
  number. The tool keeps them apart from the full APK by `_base`/`_payload` in
  the event's primary output, so the profile needs
  `--experimental_profile_include_primary_output`.
- APK byte sizes (`--apk-dir`).
- The cold-JVM floor of the signer (`--signer`, median of five
  `<signer> --version` runs). With it the tool splits the sign wall into JVM
  start and signing work, and the persistent-signing bound is the sign wall
  minus the floor.

To measure them, run perf-linux.yaml with `ab=flags` and `bazel_flags` set to:

```text
--@rules_flutter//flutter/private:debug_modular_app=true --output_groups=payload_apk --experimental_profile_include_primary_output
```

Then run the tool on the downloaded traces, with the APK directory and the
SDK's `apksigner` for the two optional fields:

```text
gh run download <run id> -R Mivr/ai_rules_flutter -D <empty dir>
python3 -I tools/perf/android_pack_steps.py --apk-dir <bazel-bin dir of the app> \
  --signer <android sdk>/build-tools/<version>/apksigner \
  core_edit=<dir>/.../core_edit/rep1/trace.json.gz \
  core_edit=<dir>/.../core_edit/rep2/trace.json.gz
```

`--format json` prints only the JSON, `--format markdown` only the tables.
An unreadable trace, or one with none of the three steps, exits 2 and names
the trace.

## Constraint for any later fix

A release APK must stay byte-identical under any later fix. The debug-only
paths may change; the release overlay, align and sign steps and their bytes
may not.
