"""The `package:test` runner that `dart_test` runs a test through.

`dart_test` compiles a test at build time and runs it under `package:test`'s own
runner, because that runner is what implements the protocols Bazel asks a test
framework to honour: `--test_filter`, sharding, and a per-case result report.
Run directly, a test file gets none of them, and `package:test` applies a
hard-coded 30-second timeout per case besides — a second authority over time
that Bazel's `size`/`timeout` already owns.

The runner and the test must come from the same `package:test`: they talk over
a protocol private to that package's version, so a runner pinned by rules_dart
would drift from the version a user's lockfile resolves. The runner is therefore
built from the user's own `package:test`, once per version, inside the spoke
repository that provides it: the spoke's public `test` target is a
`dart_test_package` that forwards the library unchanged and carries the runner
beside it, and `dart_test` finds the runner on whichever direct dependency is
`package:test`.

The runner is large, and the VM compiles its kernel again on every test run:
about 0.37 s of each test's startup. So the spoke also keeps an app-JIT
snapshot of the runner. It is taken by running one real test under the runner
(`runner_training_test.dart`, compiled by `dart_test_kernel`), so it holds the
code a test takes, and it starts in about 0.12 s. The snapshot is built only
when the exec and target SDKs are the same `dart`: an app-JIT snapshot is
accepted only by the VM that wrote it, and the snapshot is written by the exec
SDK but run by the target SDK in the test. Where they differ, there is no
snapshot and the kernel is run as before. It is also not built on Windows,
where the training scratch directory has no room under the path limit (see
`app_jit_snapshot.dart`), so the snapshot would depend on the build's path.

The training run is `--deterministic` and targets an unknown CPU, and runs with
the same inputs at the keyed absolute training path for its output in the same
environment each time, from a copy of the SDK's `dart` (see
`app_jit_snapshot.dart`). Those make the snapshot the same across builds and across SDK install locations. The
baseline-CPU target is meant to let a remote cache share it across CPUs. The
snapshot's action key does not record the CPU features its code uses, so that
intent is the only guard against a cache serving code a CPU cannot run.

Like a `dart_binary` `jit-snapshot` training, the runner training is
byte-identical across builds: `package:test` derives heap strings from the
training run's own paths, but at the keyed training path those read the
same on every build. The action key holds no absolute path, so remote caching
stays on for it with the fallback off: the first machine's snapshot is reused
and every dependant keeps one action key.

`//dart:test_runner_snapshot` turns the snapshot off for the whole build: the
kernel runs instead, as before. Use it for a snapshot that misbehaves.

When the keyed training path is blocked by an entry another user owns, or its
lock stays held past `--@rules_dart//dart:jit_snapshot_lock_timeout` seconds,
the snapshot action fails and names the entry rather than training elsewhere
under the same action key. `//dart:jit_snapshot_fallback` allows the
non-reproducible private-scratch fallback instead, and is part of the action's
command line, so builds that allow it and builds that do not have different
action keys. A fallback-trained snapshot stays cached under the same action
key (in the local action cache and the output tree) until `bazel clean`, so a
build after the host is fixed keeps the fallback bytes. With the flag on, both
snapshot actions carry `no-remote-cache`, so they are never uploaded to or
served from a disk or remote cache.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartCompileInfo", "DartInfo")
load("//dart/private:common.bzl", "JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT", "jit_train_key", "kernel_sdk_mismatch_error", "sdk_dartvm", "writable_home_env")
load("//dart/private:dart_compile.bzl", "jit_tool_entry")
load("//dart/private:dart_kernel.bzl", "DartKernelInfo", "dart_kernel_module_aspect")

DartTestRunnerInfo = provider(
    doc = "The `package:test` runner built from a `package:test` library.",
    fields = {
        "runner": "File: the runner the launcher runs — its kernel (`.dill`), or the app-JIT snapshot of it where one was built.",
        "sdk_version": "str: The Dart SDK version that compiled `runner` when it is a kernel, or empty.",
    },
)

DartTestRunnerSnapshotInfo = provider(
    doc = "The app-JIT snapshot of a `package:test` runner, or `None` where it cannot be built.",
    fields = {
        "snapshot": "File or None: the snapshot, written by the exec SDK's `dart`.",
    },
)

DartTestKernelInfo = provider(
    doc = "A test compiled to the kernel that runs under a `package:test` runner.",
    fields = {
        "dill": "File: the kernel, declared where the runner's `--precompiled` layout expects it.",
        "precompiled_dir": "str: the `--precompiled` directory holding `dill`, as an exec-root path.",
        "test_path": "str: the test's path as the runner names it, under `precompiled_dir`.",
        "source": "File: the test's source, which the runner reads for its annotations.",
    },
)

DartTestRunnerMainInfo = provider(
    doc = "Marks the generated `package:test` runner entrypoint (`dart_test_runner_main`). The runner `dart_binary(compile_mode = \"kernel\")` compiles modularly by default (stripping source text from `.kmod` modules), and omits embedded sources if it falls back to a whole-program kernel.",
    fields = {},
)

# The runner's entrypoint is `package:test`'s own `bin/test.dart`, which does
# nothing but re-export this library. `bin/` is not part of a pub spoke, which
# stages `lib/` only, so the one line is written here instead.
_RUNNER_MAIN = """\
// Generated by rules_dart: the `package:test` runner, as `dart test` runs it.
export 'package:test/src/executable.dart';
"""

def _dart_test_runner_main_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.write(output = out, content = _RUNNER_MAIN)
    return [
        DefaultInfo(files = depset([out])),
        DartTestRunnerMainInfo(),
    ]

dart_test_runner_main = rule(
    implementation = _dart_test_runner_main_impl,
    doc = "Writes the entrypoint the `package:test` runner is compiled from.",
)

def _runner_kernel(ctx, runner):
    """The `.dill` a kernel-mode `dart_binary` produced.

    Args:
      ctx: The rule context, for the error message.
      runner: The `dart_binary` target.

    Returns:
      The kernel File.
    """
    if DartCompileInfo in runner and runner[DartCompileInfo].compile_mode == "kernel":
        return runner[DartCompileInfo].executable
    dills = [f for f in runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    return dills[0]

def _dart_test_package_impl(ctx):
    library = ctx.attr.library
    runner = _runner_kernel(ctx, ctx.attr.runner)
    sdk_version = (
        getattr(ctx.attr.runner[DartCompileInfo], "sdk_version", "") if DartCompileInfo in ctx.attr.runner else ""
    )
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
            sdk_version = ""

    # Forwarded beside `DartInfo`, because this target stands in for the library
    # in every `deps`. Without it, each test that depends on `package:test` would
    # find no module kernel for it and compile whole-program.
    forwarded = [library[DartKernelInfo]] if DartKernelInfo in library else []
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner, sdk_version = sdk_version),
    ] + forwarded

dart_test_package = rule(
    implementation = _dart_test_package_impl,
    attrs = {
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
            aspects = [dart_kernel_module_aspect],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = "A `dart_test_runner_snapshot` of `runner`. Its snapshot runs in place of the kernel when one was built.",
            providers = [DartTestRunnerSnapshotInfo],
        ),
    },
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)

def _dart_test_runner_snapshot_impl(ctx):
    target_sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    exec_sdk = ctx.toolchains["//dart:exec_tools_toolchain_type"].dart_sdk_info

    # `//dart:test_runner_snapshot=false` opts the whole build out; see the
    # module docstring for why a build would.
    enabled = ctx.attr._enabled[BuildSettingInfo].value

    # An app-JIT snapshot runs only on the VM that wrote it. This action runs the
    # exec SDK's `dart`, but the test that runs the snapshot uses the target SDK's,
    # so the two must be the same binary. A cross-compile has no such binary, and
    # its tests fall back to the kernel.
    # The training run's scratch directory has no room under the Windows path
    # limit. A Windows exec host gets no snapshot, and its tests run the kernel.
    is_windows = exec_sdk.dart.basename.endswith(".exe")
    if not enabled or is_windows or exec_sdk.dart.path != target_sdk.dart.path:
        return [
            DefaultInfo(),
            DartTestRunnerSnapshotInfo(snapshot = None),
        ]

    mismatch = kernel_sdk_mismatch_error(ctx.label, "runner", ctx.attr.runner, exec_sdk.version)
    if mismatch != None:
        fail(mismatch)

    lock_timeout = ctx.attr._lock_timeout[BuildSettingInfo].value
    if lock_timeout <= 0:
        fail("dart_test_runner_snapshot: `//dart:jit_snapshot_lock_timeout` must be above 0, got %r" % lock_timeout)

    runner = _runner_kernel(ctx, ctx.attr.runner)
    runner_runfiles = ctx.attr.runner[DefaultInfo].default_runfiles.files
    training = ctx.attr.training[DartTestKernelInfo]
    snapshot = ctx.actions.declare_file(ctx.label.name + ".jit")

    # `app_jit_snapshot.dart` trains at the keyed absolute path for this
    # output, where the runner, the precompiled training test and its source
    # are staged; the tool names the script and the `--precompiled` directory absolutely, keeps the
    # test path relative (the runner joins it onto `--precompiled` itself), and
    # trains with the constant directory as its working directory, so the test
    # path resolves into the staged tree. The environment is set here, and
    # nothing else from the action's environment reaches the training run, so
    # a developer's `DartTest.yaml` cannot change what the snapshot is trained
    # on. The training sees no path naming the build (see the module
    # docstring), so the snapshot is byte-identical across builds and remote
    # caching stays on for this action with the fallback off; with the fallback
    # allowed the action carries `no-remote-cache` instead (see below), so a
    # fallback-trained snapshot is never uploaded to or served from a disk or
    # remote cache.
    dartvm = sdk_dartvm(exec_sdk)
    pkg_cfg = ctx.actions.declare_file(ctx.label.name + ".jit_package_config.json")
    ctx.actions.write(
        output = pkg_cfg,
        content = '{"configVersion": 2, "packages": []}\n',
    )
    args = ctx.actions.args()
    args.add(pkg_cfg, format = "--packages=%s")
    args.add(jit_tool_entry(ctx.files._tool))
    args.add(exec_sdk.dart, format = "--dart=%s")
    if dartvm != None:
        args.add(dartvm, format = "--dartvm=%s")
    args.add(snapshot, format = "--snapshot=%s")
    args.add("--train-key=" + jit_train_key(snapshot.short_path))
    if lock_timeout != JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT:
        args.add("--lock-timeout=%d" % lock_timeout)
    args.add("--enable-asserts")

    # With the fallback allowed the trained bytes may be this host's
    # private-scratch ones, so the action carries `no-remote-cache` and never
    # reaches a shared cache. Without it no dict is built and the action is as
    # before.
    fallback_allowed = ctx.attr._fallback[BuildSettingInfo].value
    if fallback_allowed:
        args.add("--fallback-allowed")
    args.add("--env=DART_TEST_CONFIG=none/DartTest.yaml")
    args.add("--env=TMPDIR=.")
    args.add("--env=HOME=.")
    args.add(runner, format = "--copy=runner.dill=%s")
    args.add(training.precompiled_dir, format = "--copy-tree=precompiled=%s")
    args.add(training.source, format = "--copy=" + training.test_path + "=%s")
    args.add("--")
    args.add("runner.dill")
    args.add("--precompiled=precompiled")
    args.add(training.test_path)
    ctx.actions.run(
        executable = exec_sdk.dart,
        arguments = [args],
        inputs = depset(
            direct = ctx.files._tool + [ctx.file._comma_patch, pkg_cfg, exec_sdk.dart, runner, training.dill, training.source] + ([dartvm] if dartvm != None else []),
            transitive = [exec_sdk.compile_files, exec_sdk.runtime_files, runner_runfiles],
        ),
        outputs = [snapshot],
        mnemonic = "DartTestRunnerSnapshot",
        progress_message = "Snapshotting the test runner %{label}",
        env = writable_home_env(exec_sdk.dart, snapshot),
        execution_requirements = {"no-remote-cache": "1"} if fallback_allowed else None,
    )
    return [
        DefaultInfo(files = depset([snapshot])),
        DartTestRunnerSnapshotInfo(snapshot = snapshot),
    ]

dart_test_runner_snapshot = rule(
    implementation = _dart_test_runner_snapshot_impl,
    attrs = {
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`, as `dart_test_package`'s `runner`.",
            mandatory = True,
        ),
        "training": attr.label(
            doc = "A `dart_test_kernel` of the test the runner is trained on.",
            mandatory = True,
            providers = [DartTestKernelInfo],
        ),
        "_tool": attr.label(
            doc = "Every source the JIT tool imports, staged beside its entry in the action that trains the runner snapshot.",
            default = "//dart/private/tools:jit_tool_srcs",
            allow_files = True,
        ),
        "_comma_patch": attr.label(
            doc = "The `comma_patch.dart` source staged beside the JIT tool's entry when training the runner snapshot from source. Defaults to `//dart/private/tools:comma_patch.dart`.",
            default = "//dart/private/tools:comma_patch.dart",
            allow_single_file = True,
        ),
        "_enabled": attr.label(
            doc = "Build setting gating snapshot training: when off, tests run the runner's kernel instead of a trained app-JIT snapshot. Defaults to `//dart:test_runner_snapshot`.",
            default = "//dart:test_runner_snapshot",
            providers = [BuildSettingInfo],
        ),
        "_fallback": attr.label(
            doc = "Whether `--fallback-allowed` is passed when the keyed training path is unavailable.",
            default = "//dart:jit_snapshot_fallback",
            providers = [BuildSettingInfo],
        ),
        "_lock_timeout": attr.label(
            doc = "Seconds the training waits for the keyed training lock. Passed as `--lock-timeout=` only when it differs from the default.",
            default = "//dart:jit_snapshot_lock_timeout",
            providers = [BuildSettingInfo],
        ),
    },
    toolchains = [
        "//dart:toolchain_type",
        "//dart:exec_tools_toolchain_type",
    ],
    doc = "Runs one training test under the `package:test` runner and keeps the app-JIT snapshot that run writes. Empty where exec and target SDKs differ, where the exec host is Windows, or where `--@rules_dart//dart:test_runner_snapshot=false` turns snapshots off. Fails where the keyed training path is blocked by another user's entry, or its lock stays held past `--@rules_dart//dart:jit_snapshot_lock_timeout` seconds, unless `--@rules_dart//dart:jit_snapshot_fallback=true` allows the fallback.",
)
