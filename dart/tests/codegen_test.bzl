"""Unit tests for dart_codegen.bzl output filename computation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "DartCodeAssetInfo", "dart_aggregate_codegen", "dart_binary", "dart_codegen", "dart_library", "dart_sqlcodegen")
load("//dart:utils.bzl", "dart_package_identity")
load("//dart/private:dart_codegen.bzl", "compute_codegen_output_name")
load("//dart/private:dart_info.bzl", "dart_info")
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

def _action_inputs_and_tools_test_impl(ctx):
    env = analysistest.begin(ctx)
    matching = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == ctx.attr.mnemonic
    ]
    asserts.equals(env, 1, len(matching), "expected exactly one %s action" % ctx.attr.mnemonic)
    action = matching[0]
    input_paths = [f.path for f in action.inputs.to_list()]
    for suffix in ctx.attr.expected_input_suffixes:
        asserts.true(
            env,
            any([p.endswith(suffix) for p in input_paths]),
            "expected an input ending with %s in %s inputs: %s" % (suffix, ctx.attr.mnemonic, input_paths),
        )
    for arg_sub in ctx.attr.expected_argv_substrings:
        asserts.true(
            env,
            any([arg_sub in a for a in action.argv]),
            "expected an argv element containing %s in %s argv: %s" % (arg_sub, ctx.attr.mnemonic, action.argv),
        )
    return analysistest.end(env)

_action_inputs_and_tools_test = analysistest.make(
    _action_inputs_and_tools_test_impl,
    attrs = {
        "mnemonic": attr.string(mandatory = True),
        "expected_input_suffixes": attr.string_list(default = []),
        "expected_argv_substrings": attr.string_list(default = []),
    },
)

def _dummy_file_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out_path)
    ctx.actions.write(output = out, content = ctx.attr.content)
    return [DefaultInfo(files = depset([out]))]

_dummy_file = rule(
    implementation = _dummy_file_impl,
    attrs = {
        "out_path": attr.string(mandatory = True),
        "content": attr.string(default = "// dummy\n"),
    },
)

def _dummy_code_asset_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out_path)
    ctx.actions.write(output = out, content = "fake-so\n")
    return [
        DefaultInfo(files = depset([out])),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = "dynamic_loading_bundle",
            dynamic_library = out,
            system_uri = "",
        ),
    ]

_dummy_code_asset = rule(
    implementation = _dummy_code_asset_impl,
    attrs = {
        "out_path": attr.string(mandatory = True),
        "asset_id": attr.string(mandatory = True),
    },
)

def _dummy_res_only_lib_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.sub_root + "/" + ctx.attr.res_rel)
    ctx.actions.write(output = out, content = "key: val\n")
    lib_root = ctx.label.package + "/" + ctx.attr.sub_root
    return [
        DefaultInfo(files = depset([out])),
        dart_info(
            label = ctx.label,
            package = dart_package_identity(
                package_name = ctx.attr.package_name,
                lib_root = lib_root,
                language_version = "3.0",
            ),
            deps = [],
            srcs = [],
            resources = [out],
        ),
    ]

_dummy_res_only_lib = rule(
    implementation = _dummy_res_only_lib_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "sub_root": attr.string(mandatory = True),
        "res_rel": attr.string(mandatory = True),
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

    # Fixtures for generator_bin with launcher = True, data, resources, and code_assets,
    # and for codegen deps with cross-package and same-package resources.
    _dummy_file(
        name = name + "_gen_data_file",
        out_path = "data/gen_template.txt",
        content = "template-v1\n",
        tags = ["manual"],
    )
    _dummy_file(
        name = name + "_gen_res_file",
        out_path = "lib/gen_res.json",
        content = "{}\n",
        tags = ["manual"],
    )
    _dummy_code_asset(
        name = name + "_gen_native_lib",
        out_path = "native/libgen_helper.so",
        asset_id = "package:gen_helper_pkg/ffi.dart",
        tags = ["manual"],
    )
    dart_library(
        name = name + "_gen_helper_lib",
        srcs = [],
        package_name = "gen_helper_pkg",
        resources = [":" + name + "_gen_res_file"],
        code_assets = [":" + name + "_gen_native_lib"],
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_kernel_launcher_gen",
        main = "//dart/private/tools:noop.dart",
        srcs = ["//dart/private/tools:noop.dart"],
        compile_mode = "kernel",
        launcher = True,
        data = [":" + name + "_gen_data_file"],
        deps = [":" + name + "_gen_helper_lib"],
        tags = ["manual"],
    )

    _dummy_res_only_lib(
        name = name + "_res_only_dep_lib",
        package_name = "res_only_dep_pkg",
        sub_root = "res_only_subpkg",
        res_rel = "lib/schema/dep_res.yaml",
        tags = ["manual"],
    )
    _dummy_file(
        name = name + "_same_pkg_res_file",
        out_path = "lib/local_config.json",
        content = "{}\n",
        tags = ["manual"],
    )
    dart_library(
        name = name + "_same_pkg_dep_lib",
        srcs = [],
        package_name = "codegen_fixture",
        resources = [":" + name + "_same_pkg_res_file"],
        tags = ["manual"],
    )

    expected_runfile_suffixes = [
        "data/gen_template.txt",
        "lib/gen_res.json",
        "native/libgen_helper.so",
    ]
    expected_dep_res_input_suffixes = expected_runfile_suffixes + [
        "res_only_subpkg/lib/schema/dep_res.yaml",
        ".pkg_roots/res__only__dep__pkg/lib/schema/dep_res.yaml",
        "lib/local_config.json",
        ".pkg_roots/codegen__fixture/lib/local_config.json",
    ]

    dart_codegen(
        name = name + "_launcher_and_res_codegen_fixture",
        src = ":" + name + "_dummy_src",
        generator_bin = ":" + name + "_kernel_launcher_gen",
        deps = [
            ":" + name + "_res_only_dep_lib",
            ":" + name + "_same_pkg_dep_lib",
        ],
        output_suffixes = [".lnch.g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_inputs_and_tools_test(
        name = name + "_launcher_and_res_codegen_test",
        size = "small",
        mnemonic = "DartCodegen",
        expected_input_suffixes = expected_dep_res_input_suffixes,
        expected_argv_substrings = ["|lib/local_config.json"],
        target_under_test = ":" + name + "_launcher_and_res_codegen_fixture",
    )

    dart_aggregate_codegen(
        name = name + "_launcher_and_res_agg_fixture",
        srcs = [":" + name + "_dummy_src"],
        generator_bin = ":" + name + "_kernel_launcher_gen",
        deps = [
            ":" + name + "_res_only_dep_lib",
            ":" + name + "_same_pkg_dep_lib",
        ],
        outputs = ["lib/" + name + "_lnch_agg.g.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_inputs_and_tools_test(
        name = name + "_launcher_and_res_agg_test",
        size = "small",
        mnemonic = "DartAggregateCodegen",
        expected_input_suffixes = expected_dep_res_input_suffixes,
        expected_argv_substrings = ["|lib/local_config.json"],
        target_under_test = ":" + name + "_launcher_and_res_agg_fixture",
    )

    dart_sqlcodegen(
        name = name + "_launcher_and_res_sql_fixture",
        src = ":" + name + "_dummy_src",
        generator_bin = ":" + name + "_kernel_launcher_gen",
        deps = [
            ":" + name + "_res_only_dep_lib",
            ":" + name + "_same_pkg_dep_lib",
        ],
        output_suffixes = [".lnch.drift.dart"],
        package_name = "codegen_fixture",
        tags = ["manual"],
    )
    _action_inputs_and_tools_test(
        name = name + "_launcher_and_res_sql_test",
        size = "small",
        mnemonic = "DartSqlCodegen",
        expected_input_suffixes = expected_dep_res_input_suffixes,
        expected_argv_substrings = ["|lib/local_config.json"],
        target_under_test = ":" + name + "_launcher_and_res_sql_fixture",
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
            ":" + name + "_launcher_and_res_codegen_test",
            ":" + name + "_launcher_and_res_agg_test",
            ":" + name + "_launcher_and_res_sql_test",
        ],
    )
