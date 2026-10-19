"""Unit tests for dart_codegen.bzl output filename computation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen", "dart_sqlcodegen")
load("//dart/private:dart_codegen.bzl", "compute_codegen_output_name")
load(":small_suite.bzl", "small_unittest_suite")

def _g_dart_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("user.dart", ".g.dart")
    asserts.equals(env, "user.g.dart", result)
    return unittest.end(env)

def _freezed_suffix_with_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("some/dir/model.dart", ".freezed.dart")
    asserts.equals(env, "some/dir/model.freezed.dart", result)
    return unittest.end(env)

def _custom_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("router.dart", ".gr.dart")
    asserts.equals(env, "router.gr.dart", result)
    return unittest.end(env)

def _action_hermeticity_test_impl(ctx):
    env = analysistest.begin(ctx)
    matching = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == ctx.attr.mnemonic
    ]
    asserts.equals(env, 1, len(matching), "expected exactly one %s action" % ctx.attr.mnemonic)
    action = matching[0]
    asserts.true(
        env,
        "HOME" in action.env or "USERPROFILE" in action.env,
        "%s action must set writable_home_env, got env=%s" % (ctx.attr.mnemonic, action.env),
    )
    if ctx.attr.expect_packages_before_script:
        pkg_indices = [i for i, a in enumerate(action.argv) if a.startswith("--packages=")]
        script_indices = [i for i, a in enumerate(action.argv) if a.endswith("/noop.dart")]
        asserts.true(
            env,
            len(pkg_indices) >= 1 and len(script_indices) >= 1 and pkg_indices[0] < script_indices[0],
            "%s action must pass --packages=<file> before script in argv=%s" % (ctx.attr.mnemonic, action.argv),
        )
        pkg_path = action.argv[pkg_indices[0]][len("--packages="):]
        input_paths = [f.path for f in action.inputs.to_list()]
        asserts.true(
            env,
            pkg_path in input_paths,
            "--packages file %s must be a declared input of %s" % (pkg_path, ctx.attr.mnemonic),
        )
    return analysistest.end(env)

_action_hermeticity_test = analysistest.make(
    _action_hermeticity_test_impl,
    attrs = {
        "mnemonic": attr.string(mandatory = True),
        "expect_packages_before_script": attr.bool(default = False),
    },
)

def _dummy_dart_source_impl(ctx):
    out = ctx.actions.declare_file("lib/" + ctx.label.name + ".dart")
    ctx.actions.write(output = out, content = "// dummy\n")
    return [DefaultInfo(files = depset([out]))]

_dummy_dart_source = rule(
    implementation = _dummy_dart_source_impl,
)

_t0_test = unittest.make(_g_dart_suffix_test_impl)
_t1_test = unittest.make(_freezed_suffix_with_dir_test_impl)
_t2_test = unittest.make(_custom_suffix_test_impl)

def codegen_test_suite(name):
    """Declares the codegen unit and analysis tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(name + "_unit", _t0_test, _t1_test, _t2_test)

    _dummy_dart_source(
        name = name + "_dummy_src",
        tags = ["manual"],
    )

    dart_codegen(
        name = name + "_script_fixture",
        src = ":" + name + "_dummy_src",
        generator = "//dart/private/tools:noop.dart",
        output_suffixes = [".g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_hermeticity_test(
        name = name + "_script_hermeticity_test",
        size = "small",
        expect_packages_before_script = True,
        mnemonic = "DartCodegen",
        target_under_test = ":" + name + "_script_fixture",
    )

    dart_codegen(
        name = name + "_bin_fixture",
        src = ":" + name + "_dummy_src",
        generator_bin = "//dart/private/tools:noop",
        output_suffixes = [".bin.g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_hermeticity_test(
        name = name + "_bin_hermeticity_test",
        size = "small",
        mnemonic = "DartCodegen",
        target_under_test = ":" + name + "_bin_fixture",
    )

    dart_aggregate_codegen(
        name = name + "_agg_script_fixture",
        srcs = [":" + name + "_dummy_src"],
        generator_script = "//dart/private/tools:noop.dart",
        outputs = ["lib/" + name + "_agg_script.g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_hermeticity_test(
        name = name + "_agg_script_hermeticity_test",
        size = "small",
        expect_packages_before_script = True,
        mnemonic = "DartAggregateCodegen",
        target_under_test = ":" + name + "_agg_script_fixture",
    )

    dart_aggregate_codegen(
        name = name + "_agg_bin_fixture",
        srcs = [":" + name + "_dummy_src"],
        generator_bin = "//dart/private/tools:noop",
        outputs = ["lib/" + name + "_agg_bin.g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_hermeticity_test(
        name = name + "_agg_bin_hermeticity_test",
        size = "small",
        mnemonic = "DartAggregateCodegen",
        target_under_test = ":" + name + "_agg_bin_fixture",
    )

    dart_sqlcodegen(
        name = name + "_sql_fixture",
        src = ":" + name + "_dummy_src",
        generator_bin = "//dart/private/tools:noop",
        output_suffixes = [".drift.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_hermeticity_test(
        name = name + "_sql_hermeticity_test",
        size = "small",
        mnemonic = "DartSqlCodegen",
        target_under_test = ":" + name + "_sql_fixture",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_script_hermeticity_test",
            ":" + name + "_bin_hermeticity_test",
            ":" + name + "_agg_script_hermeticity_test",
            ":" + name + "_agg_bin_hermeticity_test",
            ":" + name + "_sql_hermeticity_test",
        ],
    )
