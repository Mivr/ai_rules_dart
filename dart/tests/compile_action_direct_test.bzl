"""Direct `rules_testing` tests for argv and guards of `dart_compile_action`.

Each test pins one line of `dart/private/dart_compile.bzl` that no other test
sees, so a mutation of that line cannot survive the Starlark suite:

* a `jit-snapshot` `dart_binary`'s `DartJitSnapshot` action takes its kernel
  through a `--copy=input.dill=<main>` element and trains the separate
  `input.dill` operand that follows `--`;
* an AOT compile (`aot-snapshot`) passes `--aot`, `--tfa` and
  `--no-embed-sources` to its `DartKernel` action. The AOT fixture, not a
  `kernel`-mode one, is the subject: `kernel` mode omits sources through a
  different branch (`embed_sources`), so only an AOT fixture reaches the AOT
  branch's own `--no-embed-sources`;
* `dart_compile_action` refuses `recorded_uses` for a mode that records no
  uses. No `dart_binary` attribute pairing reaches that guard (`record_use`
  with `kernel` writes an empty file and never passes `recorded_uses` on), so
  the failure test drives the public function from a probe rule.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_binary")
load("//dart/private:dart_compile.bzl", "dart_compile_action")
load(":truth_helpers.bzl", "WINDOWS_ATTR", "action_of", "exe_extension")

visibility(["//dart/..."])

_TOOLCHAIN = "//dart:toolchain_type"
_MAIN = "//dart/private/tools:noop.dart"

def _jit_snapshot_input_dill_test(env, target):
    """Asserts the `DartJitSnapshot` argv copies the main file in as `input.dill` and trains it."""
    if exe_extension(env):
        # On Windows jit-snapshot trains through `dart compile`, which has no `DartJitSnapshot` action.
        return
    action = action_of(env, target, "DartJitSnapshot").actual
    argv = action.argv
    copies = [a for a in argv if a.startswith("--copy=input.dill=")]
    env.expect.that_int(len(copies)).equals(1)

    # The snapshot's main is the front-end kernel of the fixture's `main`, an input of the action.
    kernel = [f.path for f in action.inputs.to_list() if f.basename == target.label.name + ".jit.dill"]
    env.expect.that_collection(kernel).has_size(1)
    env.expect.that_str(copies[0] if copies else "").equals("--copy=input.dill=" + (kernel[0] if kernel else ""))
    env.expect.that_bool("--" in argv).equals(True)
    operands = argv[argv.index("--") + 1:] if "--" in argv else []
    env.expect.that_collection(operands).contains_exactly(["input.dill"]).in_order()

def _aot_kernel_flags_test(env, target):
    """Asserts the AOT fixture's `DartKernel` action passes the AOT flags and omits sources.

    The fixture compiles in `aot-snapshot` mode, so it is the one under test: the
    `--no-embed-sources` below can only come from the AOT branch of the front end.
    """
    action = action_of(env, target, "DartKernel")
    action.argv().contains_at_least(["--aot", "--tfa", "--no-embed-sources"])

def _recorded_uses_probe_impl(ctx):
    """Calls `dart_compile_action` with a declared `recorded_uses` File and the attribute's mode."""
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(output = package_config, content = '{"configVersion": 2, "packages": []}\n')
    dart_compile_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        cfg = struct(
            main = ctx.file.main,
            srcs = [ctx.file.main],
            package_config = package_config,
            output = ctx.actions.declare_file(ctx.label.name + ".out"),
            compile_mode = ctx.attr.compile_mode,
            target_os = "",
            target_arch = "",
            extra_flags = [],
            defines = [],
            main_path = None,
            recorded_uses = ctx.actions.declare_file(ctx.label.name + ".uses.json"),
            jit_tool = [],
            comma_patch = None,
            native_assets_yaml = None,
            embed_sources = True,
            jit_snapshot_fallback = False,
        ),
    )
    return [DefaultInfo()]

_recorded_uses_probe = rule(
    implementation = _recorded_uses_probe_impl,
    attrs = {
        "main": attr.label(
            doc = "The entrypoint `.dart` File.",
            allow_single_file = [".dart"],
            mandatory = True,
        ),
        "compile_mode": attr.string(
            doc = "The `compile_mode` passed to `dart_compile_action`.",
            mandatory = True,
        ),
    },
    toolchains = [_TOOLCHAIN],
)

def _recorded_uses_guard_test(env, target):
    """Asserts a non-recording mode with `recorded_uses` fails analysis with `records no uses`."""
    env.expect.that_target(target).failures().contains_predicate(
        matching.str_matches("*`dart compile kernel` records no uses*"),
    )

def compile_action_direct_test_suite(name):
    """Declares the `dart_compile_action` argv and guard tests and their `test_suite`.

    Args:
      name: Name of the generated `test_suite`; fixture and test names derive from it.
    """
    dart_binary(
        name = name + "_jit_fixture",
        compile_mode = "jit-snapshot",
        main = _MAIN,
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_aot_fixture",
        compile_mode = "aot-snapshot",
        main = _MAIN,
        tags = ["manual"],
    )
    _recorded_uses_probe(
        name = name + "_kernel_uses_fixture",
        compile_mode = "kernel",
        main = _MAIN,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_jit_input_dill_test",
        attr_values = {"size": "small"},
        attrs = WINDOWS_ATTR,
        impl = _jit_snapshot_input_dill_test,
        target = ":" + name + "_jit_fixture",
    )
    analysis_test(
        name = name + "_aot_kernel_flags_test",
        attr_values = {"size": "small"},
        impl = _aot_kernel_flags_test,
        target = ":" + name + "_aot_fixture",
    )
    analysis_test(
        name = name + "_recorded_uses_guard_test",
        attr_values = {"size": "small"},
        expect_failure = True,
        impl = _recorded_uses_guard_test,
        target = ":" + name + "_kernel_uses_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_jit_input_dill_test",
            ":" + name + "_aot_kernel_flags_test",
            ":" + name + "_recorded_uses_guard_test",
        ],
    )
