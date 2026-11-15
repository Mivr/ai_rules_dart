# iOS perf bench

Manual-only workflow (`.github/workflows/perf-ios.yaml`) measuring iOS build
cost of `rules_flutter` on GitHub's free macOS runners. Linux cannot build
iOS targets, so this is the only signal for the iOS half of the monorepo
perf target; the manager dispatches it per comparison and reads the
artifact.

## What it measures

For each of `base_ref` and `head_ref` (rules_flutter commits, wired through
`local_path_override` in the generated `MODULE.bazel`), in each of six
configurations (fixed table `CONFIGS` in `tools/perf/run_rep.py`, recorded
in the summary metadata):

- `device_release`: the Flutter iOS framework assembly itself —
  `//app:__app_framework_framework` with `-c opt
  --ios_multi_cpus=arm64`. That is the `_flutter_ios_framework` rule
  the generator's public `flutter_ios_framework_gen(name =
  "app_framework")` creates (`__<name>_framework` in
  `flutter/ios.bzl`): with `-c opt` the application is non-debug, so
  `flutter_application` runs AOT gen_snapshot for iOS (`FlutterAotMacho`)
  and the framework rule assembles App.framework (`FlutterIOSRetagDylib`
  + `FlutterIOSCopyAssets`), with no `ios_application`, hence no
  signing and no provisioning profile. The public
  `//app:app_framework` wrapper is an `apple_dynamic_framework_import`
  whose outputs are only consumed when linked into an app — building it
  executes zero actions (as the first dispatch showed), so the bench
  targets the inner rule and the driver fails any clean build that
  executes fewer than 10 actions (`--min-clean-actions`).
- `sim_debug`: the full simulator app — `//app:app_ios` with
  `-c dbg --ios_multi_cpus=sim_arm64` (the developer inner loop; the
  simulator runs debug builds only, and simulator bundles need no
  provisioning profile).
- `android_release` / `android_debug`: the generated Android app
  `//app:app_android` (`flutter_android_app`, the APK) with `-c opt`
  or `-c dbg`.
- `web_release` / `web_debug`: the generated Web app
  `//app:app_web` (`flutter_web_app`, the deployment directory) with
  `-c opt` or `-c dbg`.

Per configuration the three scenarios run against a freshly reset
workspace copy:

1. `clean`: clean build (fresh workspace copy, fresh per-config output
   base, no caches anywhere).
2. `app_edit`: rebuild after a behaviour-changing top-layer app edit
   (`app/lib/main.dart` shows `value + 1` for the first wired widget).
3. `core_edit`: rebuild after a core body edit (layer 0, highest fan-in
   file; same `var total = 1;` to `var total = 2;` shape as the referee's
   `body_edit`). Cumulative: the app edit stays applied.

Per scenario run it records:

- Executed action count by mnemonic, from
  `bazel build --execution_log_json_file` (only executed spawns are logged).
