"""Analysis tests for the SDK `dart`/`dartvm` launcher inputs.

The `dart` launcher finds its sibling `dartvm` by following its own path, so
an action that runs the launcher reads a file its declared subsets may not
name. A custom toolchain whose subsets omit `dartvm` then works locally and in
a symlinked sandbox but fails under remote execution, where only declared
inputs exist. These tests pin both toolchain shapes: subsets that omit
`dartvm` while the SDK root carries it, and an SDK layout with no `dartvm`
where `bin/dart` is the VM itself and keeps running the actions.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:common.bzl", "sdk_dartvm")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

# --- `sdk_dartvm` over fake SDK records ---

_NO_VM_FILES = [
    struct(basename = "dart"),
    struct(basename = "gen_kernel_aot.dart.snapshot"),
]
_WITH_VM_FILES = _NO_VM_FILES + [struct(basename = "dartvm")]

def _subset_without_dartvm():
    """The compile subset of a toolchain whose subsets omit `dartvm`."""
    return _NO_VM_FILES

def _compile_with_dartvm():
    """The compile subset after the toolchain normalization adds `dartvm`."""
    return _WITH_VM_FILES

def _sdk_dartvm_lookup_test_impl(ctx):
    env = unittest.begin(ctx)
    info = struct(
        compile_files = struct(to_list = _compile_with_dartvm),
        tool_files = struct(to_list = _compile_with_dartvm),
    )
    found = sdk_dartvm(info)
    asserts.true(env, found != None, "dartvm in the compile subset is found")
    asserts.equals(env, "dartvm", found.basename, "the compile subset's dartvm is returned")
    return unittest.end(env)

def _sdk_dartvm_absent_test_impl(ctx):
    env = unittest.begin(ctx)
    info = struct(
        compile_files = struct(to_list = _subset_without_dartvm),
        tool_files = struct(to_list = _subset_without_dartvm),
    )
    asserts.true(env, sdk_dartvm(info) == None, "an SDK layout without dartvm keeps the launcher")
    return unittest.end(env)

def _sdk_dartvm_subset_only_test_impl(ctx):
    env = unittest.begin(ctx)

    # One mechanism: the toolchain normalization puts `dartvm` into the
    # compile subset (see dart/toolchain.bzl), so `sdk_dartvm` reads that
    # subset only. A `dartvm` anywhere else in the SDK is not consulted.
    info = struct(
        compile_files = struct(to_list = _subset_without_dartvm),
        tool_files = struct(to_list = _compile_with_dartvm),
    )
    asserts.true(env, sdk_dartvm(info) == None, "dartvm outside the compile subset is not consulted")
    return unittest.end(env)

_sdk_dartvm_lookup_test = unittest.make(_sdk_dartvm_lookup_test_impl)
_sdk_dartvm_absent_test = unittest.make(_sdk_dartvm_absent_test_impl)
_sdk_dartvm_subset_only_test = unittest.make(_sdk_dartvm_subset_only_test_impl)

# --- Probe rule mirroring the kernel and JIT actions ---

def _lows_b_runner_probe_impl(ctx):
    sdk = ctx.attr.sdk[platform_common.ToolchainInfo].dart_sdk_info
    runner = sdk_dartvm(sdk)
    if runner == None:
        runner = sdk.dart
    out = ctx.actions.declare_file(ctx.label.name + ".probe")
    ctx.actions.run(
        executable = runner,
        arguments = ["--probe"],
        inputs = depset(direct = [runner], transitive = [sdk.compile_files]),
        outputs = [out],
        mnemonic = "LowsBRunnerProbe",
        progress_message = "Probing the SDK runner %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

lows_b_runner_probe = rule(
    implementation = _lows_b_runner_probe_impl,
    attrs = {
        "sdk": attr.label(
            doc = "The `dart_toolchain` target whose `DartSdkInfo` the probe runs.",
            mandatory = True,
            providers = [platform_common.ToolchainInfo],
        ),
    },
    doc = "Runs one action with the SDK runner `sdk_dartvm` selects, declared as an input, mirroring the kernel and JIT actions.",
)

# --- Shared assertions ---

def _assert_runner_declared(env, action, want):
    """Asserts an action runs `want` directly with it declared as an input."""
    runner = action.argv[0].split("/")[-1]
    asserts.equals(env, want, runner, "the action runs %s directly, got: %s" % (want, action.argv))
    basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(env, want in basenames, "%s is a declared input: %s" % (want, basenames))

def _patch_snapshot_actions(env):
    return [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartPatchSnapshot"
    ]

# --- Subsets omit `dartvm` while the SDK root carries it ---

def _omit_patch_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = _patch_snapshot_actions(env)
    asserts.equals(env, 2, len(actions), "one patch action per snapshot")
    for action in actions:
        _assert_runner_declared(env, action, "dartvm")
    return analysistest.end(env)

def _omit_subsets_test_impl(ctx):
    env = analysistest.begin(ctx)
    sdk = analysistest.target_under_test(env)[platform_common.ToolchainInfo].dart_sdk_info

    # The compile and runtime subsets carry `dartvm`: those are the subsets a
    # launcher action declares. The analyze subset keeps its shape — no
    # launcher action declares it without the runtime subset beside it.
    for name in ("compile_files", "runtime_files"):
        basenames = [f.basename for f in getattr(sdk, name).to_list()]
        asserts.true(env, "dartvm" in basenames, "%s carries dartvm: %s" % (name, basenames))
    return analysistest.end(env)

def _omit_probe_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "LowsBRunnerProbe"
    ]
    asserts.equals(env, 1, len(actions), "one probe action")
    _assert_runner_declared(env, actions[0], "dartvm")
    return analysistest.end(env)

_omit_patch_test = analysistest.make(_omit_patch_test_impl)
_omit_subsets_test = analysistest.make(_omit_subsets_test_impl)
_omit_probe_test = analysistest.make(_omit_probe_test_impl)

# --- SDK layout with no `dartvm` ---

def _no_vm_patch_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = _patch_snapshot_actions(env)
    asserts.equals(env, 2, len(actions), "one patch action per snapshot")
    for action in actions:
        _assert_runner_declared(env, action, "dart")
    return analysistest.end(env)

def _no_vm_probe_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "LowsBRunnerProbe"
    ]
    asserts.equals(env, 1, len(actions), "one probe action")
    _assert_runner_declared(env, actions[0], "dart")
    return analysistest.end(env)

_no_vm_patch_test = analysistest.make(_no_vm_patch_test_impl)
_no_vm_probe_test = analysistest.make(_no_vm_probe_test_impl)

def lows_b_a_suite(name):
    """Declares the launcher-input tests over both toolchain shapes.

    Args:
      name: Name of the generated `test_suite`.
    """
    lows_b_runner_probe(
        name = name + "_probe_omit",
        sdk = "//dart/tests/dart_lows_b/toolchain_a:lows_b_a_toolchain",
        tags = ["manual"],
    )
    lows_b_runner_probe(
        name = name + "_probe_no_vm",
        sdk = "//dart/tests/dart_lows_b/toolchain_b:lows_b_b_toolchain",
        tags = ["manual"],
    )
    _omit_patch_test(
        name = name + "_omit_patch_test",
        target_under_test = "//dart/tests/dart_lows_b/toolchain_a:lows_b_a_toolchain",
        size = "small",
    )
    _omit_subsets_test(
        name = name + "_omit_subsets_test",
        target_under_test = "//dart/tests/dart_lows_b/toolchain_a:lows_b_a_toolchain",
        size = "small",
    )
    _omit_probe_test(
        name = name + "_omit_probe_test",
        target_under_test = ":" + name + "_probe_omit",
        size = "small",
    )
    _no_vm_patch_test(
        name = name + "_no_vm_patch_test",
        target_under_test = "//dart/tests/dart_lows_b/toolchain_b:lows_b_b_toolchain",
        size = "small",
    )
    _no_vm_probe_test(
        name = name + "_no_vm_probe_test",
        target_under_test = ":" + name + "_probe_no_vm",
        size = "small",
    )
    small_unittest_suite(
        name + "_unit",
        _sdk_dartvm_lookup_test,
        _sdk_dartvm_absent_test,
        _sdk_dartvm_subset_only_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_omit_patch_test",
            ":" + name + "_omit_subsets_test",
            ":" + name + "_omit_probe_test",
            ":" + name + "_no_vm_patch_test",
            ":" + name + "_no_vm_probe_test",
        ],
    )
