# Incremental kernel compiles

`rules_flutter` can keep the Dart `frontend_server` warm across debug
compiles instead of starting a cold one per build. The finished kernel is
canonically equal either way: the worker always ends with **rule F**, a
`reset` followed by an empty `recompile`, so the output dill comes from a
compile that compiled nothing and carries no history. The worker output is
the unlinked app component (no `dart:` platform link, no call-site metadata
hint payloads); the stock batch output links the platform libraries and
carries `vm.call-site-attributes.metadata`. Canonical check on
`e2e/hello_world`: `canon(platform_strong.dill + F) ==
canon_strip_md(batch)` is byte-equal (53,175,968 bytes both sides; all 739
app libraries and all 1,051 sources identical, same `main`). Only the
second and later builds go faster; the first compile of a configuration
pays the cold cost.

The byte-equality between a warm worker's dill and the one-shot compile's is
checked by `//tools/incr_kernel_identity` (`bazel run
//tools/incr_kernel_identity` from the repo root), which the `E2E Linux app
(hello_world, codegen)` CI job runs. The check builds `e2e/hello_world`'s
`//:hello_world` under `-c dbg` with the flag on, in two fresh output bases:
a worker leg (`--strategy=FlutterKernelCompile=worker`, one worker instance)
builds the original sources, then two successive edits touching more than one
app library including an import change, then the revert; a one-shot leg
(`--strategy=FlutterKernelCompile=local`) builds the same states. Every
worker dill must be byte-equal to the one-shot dill of that state, every
compared build must have executed its compile under its stated strategy (no
cache hit, no fallback), and the worker leg must prove one worker and one
compiler process served all four builds. The check calls Bazel as the `BAZEL`
environment variable names, or `bazel` on PATH: under `bazel run` the PATH
`bazel` is Bazel's own binary, so a caller whose Bazel is a wrapper sets
`BAZEL` to that wrapper.

## Default and opting out

The worker is on by default for debug builds (`-c dbg`), which is what the
iOS simulator and Android debug flows build, so a debug edit does not pay a
cold `frontend_server`. Every other compilation mode (fastbuild, opt) and
every AOT, web, `from_dill`, `import_dill` or `recorded_uses` compile runs
the stock one-shot action, byte-identical to a build without the worker, so
release, CI and remote-cache builds keep hitting their caches.

A plain debug `flutter_application` (no define, define file, flavor, native
asset, recorded use or widget-creation tracking) compiles per-package kernel
modules and links them by default, so it registers no `FlutterKernelCompile`
and the worker is not involved. #421 had turned this default off because the
linked kernel failed to load in the VM (`Invalid kernel binary: Contains at
least two source entries that do not agree`); rules_dart fixed its module strip
in #422 and the default is back. Opt out with
`--@rules_flutter//flutter/private:debug_modular_app=false`: the app then
compiles whole program and takes the warm worker. Every other
application, and every `flutter_test` or web build, is unchanged.

To restore the stock action in a debug build:

```sh
bazel build -c dbg --@rules_flutter//flutter:incremental_kernel=false //app:app
```

The flag is a `bool_flag` defaulting to `True`. The worker's dill is
canonically equal to the one-shot dill (above), but a debug build that goes
through a remote cache or executor with the worker route gets a different
action key than the stock action; set the flag to `false` there. The bench
(`tools/perf/incr_kernel_ab.py`) reports the iOS (`sim_debug`) and Android
(`android_debug`) debug body-edit flows with each setting on and off in one
session, so the numbers behind the default are reproducible.

## Dev-only incremental serialization

```sh
bazel build --@rules_flutter//flutter:incremental_kernel \
  --@rules_flutter//flutter:dev_incremental_serialization //app:app
```

By default the worker starts `frontend_server` with
`--no-incremental-serialization`, so every warm edit rewrites the full dill
from scratch. `//flutter:dev_incremental_serialization` (a `bool_flag`,
default `False`) starts it without that flag, which keeps the server's
incremental serialization. A reporter measured the reset phase at 13-16 s
with the default against 1.6 s without it (one build each, one machine).

- It is **not** the default, and cannot be: its dill is not byte-identical to
  a one-shot compile and its compiles carry `no-remote-cache` and
  `no-remote-exec`, so defaulting it on would take every debug build off
  shared caches and remote executors and make outputs differ between a
  cold and a warm build.