- Total action CPU time (user+sys from each spawn's metrics) plus wall time.
  The Linux sandbox runner does not populate `userTime`/`systemTime` and
  the macOS runner did not either on the first dispatch;
  `cpu_time_available` says whether any spawn carried them, so missing
  data is never mistaken for zero CPU. Wall time is always reported.
  (`--experimental_execution_log_spawn_metrics` does not exist in the
  pinned Bazel 9.3.0 — `bazel help build` lists only the
  `--execution_log_{binary,compact,json}_file` outputs — so there is no
  extra per-spawn metric to consume.)
- Instructions retired for the iOS-only actions (`FlutterAotMacho`
  gen_snapshot for iOS, the `FlutterIOS*` framework/bundle tools,
  `FlutterStripEngine`, `FlutterPlistMerge`, `FlutterMachOVerifyProbe`,
  assembler/clang and linker steps), by replaying each such action's
  command line under `/usr/bin/time -l` with the host environment
  overlaid by the logged environment, in the build's execroot right
  after the build. Kernel compiles are excluded (the Linux bench
  measures them); pass `--mnemonic` to opt back in. Replays run with
  stdin closed, a 600 s per-action timeout, and an 1800 s whole-log
  budget; on exhaustion the report records `truncated=true` and the
  skipped count.
- Replay CPU seconds (`user_s`/`sys_s` from `time -l`) per action and
  per mnemonic. GitHub's macOS VMs may expose no PMU, in which case no
  replayed action carries an instruction counter; the summary then says
  so plainly and replay CPU is the fallback cost signal.
- Failed replays (non-zero exit or timeout) record the exit code plus
  the last 20 lines of stderr in `replay.json`, and the summary shows
  one sample per failing mnemonic (target, exit, stderr tail), so the
  next run tells us why a replay class failed (missing Xcode env,
  sandbox-only paths) instead of just counting it.
- Executed-but-not-replayed actions are counted per reason in
  `replay.json` (`skipped_by_mnemonic`) and shown in the summary's "Not
  replayed" table. Exec-configuration (host tool) spawns — outputs
  under an exec configuration directory such as
  `bazel-out/darwin_arm64-opt-exec-*/` or (Bazel 9's default, with no
  `-ST-<hash>` suffix) `bazel-out/darwin_arm64-opt-exec/`, which build
  host tools (abseil, the Swift worker) rather than the iOS app — are
  skipped by default under the single reason "host tools (not replayed)"
  (`--include-exec-config` opts back in).

## Generator v2: a reachable program

The first generator shape wired `main` to top-layer widgets only, with
no package calling its dependencies at run time, so AOT tree-shaking
dropped everything below the top layer: a layer-0 `core_edit`
re-ran the kernel compile but never `gen_snapshot`, and the AOT dill
came out byte-identical. Since generator v2 (same design as the
referee's `flutter-monorepo` v2) the generated program is reachable
like a real app:

- Each package entry (`entryN(x, probe)`) calls every own file's
  helper and value functions — including the value functions the
  bench edits — and constructs every own file's widget, all
  unconditionally, so a `body_edit` at any layer changes the AOT
  program. (`api_edit` keeps its meaning: adding an unused member
  legitimately changes nothing in AOT.)
- Each entry also calls its direct dependencies' entries, and `main`
  calls every top-layer entry. Cross-package calls are guarded by a
  probe `main` reads from a runtime source the compiler cannot fold
  (`int.tryParse('probe') ?? 0`, always zero at run time), so the
  whole transitive closure stays reachable for tree-shaking without
  running if the app ever runs. The DAG repair pass gives every
  package below the top layer at least one dependent, so reachability
  holds through the dependency graph from every seed.
- `bench-workspace-stats.json` records `generator_version: 2` (also
  embedded in the summary metadata as `base_stats`/`head_stats`); the
  summary warns when the two sides differ in shape. Numbers from the
  old shape are never comparable with v2 numbers.

## Apple replay environment

Bazel's darwin spawn runner adds `DEVELOPER_DIR` and `SDKROOT` at
execution time (as `XcodeLocalEnvProvider` does), so the execution log
never records them and naive replays of Apple actions fail with
`Error: DEVELOPER_DIR not set.` When the logged environment names an
Apple SDK platform (`APPLE_SDK_PLATFORM`, alongside
`APPLE_SDK_VERSION_OVERRIDE` / `XCODE_VERSION_OVERRIDE`),
`tools/perf/replay.py` resolves `DEVELOPER_DIR` from `xcode-select -p`
and `SDKROOT` from `xcrun --sdk <platform lowercased>
--show-sdk-path`, cached per platform. Without those tools (e.g.
Linux) it replays with the logged environment alone.

Ordering (enforced by `tools/perf/run_rep.py`): per repeat and per config,
the workspace is reset from the pristine copy, then all three scenario
builds run, then the execroot's `bazel-out` is made user-writable, then
all three logs are summarized and replayed, then the server shuts down.
Each config builds in its own output base under the per-repeat root, so
configs never share a server. No build follows a replay in the same
output base, so replayed outputs cannot perturb incremental builds.
Builds pass `--materialize_param_files` so `@flagfile` inputs exist at
replay time. Results are stored per config:
`results/<ref>/<config>/<scenario>/rep<N>/`, and the summary reports
medians per config.

Each scenario repeats (`repeats`, default 3); the summary reports medians
with [min, max] spread and head-vs-base deltas (`repeats=1` is called out
as a single sample with no spread). The summary also shows per-mnemonic
replay failure counts (non-zero exit or timeout) and truncation warnings,
so a broken replay can never look like a cost drop. One JSON + one
Markdown file are uploaded as a single artifact (`perf-ios-summary`,
3-day retention). Build outputs are never uploaded.

## Dispatching

Actions > "iOS perf bench" > Run workflow. `head_ref` is required;
`base_ref` defaults to `main`. Keep `target_loc` at the default 500000
unless the 5-hour job timeout is hit, then lower it rather than raising the
timeout. Base and head should share the `rules_dart` pin for a clean
comparison; if they drift, the delta mixes both rule sets.

Rough duration guidance (extrapolation, not a measurement): a 20k-line
Linux smoke builds the shared app kernel in about 80 s; compile cost
scales roughly with lines, so a 500k clean compile lands around the
half-hour mark per config, times two configs, plus fast incremental
rebuilds and serial instruction replay (capped at 30 min per log, 3 h
worst case across 2 refs × 2 configs × 3 scenarios, typically far less).
That fits the 5 h timeout with margin; a 100k dispatch should take
roughly a fifth of the full size. The first successful dispatch
calibrates these numbers; if the job times out, lower `target_loc`.

## `bazel_flags` (A/B experiments, never main points)

Dispatch input `bazel_flags` (string, default empty) carries Bazel flags
separated by whitespace for one run. They apply to the head workspace
only: each flag becomes one `common <flag>` line appended to the
generated head workspace's `.bazelrc`, after generation and before any
Bazel command. Compare mode never gives them to base, and sol mode
measures head only. Empty input runs exactly as before (the workspace
is byte-identical, every Bazel command line unchanged); the only
addition is `meta.bazel_flags: []`. With flags, `ios-sol.json`
`meta.bazel_flags` (and compare mode's `summary.json` meta, plus a
`summary.md` line) records the accepted tokens.

Use it for A/B runs of flags that change how a build runs but not which
rules it uses: the opt-in incremental kernel worker
(`--@rules_flutter//flutter:incremental_kernel`, a persistent worker
whose effect only the warm-server edit flows of sol mode can show), or
`--host_compilation_mode=fastbuild` on the debug clean build, where the
host-tool builds may dominate (they are an exec-configuration C++ build of
the Swift worker, among others; the share is measured, not assumed:
`flows.<flow>.attribution.parts.host_tools` in `ios-sol.json` splits that
CPU by mnemonic and by repository, see "CPU attribution" below). Never use
flagged runs as main dashboard points.

Validation (`tools/perf/bench_flags.py`, before anything is generated
or built) accepts only `--<name>` or `--<name>=<value>` where `<name>`
is a plain option name or a Starlark flag label and `<value>` uses only
letters, digits and `_ @ / : . , + = -`, with no whitespace, quotes,
`$`, backtick, `;`, `|`, `&`, `<`, `>`, `\`, `#` or control characters.
One bad token fails the job naming the token. Refused, in `--name` and
`--no<name>` forms because they would change what the bench measures or
where it writes: caches and remote services (`disk_cache`,
`repository_cache`, `remote_*`, `experimental_remote*`, `bes_*`,
`google_*`); locations, logs and profiles (`output_base`,
`output_user_root`, `install_base`, `symlink_prefix`, `profile`,
`generate_json_trace_profile`, `execution_log*`,
`experimental_execution_log*`); rc files and configs (`config`,
`bazelrc`, `ignore_all_rc_files`); module and repository resolution
(`lockfile_mode`, `override_module`, `override_repository`,
`registry`); and startup options the bench owns (`batch`,
`host_jvm_args`, `max_idle_secs`, `output_base`).

Workers in sol mode: when a flag makes Bazel run a chain step in a
persistent worker (the execution log's `runner` names a worker), the
SOL chain still runs that step by hand, one-shot, from its recorded
argv (its params files are in the execroot, via
`--materialize_param_files`, as for any step). The step's CPU, its
byte-identity proof and the ordering rules stay as for any step. The
flow record carries `worker_steps` (chain steps Bazel ran in a worker,
by mnemonic). The warm number counts live descendants (workers) while
the server is up; the server shuts down after each config and on every
error path, so no worker or server outlives its config.

In A/B runs flags reach the arms as `ab` says (next section): with
`ab=flags` only the treatment arm gets `bazel_flags`, with
`ab=lockfile` both arms get them.

## Same-runner A/B (`ab`, never main points)

Two 100k runs of the same commit on two free macOS runners differed
1.3-1.7x on flows no flag could touch (release clean 108.5 vs 66.9 CPU
s; runs 40052206141 and 40052214120), so comparing two separate runs
does not measure a flag. An A/B runs both arms in the same job on the
same runner, interleaved: repeat 1 runs control first, repeat 2
treatment first, and so on alternating. Each arm runs the full sol
scenario sequence (clean batch, warm-up, warm edits, chains) in its own
output base and work directory, exactly as a single sol run does, and
every server and worker of one arm is gone before the other arm starts.

Dispatch input `ab` (choice, default `off`; sol mode only — any other
mode with `ab` set fails at once with a clear message):

- `off`: today's behaviour. One measured workspace with `bazel_flags`
  and `lockfile` applied; writes `ios-sol.json` (artifact `ios-sol`).
- `flags`: two arms. Control is the workspace with the `lockfile`
  setting and no flags; treatment is the same plus `bazel_flags`,
  which must be non-empty.
- `lockfile`: two arms. Both get `bazel_flags`; control has no
  lockfile, treatment the committed one. The `lockfile` input must be
  `none` here.

The A/B comparison stays on the two iOS configurations (`IOS_CONFIGS` in
`tools/perf/run_rep.py`): the Android and Web configurations are SOL-only
series, so `ios-ab.json` and the A/B lock build are exactly what they were
before those series existed.

With `ab` on the run writes `ios-ab.json` (artifact `ios-ab`, 3-day
retention) instead of `ios-sol.json`:

- `meta`: `repeats`, `target_loc`, `seed`, `ab`, `bazel_flags`,
  `lockfile`, and the per-repeat arm order (`order`).
- `arms`: `control` and `treatment`, each mapping every flow id to its
  flow record in exactly the `ios-sol.json` flow schema (medians over
  that arm's repeats).
- `ratio`: per flow the median, min and max over
  repeats of the paired per-repeat ratio treatment.bazel /
  control.bazel (pairs from the same repeat), plus the geometric mean
  (`geomean`: `exp(mean(log r))` over the paired ratios, null when
  `n` is 0), plus `n` and `unpaired`
  (the repeat numbers with no pair). A flow that is non-identical or
  missing in either arm of a repeat has no pair for that repeat, and
  the record says so.

The arms alternate which runs first (repeat 1 control first, repeat 2
treatment first, and so on), and at small repeat counts the median is
a poor central estimate of the effect: with `n=2` the upper median is
just the upper pair, which is always the repeat where treatment ran
first. An order effect — the second arm of a repeat running faster or
slower than the first — multiplies one pair's ratio by a factor `f`
and the other's by `1/f`, so the geometric mean of the pairs cancels
the effect while the median does not. Read the geomean as the central
estimate and the median alongside it.

How to read an A/B honestly: a flag's effect on the flows it touches
counts only when the flows it cannot touch stay within ±5% between
arms (geomean); otherwise the run is inconclusive and needs more
repeats. The first macOS A/Bs showed why: pairs such as 0.649 / 1.16
on one flow mean the runner moved under the run, not that the flag
did anything.

Dashboard series: since bench v3 (2026-10-24), main dashboard points
are sol runs with `lockfile=committed`. The bench generates the lock
per measured ref, with that ref's own rules, by an unmeasured run
before any timed build. Points with `lockfile=none` belong to the
earlier series (bench 1 and 2). A/B and `bazel_flags` runs are never
dashboard points.

The `ios-profile` artifact keeps both arms' traces and logs under
per-arm paths. A/B runs are never main dashboard points: use them to
decide whether a flag or the committed lock changes the cost, then
record the decision; the dashboard tracks single-arm runs only.

An A/B doubles the measured work: the single-arm 500k / 3-repeat run
takes about 95 minutes, so the same size as an A/B takes about 190
minutes and still fits the 300-minute job timeout. For quick iteration
use 100k with 1-2 repeats.

## Committed lockfile (`lockfile`)

Dispatch input `lockfile` (choice, default `none`): `committed` gives
the measured workspace a `MODULE.bazel.lock`, as a real team's checkout
carries. Without one, every clean build re-evaluates the module
extensions whose results Bazel stores in the lockfile; whether that
cost matters needs the same kind of same-runner A/B (`ab=lockfile`).

The lock is produced the way a team's committed lock would be:
generated on the runner, before any measured build, by an unmeasured
Bazel run with the workspace's default lockfile mode and its own output
base. That run builds every bench target for both configs, analysis
only (`--nobuild`), so it evaluates everything the measured builds
need while staying fast. Its output base is deleted afterwards and its
server shut down. Every measured build still starts from a fresh output
base. The lock is generated once per job and every repeat gets the same
bytes.

With `ab` off, `ios-sol.json` stays what it is today and also records
`meta.lockfile`. With `ab` off and `lockfile` none, every run is
exactly today's: the generated workspace is byte-identical, every Bazel
command line is unchanged, and the `ios-sol.json` fields keep their
meaning.

## Speed-of-light (SOL) mode

The performance dashboard compares each developer flow's cost with its best
case: the same SDK tools run by hand for the same edit. Dispatch the same
workflow with `mode=sol` (Actions > "iOS perf bench" > Run workflow >
`mode: sol`); only `head_ref` is checked out, generated and built.

Per configuration (`device_release`, `sim_debug`, `android_release`,
`android_debug`, `web_release`, `web_debug`) and scenario (`clean`,
`app_edit`, `core_edit` — the same edits compare mode applies), `sol`
mode measures two numbers in the same unit, whole-tree user+sys CPU
seconds:

- the Bazel cost: for the `clean` flow, the whole `bazel --batch build`
  process tree (Bazel's own work plus every action), measured with wait4
  rusage deltas, which include reaped descendants on both macOS and Linux.
  Edit flows (`app_edit`, `core_edit`) are measured against a warm server,
  not `--batch` (below). One unit for the whole run. A macOS instruction
  counter cannot do this: `/usr/bin/time -l` reads "instructions retired"
  for its direct child alone (the JVM for a build, the Python driver for a
  chain), so instructions are never the flow number; `unit` in
  `ios-sol.json` is always `cpu_seconds`.
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs), run by hand in order. The SOL number is the sum of
  the chain steps' own process-tree CPU — the driver's own cost
  (loading the log, hashing, moving files) is never included. Steps
  whose outputs did not change for the edit are skipped as a person
  would skip them: the execution log records executed spawns only, so
  replaying it replays exactly the work the edit required. Edit flows
  run the chain from the warm-server build's execution log, exactly as
  clean flows run it from the `--batch` build's log.

The clean flow is a cold measurement: one `bazel --batch build` with no
server, so its cost includes Bazel startup and full analysis. Edit flows
are warm measurements: after the clean chain and host-tools replay have
restored Bazel's outputs, a server starts on the same output base (same
startup options minus `--batch`), and one unmeasured warm-up build of
the same target and flags must execute zero actions — otherwise the
config fails, because the outputs were perturbed and the edit would not
measure an incremental build. Each edit scenario then applies its
cumulative edit and builds through that warm server. While the server
is up every Bazel command on that output base goes through it, never
`--batch`; the server shuts down after the config's last flow and on
every error path, so no server outlives its config.

The warm number (`tools/perf/warm_server.py`, usable by any other bench)
is the CPU growth of the whole process tree for the one measured
client command: the waiting client's own CPU, the server's own CPU
growth, the server's reaped-children growth, and the growth of the
server's live descendant tree (a child that appears mid-command is
counted from zero). It fails closed — missing server, a server that
restarted under the same pid, or an unreadable sample is a config error,
never a number. Known limit: a descendant that exits and is already
reaped when the command ends contributes its whole-life CPU through the
parent's reaped-children time, so the split across parts is approximate
while their sum is exact. Edit flows record `method: "warm-server"` and
the per-part breakdown as `bazel_parts`; clean flows record
`method: "batch"` with no breakdown. The `profile.jvm` counter covers
the same trace whether the build ran batched or through the server, and
the residual still excludes all server time, so for a warm flow the
residual is mostly JVM launch and analysis-cache warmth the trace
counter never sees.

Every flow record also carries wall time and peak memory in its `bazel`
object (`real_s`, `peak_rss_mb`), and each flow summary gains `wall_s` and
`peak_rss_mb` (medians; `spread.wall_s` and `spread.peak_rss_mb` are
`[min, max]`, and `null` for records without the value). `peak_rss_mb` is
the largest sum, in MiB, of the resident sets of a root pid and all its
descendants (persistent workers included), sampled by
`tools/perf/peak_rss.py` every 0.5 s at most plus one final sample at the
end of the command: the Bazel server tree for an edit flow, the spawned
client and its descendants for a clean flow. A process that vanished adds
0 and an unreadable sample fails the flow. In A/B mode each `ratio` entry
keeps its CPU keys and gains `wall` and `peak_rss` objects with the same
`median`, `min`, `max`, `geomean`, `n` and `unpaired` fields, paired like
the CPU ratio; `unit` stays `cpu_seconds`.

Chain selection is output-based: a host-tool build is a spawn whose
declared outputs land in an exec configuration
(`bazel-out/*-exec-*/`, or Bazel 9's default with no `-ST-<hash>`
suffix, `bazel-out/*-exec/`), and only those are left out (building
Bazel's helper tools is part of the gap). Every other executed spawn
runs, whatever tool binary it invokes — an action that runs an
exec-built tool to produce target-configuration outputs (the kernel
compile, for example) belongs in the chain. Command arguments never
classify: they name the tool that runs, not what is built. (Compare
mode's replay allowlist is unchanged.)

Proof the SOL did the same work cannot pass by accident: each chain
step runs as Bazel runs it — its declared outputs are removed before
it starts, so merge-style steps cannot see stale inputs — and steps
run in dependency order even for edges the execution log never
records: a step whose input (as the log lists it, with symlinks in the
execroot followed) is, or resolves to, another step's declared output
runs after that step, with ties keeping the log order. A step that
would start while one of its inputs is still a moved-aside output no
earlier step re-created is an ordering failure: it never runs, and the
flow reports `identical: false` with a reason naming the step and the
input. Before the chain every declared output of every step that will
run is moved aside. After the chain, whatever the chain wrote at those
paths is removed and Bazel's originals move back, recreating any parent
directory the chain removed; files and directories the chain created
under `bazel-out` that no step declares (an undeclared sibling of a
declared archive, say) are removed as well. This holds whether the
chain succeeded, stopped at a failed step, or wrote different bytes, so
the next incremental build always finds exactly the files Bazel left.
The scenario's verify set comes from declared outputs only, never a
glob over `bazel-out` (whose leftovers are not this build's outputs):
device_release hashes the App.framework binary among the framework
target's listed outputs (`cquery --output=files`); sim_debug hashes
every file in the final app bundle's payload — every entry of each
listed `.ipa` archive, and every file under each listed `.app`
directory (the kernel blob and the App.framework binary are among
those files) — compared by entry path and content, so archive metadata
such as zip timestamps is not part of the proof. Android hashes every
entry of each declared `.apk`/`.aab` archive the same way (zip
timestamps, extra fields and entry order ignored); Web hashes every
file under the declared web build output directory at its relative
path — the directory carrying the built `index.html`, not the DDC
staging directories a debug build also declares. A listing with no
bundle fails loudly instead of globbing. A step that exits non-zero,
times out or cannot start — or any verify entry that differs
afterwards — reports `identical: false` with no SOL number, plus the
step (mnemonic, exit, last stderr lines) and the differing entries
(path with before/after digests; at most 10, plus the count). When a
step fails before the final bundle is written, the bundle does not
exist after the chain: that is the same flow verdict (identical false,
no SOL number, the reason naming the failed step and the missing
entries), Bazel's outputs are restored as usual, and the run continues
with the next scenario — only a fault in the tool itself fails the
config. An unexpected error in one config records its remaining flows with the
error as their reason, lets the other config run, and still writes and
uploads `ios-sol.json` (the job may fail afterwards). Bazel info/query
output is captured stdout-only (Bazel's stderr carries JVM warnings
that once corrupted a parsed path), and every parsed line must resolve
to an existing path under the output base.

Medians over `repeats` go to one small artifact per platform: the iOS
configurations write `ios-sol.json` (unchanged), Android writes
`android-sol.json` and Web writes `web-sol.json`, each with the same
schema:

```json
{
  "rules_flutter": "<full sha>",
  "unit": "cpu_seconds",
  "runner": {"system": "Darwin", "machine": "arm64"},
  "flows": {
    "ios-release-clean": {"bazel": 1, "sol": 1, "identical": true,
                          "reason": "ok",
                          "chain": {"steps": {"Genrule": {"count": 1,
                                                          "cpu_s": 1}},
                                    "skipped": {"host-tool build": 2},
                                    "failed": [],
                                    "ordering_failed": null,
                                    "verify_differ": {"n": 0, "differ": []},
                                    "output_drift": {"n": 0, "paths": []},
                                    "side_effects_removed": {"n": 0,
                                                             "paths": []},
                                    "sol_cpu_s": 1,
                                    "status": "ok"},
                          "spread": {"n": 3, "bazel": [1, 1],
                                     "sol": [1, 1]}}
  }
}
```

Flow ids are `ios-release-{clean,app,body}` (device_release; `body` is
the core_edit), `ios-debug-{clean,app,body}` (sim_debug),
`android-release-{clean,app,body}`, `android-debug-{clean,app,body}`,
`web-release-{clean,app,body}` and `web-debug-{clean,app,body}`. Each flow
carries a small `chain` record — steps run per mnemonic with their CPU
seconds, spawns left out per reason, any failed step, any ordering
failure (step plus the still-moved-aside input), any differing verify
entries (path with both digests; at most 10, plus the count), the
chain-created files removed afterwards, and (information only) the
number of chain-step outputs whose digest differs from the digest the
execution log recorded in `actualOutputs` (with up to 10 such paths) —
with no command lines — and a one-line `reason`, also printed per flow
in the job log, so the artifact alone explains what the SOL ran and why
a flow is not identical. The driver is `tools/perf/sol.py` (`run` / `chain` /
`summarize`; unit tests in `sol_test.py` run on Linux CI from recorded
fixtures, including a `run` -> `chain` -> `summarize` end-to-end pass
against a fake `bazel` in both `--batch` and warm-server modes — the
fake Bazel runs a tiny daemon so the warm tests exercise the real
server start, zero-action warm-up and per-part measurement —
with no time binary present). The warm-server measurement itself is
`tools/perf/warm_server.py` (tests in `warm_server_test.py`: a real
process tree on Linux, macOS conversion math against stubbed system
calls, and fail-closed paths).

The generated workspace (`tools/perf/gen_monorepo.py`) builds the bench
app end to end on the runner with no developer-only setup: its
`.bazelrc` sets `common --lockfile_mode=off` by default, and it
registers only the Flutter toolchain (no LLVM or other dev-only
toolchains).

Each flow also carries a small `profile` record, always on, with no
command lines:

- `jvm`: Bazel's own CPU, from the build's `--profile` JSON trace: the
  "CPU usage (Bazel)" counter (`ph: "C"`, `args.cpu` cores, about one
  sample a second) integrated over time and split at the build-phase
  markers, so `phases` names analysis, execution and the rest. The
  counter starts after JVM launch, so launch CPU lands in `residual`,
  not `jvm`.
- `host_tools`: the chain-excluded host-tool builds, replayed by hand
  under the same wait4 method after the chain restores Bazel's outputs
  (total, per mnemonic, top 10 targets). A host build that fails to
  replay is recorded, not fatal.
- `residual`: `bazel - jvm - sol - host_tools`, never clamped, so the
  parts always sum to the flow's Bazel number. A failed chain has no
  SOL number, and the record says so and substitutes the chain CPU
  instead.

The gzipped trace profiles and execution logs behind each record go to
a second small artifact, `ios-profile` (same 3-day retention, no build
outputs). Medians across repeats recompute the residual from the
medians, so the parts still sum exactly.

## Two floors for the mobile edit flows (`replay` and `toolchain floor`)

The replay floor (`sol`) re-runs the tool binaries Bazel ran, so it
includes whatever the rules decided to run: a debug body edit re-runs a
one-shot kernel compile, an asset copy and a full bundle sign. A gap
against anything cheaper can never show there. `sol` mode therefore adds
a second floor, `toolchain_floor`, to each mobile edit flow (iOS
simulator debug, iOS device release, Android debug, Android release; not
Web, not `clean`), written by hand in `tools/perf/floor*.py` against the
SDK and platform tools:

- **Includes (debug edit):** a resident `frontend_server` in incremental
  mode (first compile untimed), the recompile after the edit, the kernel
  blob replaced inside a copy of the built package in place, and the
  least re-signing the platform accepts: iOS seals the changed bundle
  only (no `--deep`, frameworks keep their signatures); Android signs the
  package once (v2 only) with no recompression and no realignment of
  unchanged entries.
- **Includes (release edit):** the AOT kernel compile, exactly one
  `gen_snapshot`, the snapshot replaced inside the package, the same
  minimum re-sign.
- **Excludes:** Bazel itself, analysis, caching, action setup, asset
  copies, linking, host-tool builds and anything the chain does not need.
  Untimed setup (the first resident compile, a throwaway keystore) is not
  counted. CPU is the same wait4 whole-tree clock as the replay chain; the
  resident compiler's CPU is its exit total minus its CPU after the first
  compile.

Tool paths come from the workspace the bench built (its external
repositories, and Xcode's `codesign` via `xcrun --find`), never from a
host install; an unfindable tool is named in `floor_reason`. The
replaced package must pass the platform's own check (iOS: `codesign
--verify --strict`, `Info.plist` and the executable present; Android:
`apksigner verify`, `zipalign -c`, `AndroidManifest.xml` and the Dart
payload present); otherwise the flow has `floor_identical: false`, a
non-`ok` `floor_reason` and no `toolchain_floor`.

`ios-sol.json` and `android-sol.json` flows carry `toolchain_floor`
(median CPU seconds, same unit as `sol`), `spread.toolchain_floor`,
`floor_identical`, `floor_reason` and `bazel_over_toolchain_floor`
(bazel / toolchain_floor) beside the unchanged `sol` keys. A floor failure
marks only these fields; it never changes `sol` and never fails the
replay chain. `sol.py run --floor=off` (default `on`) writes exactly the
output the base wrote.

## Cost rules (binding)

`workflow_dispatch` only; `macos-15`; job timeout 300 minutes; artifact
retention 3 days; no caches; never upload build outputs; never touch
`ci.yaml` or `full.yaml`. The generator and measurement scripts are the
tooling in `tools/perf/` (Python 3 stdlib only).

## Deadline (sol and ab runs)

The iOS and Linux bench jobs stop measuring 30 minutes before the job
timeout, so the summary and the artifact uploads still run. The first step
records `BENCH_DEADLINE` (job start plus 270 minutes) in `$GITHUB_ENV`;
every `sol.py run` and `ab.py run` call passes `--deadline-epoch
"$BENCH_DEADLINE"`, and each measuring step has `timeout-minutes: 280`.
Once the deadline has passed no flow or config starts; a measured Bazel
command still running is killed with its process group and the config's
server is shut down. Every flow not finished is recorded with reason
`timeout` and no numbers, and the run exits non-zero. The summaries mark
those flows (`reason` contains `timeout`, null numbers, A/B ratios list
the repeat as `unpaired`) and set `meta.timed_out` to `true`; without a
timeout the key is absent. Without `--deadline-epoch` nothing changes, and
`mode=compare` has no deadline.

## Calibrating the replay set

`tools/perf/replay.py` replays a mnemonic allowlist
(`DEFAULT_IOS_MNEMONICS`: the iOS `Flutter*` actions verified in
`flutter/`, plus best-effort `CppCompile`, `CppLink`, `ObjcCompile`,
`ObjcLink`, `SwiftCompile`, `Lipo`). Every report includes the
executed-but-not-replayed table, so the first dispatch shows exactly which
Apple-side mnemonics (actool, storyboards, codesign, final bundle/link)
were missed; extend the allowlist with `--mnemonic` (workflow) or in the
default set (follow-up commit).

## Testing without macOS

Everything except the Bazel invocation, the replay execution, and the
`time -l` counter runs on Linux:

- `python3 -m unittest discover -s tools/perf -p '*_test.py'`
- Generate a small workspace and analyze it:
  `python3 tools/perf/gen_monorepo.py generate --target-loc 20000
  --rules-flutter <checkout> --out <dir>`, then
  `bazel build //packages/... //app:app //app:app_lib --nobuild` in it.
  All three bench targets must load:
  `bazel query '//app:app_framework + //app:app_ios +
  //app:__app_framework_framework'`. The device_release target goes
  further: `bazel build //app:__app_framework_framework --nobuild -c opt
  --ios_multi_cpus=arm64` completes analysis on Linux (only execution
  needs the Apple SDK). The full `//app:app_ios` analysis fails on Linux
  at Apple toolchain resolution, which is expected — macOS builds it.

## Scale bench (packages and plugins)

`gen_monorepo.py generate --packages=N` writes exactly N Dart packages
(N >= 2): it picks `layers` and `fanout` so that `layers * fanout >= N`
and reuses the layered DAG builder; `--target-loc` is then optional (it
defaults to `N * files-per-package * 125`, and the line-count window is
not enforced because the package count is the fixed quantity).
`--plugins=M` (default 0) adds M native plugins under `plugins/` in a
seeded mix of the three kinds the public rules support: iOS source
plugins (Swift or Objective-C plus a podspec), SwiftPM plugins whose
dependencies are pinned in a recorded `Package.resolved` with
`swift_package_sha256`, and Android plugins (Kotlin or Java) whose Maven
coordinates are mapped with `android_maven_deps` and listed with their
sha256 in `plugins/maven_pins.json` (checked against the workspace's
`rules_android_maven_install.json`). The app depends on all of them.
`--packages` with `--layers` or `--fanout`, a non-positive `--packages`
and a negative `--plugins` exit 2. Without the new flags the output is
byte-for-byte the same as before.

`scale_report.py --point PACKAGES,PLUGINS,SOL_JSON ...` (two or more
points) writes `scale.json`: per flow the cost, analysis-only time, action
count and actions per plugin at every size, and the fitted growth
exponent (least-squares slope of log cost against log size) over
packages and over plugins. The plugin axis counts the app as one unit
(size = plugins + 1) when a 0-plugin point is present. It exits 1, after
writing `scale.json`, when an exponent exceeds its ceiling in
`tools/perf/scale_ceilings.json`, a flow failed or a flow has no ceiling.
The nightly `perf-scale-linux.yaml` (Android) and `perf-scale-ios.yaml`
workflows measure 200 and 2,000 packages and 0 and 30 plugins, then run
the report.

## CPU attribution (clean and cold flows)

`python3 tools/perf/sol.py summarize` adds `flows.<flow>.attribution`
(a sibling of `profile`) to `ios-debug-clean`, `ios-debug-body`,
`ios-debug-app`, `android-debug-body` and `android-release-noop`. It reads each repeat's
saved `trace.json.gz` and `execlog.json.gz`, so no extra Bazel run is
needed, and reports the median over repeats, in CPU seconds (the unit of
the flow's `bazel` total):

- `parts.fetch_extract`, `module_resolution`, `loading_analysis` and
  `sandbox` are CPU seconds of the `bazel` process: the profile's
  "CPU usage (Bazel)" counter (cores) integrated over the wall-clock
  time each category is active. Each instant goes once, to the most
  specific category active on any thread (sandbox, then fetch, then
  module resolution, then loading/analysis), so nested events and
  events that overlap on parallel threads are split, never counted in
  both.
- `host_tools` (`total`, `by_mnemonic`, `by_repo`: ten largest, then
  `other`) is the execution log's `userTime` + `systemTime` of executed
  spawns whose listed outputs land in an exec configuration.
- `host_tools.by_repo_owner` maps each repository in `by_repo` (not
  `other`) to the sorted exec tool target labels whose closure pulled it
  in. It is derived from the saved execution log: spawns that build host
  tools and read the repository's outputs as inputs, followed through
  other host-tool spawns to the outermost target. Labels are the union
  over repeats. When the log does not tie a repository to a tool its
  entry is `[]` and the attribution's `warnings` list names it
  ("no exec tool target found for repository <repo>"); a tool is never
  guessed.
- `spawns_by_mnemonic` (a sibling of `parts`) gives, for every mnemonic
  of the execution log, `executed` (spawns that ran) and `cache_hit`
  (spawns with `cacheHit` true), each the median over repeats (a repeat
  without the mnemonic counts 0). `ImportedDynamicFrameworkProcessor`,
  `ProcessAndSign` and `BundleApp` are always listed, with 0 and 0 when
  they did not occur, so an absent spawn is never read as missing data.
- `target_actions` is the same CPU of the remaining executed spawns.
- `unattributed` is `total_s` minus the six parts above; `gap_s` equals
  it (never clamped). `ok` is `abs(gap_s) <= 0.05 * total_s`.

When the data is missing the flow's `attribution` is
`{"ok": false, "error": "<what is missing>"}` with no parts: a repeat
directory without `trace.json.gz` or `execlog.json.gz`, a trace with no
fetch/module/loading/analysis events or no "CPU usage (Bazel)" counter
samples, an execution log whose executed spawns carry no
`metrics.userTime`/`systemTime` (the Linux sandbox runner reports none),
or whose spawns list no outputs (`listedOutputs`/`actualOutputs`), or
whose spawns list no `inputs` (needed for `by_repo_owner`).

When executed spawns carry no `metrics.userTime`/`systemTime` (as on the
macOS runner) but do carry `metrics.executionWallTime`, `attribute_flow`
returns `"ok": false` naming the missing CPU metrics and carries a sibling
record `host_tools_wall`:
`{"unit": "wall_s", "total": ..., "by_mnemonic": {...}, "by_repo": {...}, "by_repo_owner": {...}}`.
Its unit is summed spawn wall seconds (`"unit": "wall_s"`) across executed
host-tool spawns and not CPU (because concurrent spawns add up, the sum can
exceed elapsed wall time), and it is never part of `parts`. Its `total`,
`by_mnemonic` and `by_repo` are medians over repeats of the ten largest then
`other`, and `by_repo_owner` maps each repository in `by_repo` to its owner
targets (`[]` plus a warning in `warnings` when no owner target is found).
When neither CPU metrics nor `executionWallTime` are present, or the log
lists no spawn inputs, `attribution` returns `{"ok": false, "error": ...}`
with no `host_tools_wall`.

`--strict-attribution` makes `summarize` exit non-zero when a flow's
`ok` is false (default off). Once this lands, the bench step in the
iOS perf workflow that runs `sol.py summarize` must pass
`--strict-attribution`; the workflow is not changed here.

## Android and Web A/B

`.github/workflows/perf-linux.yaml` takes the same `bazel_flags` and `ab`
inputs as the iOS workflow (`ab` is `"off"` or `flags`). With `ab=flags` it
validates the inputs first (`ab=flags` with empty flags fails at once),
copies the pristine workspace (with the committed lockfile, generated once,
when `lockfile=committed`) to a control and a treatment copy, applies the
flags to the treatment copy only, and runs `ab.py run --platform <platform>`
for `repeats` repeats, control first on odd repeats and treatment first on
even ones. `ab.py summarize --platform` writes `<platform>-ab.json` in the
shape of `ios-ab.json` (the flows are the platform's two configurations);
the default platform stays `ios`. The artifacts are `<platform>-ab` (only
`ab=flags`), `<platform>-sol` (only `ab=off`) and `<platform>-profile` (the
gzipped traces and execution logs, no build outputs). With `ab=off` the run
is the single run as before; non-empty `bazel_flags` are then applied to the
measured workspace.
