"""Unit tests for dart_binary.bzl helpers and rule kinds."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_binary", "dart_codegen", "dart_test")
load("//dart:providers.bzl", "DartCompileInfo")
load("//dart/private:dart_binary.bzl", "binary_output_basename")
load("//dart/private:dart_compile.bzl", "compile_quiet_flags")
load("//dart/private:dart_test.bzl", "dart_test_kernel")
load("//dart/private:dart_test_runner.bzl", "dart_test_runner_snapshot")

_RuleKindInfo = provider(
    doc = "Records `ctx.rule.kind` for `target_under_test`.",
    fields = {"kind": "str: The Bazel rule kind name (`ctx.rule.kind`)."},
)

def _rule_kind_aspect_impl(_target, ctx):
    return [_RuleKindInfo(kind = ctx.rule.kind)]

_rule_kind_aspect = aspect(
    implementation = _rule_kind_aspect_impl,
)

def _rule_kind_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, "rule", type(dart_binary), "dart_binary in //dart:defs.bzl is a rule")
    asserts.equals(env, "rule", type(dart_test), "dart_test in //dart:defs.bzl is a rule")
    asserts.equals(env, ctx.attr.expected_kind, target[_RuleKindInfo].kind)
    if DartCompileInfo in target:
        asserts.true(
            env,
            bool(target[DartCompileInfo].sdk_version),
            "DartCompileInfo.sdk_version must be populated",
        )
    return analysistest.end(env)

_rule_kind_test = analysistest.make(
    _rule_kind_test_impl,
    attrs = {
        "expected_kind": attr.string(mandatory = True),
    },
    extra_target_under_test_aspects = [_rule_kind_aspect],
)

def _mismatched_kernel_tool_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    ctx.actions.write(output = dill, content = "", is_executable = True)
    return [
        DefaultInfo(files = depset([dill]), executable = dill),
        DartCompileInfo(
            executable = dill,
            compile_mode = "kernel",
            sdk_version = "0.0.0-mismatched",
        ),
    ]

_mismatched_kernel_tool = rule(
    implementation = _mismatched_kernel_tool_impl,
    executable = True,
)

def _kernel_sdk_mismatch_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "was compiled to a Dart kernel (.dill) by Dart SDK 0.0.0-mismatched")
    return analysistest.end(env)

_kernel_sdk_mismatch_failure_test = analysistest.make(
    _kernel_sdk_mismatch_failure_test_impl,
    expect_failure = True,
)

def _exe_gets_dot_exe_on_windows_test_impl(ctx):
    # Regression: a dart_binary's native executable must be named `<name>.exe`
    # on Windows. Otherwise the output is a bare `app`, and a consumer's
    # runfiles lookup for `app.exe` (the conventional Windows name) misses and
    # falls through to a non-existent path — so the exe can't be located/run.
    env = unittest.begin(ctx)
    asserts.equals(env, "app.exe", binary_output_basename("app", "exe", True))
    return unittest.end(env)

def _exe_bare_off_windows_test_impl(ctx):
    # Off Windows, a native executable has no extension.
    env = unittest.begin(ctx)
    asserts.equals(env, "app", binary_output_basename("app", "exe", False))
    return unittest.end(env)

def _snapshot_modes_fixed_extensions_test_impl(ctx):
    # Snapshot modes aren't native executables; their extensions don't vary by
    # platform (no `.exe` even on Windows).
    env = unittest.begin(ctx)
    asserts.equals(env, "app.aot", binary_output_basename("app", "aot-snapshot", True))
    asserts.equals(env, "app.dill", binary_output_basename("app", "kernel", True))
    asserts.equals(env, "app.jit", binary_output_basename("app", "jit-snapshot", True))
    asserts.equals(env, "app.aot", binary_output_basename("app", "aot-snapshot", False))
    return unittest.end(env)

def _aot_modes_compile_quietly_test_impl(ctx):
    # Regression: `dart compile exe|aot-snapshot` prints `Generated: <path>` on
    # stdout, and Bazel echoes any action output, so every build that compiled
    # a dart_binary showed a sandbox path. The other modes have no flag that
    # silences them.
    env = unittest.begin(ctx)
    asserts.equals(env, ["--verbosity=error"], compile_quiet_flags("exe"))
    asserts.equals(env, ["--verbosity=error"], compile_quiet_flags("aot-snapshot"))
    asserts.equals(env, [], compile_quiet_flags("kernel"))
    asserts.equals(env, [], compile_quiet_flags("jit-snapshot"))
    return unittest.end(env)

def _kernel_launcher_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default_exe = target[DefaultInfo].files_to_run.executable
    compile_info = target[DartCompileInfo]
    asserts.false(
        env,
        default_exe.basename.endswith(".dill"),
        "DefaultInfo.executable is the native launcher, not the .dill kernel",
    )
    asserts.equals(
        env,
        "shim.dill",
        compile_info.executable.basename,
        "DartCompileInfo.executable remains the .dill kernel for worker actions",
    )
    asserts.equals(env, "kernel", compile_info.compile_mode)
    asserts.true(
        env,
        RunEnvironmentInfo in target and
        target[RunEnvironmentInfo].environment.get("RULES_DART_KERNEL_CONFIG", "").endswith("/shim.kernel_launcher.json"),
        "RunEnvironmentInfo sets RULES_DART_KERNEL_CONFIG",
    )
    return analysistest.end(env)

_kernel_launcher_binary_test = analysistest.make(_kernel_launcher_binary_test_impl)

def _script_action_packages_test_impl(ctx):
    env = analysistest.begin(ctx)
    matching = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == ctx.attr.mnemonic
    ]
    asserts.equals(env, 1, len(matching), "expected one %s action" % ctx.attr.mnemonic)
    action = matching[0]
    asserts.true(
        env,
        "HOME" in action.env or "USERPROFILE" in action.env,
        "%s action must set writable_home_env, got env=%s" % (ctx.attr.mnemonic, action.env),
    )
    pkg_indices = [i for i, a in enumerate(action.argv) if a.startswith("--packages=")]
    script_indices = [i for i, a in enumerate(action.argv) if a.endswith("/app_jit_snapshot.dart")]
    asserts.true(
        env,
        len(pkg_indices) >= 1 and len(script_indices) >= 1 and pkg_indices[0] < script_indices[0],
        "%s action must pass --packages=<file> before app_jit_snapshot.dart in argv=%s" % (ctx.attr.mnemonic, action.argv),
    )
    pkg_path = action.argv[pkg_indices[0]][len("--packages="):]
    input_paths = [f.path for f in action.inputs.to_list()]
    asserts.true(
        env,
        pkg_path in input_paths,
        "--packages file %s must be a declared input of %s" % (pkg_path, ctx.attr.mnemonic),
    )
    return analysistest.end(env)

_script_action_packages_test = analysistest.make(
    _script_action_packages_test_impl,
    attrs = {
        "mnemonic": attr.string(mandatory = True),
    },
)

_exe_windows_test = unittest.make(_exe_gets_dot_exe_on_windows_test_impl)
_exe_other_test = unittest.make(_exe_bare_off_windows_test_impl)
_snapshot_test = unittest.make(_snapshot_modes_fixed_extensions_test_impl)
_quiet_test = unittest.make(_aot_modes_compile_quietly_test_impl)

def dart_binary_test_suite(name):
    """Registers the dart_binary.bzl helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _exe_windows_test(name = "dart_binary_exe_windows_test", size = "small")
    _exe_other_test(name = "dart_binary_exe_other_test", size = "small")
    _snapshot_test(name = "dart_binary_snapshot_test", size = "small")
    _quiet_test(name = "dart_binary_quiet_test", size = "small")
    _rule_kind_test(
        name = "dart_binary_exe_rule_kind_test",
        size = "small",
        expected_kind = "dart_binary",
        target_under_test = "//dart/private/tools:noop",
    )
    _rule_kind_test(
        name = "dart_binary_modular_kernel_rule_kind_test",
        size = "small",
        expected_kind = "dart_binary",
        target_under_test = "//dart/tests/legacy_mixin_fixture:app_modular",
    )
    _rule_kind_test(
        name = "dart_binary_whole_kernel_rule_kind_test",
        size = "small",
        expected_kind = "dart_binary",
        target_under_test = "//dart/tests/legacy_mixin_fixture:app_whole",
    )
    _rule_kind_test(
        name = "dart_test_rule_kind_test",
        size = "small",
        expected_kind = "dart_test",
        target_under_test = "//dart/tests/legacy_mixin_fixture:legacy_mixin_test",
    )
    _mismatched_kernel_tool(
        name = "mismatched_kernel_tool_fixture",
        tags = ["manual"],
    )
    dart_codegen(
        name = "mismatched_kernel_codegen_fixture",
        src = "//dart/private/tools:noop.dart",
        generator_bin = ":mismatched_kernel_tool_fixture",
        output_suffixes = [".g.dart"],
        package_name = "mismatched_fixture",
        tags = ["manual"],
    )
    _kernel_sdk_mismatch_failure_test(
        name = "dart_codegen_kernel_sdk_mismatch_test",
        size = "small",
        target_under_test = ":mismatched_kernel_codegen_fixture",
    )
    _kernel_launcher_binary_test(
        name = "dart_binary_kernel_launcher_test",
        size = "small",
        target_under_test = "//dart/ext/json_serializable:shim",
    )
    dart_binary(
        name = "jit_snapshot_fixture",
        compile_mode = "jit-snapshot",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    _script_action_packages_test(
        name = "dart_jit_snapshot_packages_test",
        size = "small",
        mnemonic = "DartJitSnapshot",
        target_under_test = ":jit_snapshot_fixture",
    )
    _script_action_packages_test(
        name = "dart_kernel_wrapper_packages_test",
        size = "small",
        mnemonic = "DartKernel",
        target_under_test = "//dart/private/tools:noop",
    )
    dart_test_kernel(
        name = "test_runner_training_fixture",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test_runner_snapshot(
        name = "test_runner_snapshot_fixture",
        runner = "//dart/private/tools:analyze_runner",
        tags = ["manual"],
        training = ":test_runner_training_fixture",
    )
    _script_action_packages_test(
        name = "dart_test_runner_snapshot_packages_test",
        size = "small",
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":test_runner_snapshot_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            ":dart_binary_exe_windows_test",
            ":dart_binary_exe_other_test",
            ":dart_binary_snapshot_test",
            ":dart_binary_quiet_test",
            ":dart_binary_exe_rule_kind_test",
            ":dart_binary_modular_kernel_rule_kind_test",
            ":dart_binary_whole_kernel_rule_kind_test",
            ":dart_test_rule_kind_test",
            ":dart_codegen_kernel_sdk_mismatch_test",
            ":dart_binary_kernel_launcher_test",
            ":dart_jit_snapshot_packages_test",
            ":dart_kernel_wrapper_packages_test",
            ":dart_test_runner_snapshot_packages_test",
        ],
    )
