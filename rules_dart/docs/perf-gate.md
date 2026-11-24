# A performance gate in CI: what it needs

Not built. `bazel run //perf:bench -- check` (in `rules_dart/tools`) already
decides pass or fail for a set of flows against baseline rows; what CI lacks
is everything around it. This lists what the gate job needs, from the bench
harness's own report (`T10`) and the two perf workflows as they are.

## What exists

- `bench check --flows=tag:cheap --baseline=ROWS [--margin=0.25] [--floor=0.05]`
  runs the flows and compares each with the latest baseline row of the same id
  that is `ok`, not `noisy` and has runs. A flow fails when its median is
  slower by more than the margin and the floor, when an actions-per-source
  count grew, when it ran an action mnemonic the baseline did not run, or when
  it has no baseline.
- `tag:cheap` is the small Dart body and API edits, the plain and defines
  Flutter edits, the 500-library analysis with and without the aspects, and
  the actions-per-source counts: about two minutes.
- `dart-perf-linux.yaml` (dispatch) and `dart-perf-scale-linux.yaml` (nightly)
  run flows and print tables; neither checks anything.

## What the gate job needs

1. **Baseline rows CI can read.** The rows live in a ledger on a developer
   machine. The gate needs a checked-in file (or a release asset or a cache
   key) of rows taken on the runner type the gate runs on, in the format
   `bench run --out` writes, and a way to renew it: a dispatch that runs
   `bench run --flows=tag:cheap --out=baseline.jsonl` on the gate's runner and
   uploads the file for review. A baseline taken on a laptop does not
   transfer to a hosted runner.
2. **A quiet runner.** A flow's row is marked noisy above a load threshold
   (a quarter of the processors by default) and the check never takes a noisy
   row as a baseline. T10's proof passed by 1 percentage point of its 25%
   margin at load 20 to 38. The gate must run alone on its runner, or compare
   mnemonics and counts only (`--margin` very large), which a busy runner does
   not disturb.
3. **A pull-request trigger and a verdict.** The two perf workflows are
   `workflow_dispatch` and `schedule`. The gate is a job of `dart-ci.yaml`
   (path-filtered to `rules_dart/dart/**`, `rules_flutter/flutter/**` and the
   bench itself) that runs the check on the pull request's merge commit and
   fails on a nonzero exit; its report goes to the step summary.
4. **The environment of the flows it runs.** `tag:cheap` needs none of the
   following, so they are not part of the first gate: pub flows need a mirror
   (`--bazelrc-line` with a downloader config and `--option=pub_lock=`); the
   Android, emulator and stock flows need the SDKs and `--stock-env`; the
   iOS and Linux desktop rows say "not available here" and need a macOS or
   desktop runner.
5. **Pinned actions.** The `upload-artifact@v7` steps of the two workflows are
   not pinned to a hash.
6. **The first baseline.** Every row of the table T10 took is marked noisy
   except the wide-graph analysis rows; the flows whose two passes
   disagreed (the 5,000-library deep analysis with the aspects and stock, the
   2,000- and 5,000-library wide analysis, the Flutter plain stock and plugins
   edits) must be taken again on the gate's runner before they can gate.