- It only has an effect together with `//flutter:incremental_kernel`, on the
  same compiles that flag routes through the worker.
- The resulting dill is **not byte-identical** to a one-shot compile.
- It is for development only: do not use it in CI or remote-cache
  configurations. Every compile that uses it carries the execution
  requirements `no-remote-cache` and `no-remote-exec`, so a dev dill never
  reaches a shared cache or a remote executor.
- With the setting off (the default), every `FlutterKernelCompile` action is
  unchanged.

## Scope

JIT whole-program compiles of debug builds only (`target == "flutter"`,
non-AOT, `-c dbg`). The flag never applies to AOT, web (`dartdevc`), `from_dill`,
`import_dill` or `recorded_uses` compiles — those always run the stock
action. The guard and read-set checks enforce the same manifest-only policy
as the stock `kernel_filter` path — allowances come only from the
`--declared-inputs` manifest, never from the compiler argv — with identical
refusal messages. The worker deletes its `incr_fkc_*` temp directories on
every exit path, so no state survives a finished build. A worker that is
killed outright cannot run that cleanup, so every starting worker also
reclaims the scratch of workers that are no longer alive (kept alive-proof
by an exclusive lock file each worker holds for its life, published
atomically so it never exists unlocked: a starting worker opens each
sibling's lock read-only and attempts a shared lock in process, and only
an acquired lock means dead — never age or PID).

## Strategies

The compile runs through `incr_fkc_worker`, a Bazel JSON persistent worker
built from Dart (no host Python, no new downloads):

- `worker` strategy: Bazel keeps the worker process alive, and the worker
  keeps one warm `frontend_server` per distinct compiler configuration
  (argv minus the output path). Repeated builds recompile only the changed
  libraries. Declared `org-dartlang-app` deltas recompile by URI — staged
  generated files through the stage root, sources read in place through the
  mounted exec root; any other changed input restarts that server cold.
  Servers that fail, or whose process dies, restart cold on the next request.
- `sandboxed` / `local` / `remote` strategies: the same binary runs once
  per action (a fresh process that compiles cold, then applies rule F), so
  the output is identical without any persistent state.

The worker decides what changed from the SHA-256 digests Bazel sends with
each input in the request. Bazel 9.x builds a digest as the 64 lowercase hex
characters of the SHA-256, as bytes, and the JSON worker protocol prints that
`bytes` field as base64, so the worker receives 88 base64 characters that
decode to those 64 hex characters. It accepts that form, the 64 hex
characters themselves, and the base64 of the 32 raw digest bytes. Any other
value (wrong length, not base64, or a decoded value that is not 64 hex
characters) is not usable.

A file's contents are read for change detection only for an input with no
usable digest (absent, empty or malformed). The trade-off: a wrong digest from
Bazel silently skips a recompile. The directive guard still reads every Dart
source itself, because it must see an edit a stale digest hides; it reuses the
content hash that change detection already computed for the same request, so
no source is hashed twice. The read-set check reads the sources as well.

Each worker keeps at most one warm server by default. One warm server holds
about 1.75 GiB of compiler state, so on small machines bound the worker
processes with `--worker_max_instances=FlutterKernelCompile=N`
(`INCR_FKC_MAX_SERVERS=M` raises the per-worker server cap instead, at
~1.75 GiB per server).

## Errors

A compile error, a guard refusal, or an undeclared read fails the build
with the compiler's diagnostics (or the refusal text), exactly as the
stock action would. The next build resumes from the last accepted state:
rejected recompiles are repaired by recompiling the same URIs again, so
fixing the error and rebuilding converges without a cold restart unless an
input outside the declared sources changed.

## Coverage

The contract's goals map to suites: mount order and declared-once inputs to
`//flutter/tests/kernel_mount/...`, the fail-closed report checks to the
`runFiltered` tests in `flutter/private/tools/test/kernel_filter_test.dart`,
and the worker's in-place mapping, twin dedupe, warm in-place delta, and
mount-order precedence to `incr_fkc_worker_test.dart` (the `kernelMountContract`
groups in both files pin the contract's shapes). The scratch suite beside the
worker tests (`incr_fkc_scratch_test.dart`) is untouched and must stay green.
