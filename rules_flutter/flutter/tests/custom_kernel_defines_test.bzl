"""Analysis tests for defines on a custom modular kernel.

A custom modular kernel — a rule built on `FLUTTER_MODULAR_KERNEL_ATTRS`,
used through the public `//flutter:utils.bzl` — compiles with defines like the
built-in rules do: its own `defines` are the configuration of its `deps` edge,
so every dependency module and its entry compile with them, followed by the
global `//flutter:extra_dart_defines`. A value may hold a comma: the module
compiler takes the defines as a map.

The caller rules below load only the public `//flutter:utils.bzl`, the way a
downstream pipeline would. The tests pin:

- a test kernel and an app kernel analysed with the global flag stay on the
  modular `DartKernel` + `DartKernelLink` actions, with no whole-program
  `FlutterKernelCompile`, and the entry compile carries the global define;
- a kernel's own `defines` reach its entry compile before the global ones, so
  the global flag wins on a key both set, as in the whole-program compile;
- a comma in a global value changes nothing: the kernel stays modular;
- with the flag empty and no `defines` the entry compile carries no `-D` and
  the default complete link stages no base dill.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "//flutter:utils.bzl",
    "FLUTTER_MODULAR_KERNEL_ATTRS",
    "FLUTTER_MODULAR_KERNEL_TOOLCHAINS",
    "FLUTTER_TEST_BOOTSTRAP_ATTRS",
    "flutter_modular_app_kernel",
    "flutter_modular_test_kernel",
)

visibility(["//flutter/tests/..."])

_GLOBAL_TEST_URI = "package:modular_api_b/b.dart"

def _refusal_test_kernel_impl(ctx):
    """A downstream-style modular test kernel for the refusal tests."""
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    base = flutter_modular_test_kernel(
        ctx,
        test_uri = _GLOBAL_TEST_URI,
        deps = ctx.attr.deps,
        output = dill,
    )
    return [
        DefaultInfo(files = depset([dill])),
        OutputGroupInfo(
            test_kernel = depset([dill]),
            test_base_kernel = depset([base]) if base else depset(),
        ),
    ]

_refusal_test_kernel = rule(
    implementation = _refusal_test_kernel_impl,
    attrs = {} | FLUTTER_MODULAR_KERNEL_ATTRS | FLUTTER_TEST_BOOTSTRAP_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)

def _refusal_app_kernel_impl(ctx):
    """A downstream-style modular app kernel for the refusal tests."""
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_modular_app_kernel(
        ctx,
        main = ctx.file.main,
        package_name = "modular_api_app",
        srcs = ctx.files.srcs,
        deps = ctx.attr.deps,
        output = dill,
    )
    return [DefaultInfo(files = depset([dill]))]

_refusal_app_kernel = rule(
    implementation = _refusal_app_kernel_impl,
    attrs = {
        "main": attr.label(mandatory = True, allow_single_file = [".dart"]),
        "srcs": attr.label_list(allow_files = [".dart"]),
    } | FLUTTER_MODULAR_KERNEL_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)

def _entry_defines(env):
    """The `-D` arguments of the one modular entry compile, after checking the kernel stayed modular."""
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.true(env, "DartKernelLink" in mnemonics, "the kernel must link modularly, got %s" % (mnemonics,))
    asserts.equals(
        env,
        [],
        [m for m in mnemonics if m == "FlutterKernelCompile"],
        "a custom kernel must not run a whole-program compile",
    )
    entries = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(entries), "expected one modular entry compile")
    return [x for x in entries[0].argv if x.startswith("-D")] if entries else []

def _global_stays_modular_test_impl(ctx):
    """Under the global flag the kernel stays modular and its entry takes the global define."""
    env = analysistest.begin(ctx)
    asserts.equals(env, ["-DCUSTOM_KERNEL_GLOBAL=1"], _entry_defines(env))
    return analysistest.end(env)

def _own_defines_test_impl(ctx):
    """The kernel's own defines come first, then the global flag's, which wins on a shared key."""
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        ["-DCUSTOM_KERNEL_GLOBAL=own", "-DCUSTOM_KERNEL_OWN=1", "-DCUSTOM_KERNEL_GLOBAL=1"],
        _entry_defines(env),
    )
    return analysistest.end(env)

def _comma_stays_modular_test_impl(ctx):
    """A comma in a global value changes nothing: the kernel stays modular and the entry carries the value whole."""
    env = analysistest.begin(ctx)
    asserts.true(
        env,
        "-DCUSTOM_KERNEL_COMMA=a,b" in _entry_defines(env),
        "the entry compile must carry the comma define whole, got %s" % _entry_defines(env),
    )
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "a comma define must not select the whole-program compile")
    return analysistest.end(env)

def _empty_unchanged_test_impl(ctx):
    """With the flag empty and no `defines` the entry carries no `-D` and the link stages no base."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _entry_defines(env), "the entry compile must carry no defines")
    links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    if links:
        link_inputs = [f.path for f in links[0].inputs.to_list()]
        asserts.equals(
            env,
            [],
            [p for p in link_inputs if ".flutter_base." in p],
            "the default complete link must stage no base dill or keys",
        )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_WITH_GLOBAL_DEFINES = _DBG | {
    str(Label("//flutter:extra_dart_defines")): ["CUSTOM_KERNEL_GLOBAL=1"],
}
_WITH_COMMA = _DBG | {
    str(Label("//flutter:extra_dart_defines")): ["CUSTOM_KERNEL_GLOBAL=1", "CUSTOM_KERNEL_COMMA=a,b"],
}

_global_stays_modular_test = analysistest.make(_global_stays_modular_test_impl, config_settings = _WITH_GLOBAL_DEFINES)
_own_defines_test = analysistest.make(_own_defines_test_impl, config_settings = _WITH_GLOBAL_DEFINES)
_comma_stays_modular_test = analysistest.make(
    _comma_stays_modular_test_impl,
    config_settings = _WITH_COMMA,
)
_empty_unchanged_test = analysistest.make(_empty_unchanged_test_impl, config_settings = _DBG)

def _code_assets_refused_test_impl(ctx):
    """A custom kernel over a package with a build hook fails, naming the mapping it cannot take."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "takes no native-assets mapping, and its closure has code assets")
    return analysistest.end(env)

_code_assets_refused_test = analysistest.make(_code_assets_refused_test_impl, expect_failure = True, config_settings = _DBG)

def custom_kernel_defines_test_suite(name):
    """Fixtures and tests for defines on a custom modular kernel.

    Args:
        name: The test suite name.
    """
    _refusal_test_kernel(
        name = "_custom_kernel_defines_test",
        tags = ["manual"],
        deps = ["//flutter/tests/modular_api_fixture:dep_b"],
    )
    _refusal_app_kernel(
        name = "_custom_kernel_defines_app",
        main = "modular_api_app_main.dart",
        srcs = ["modular_api_app_main.dart"],
        tags = ["manual"],
        deps = ["//flutter/tests/modular_api_fixture:dep_a"],
    )
    _refusal_test_kernel(
        name = "_custom_kernel_defines_test_own",
        defines = ["CUSTOM_KERNEL_OWN=1", "CUSTOM_KERNEL_GLOBAL=own"],
        tags = ["manual"],
        deps = ["//flutter/tests/modular_api_fixture:dep_b"],
    )

    _refusal_test_kernel(
        name = "_custom_kernel_code_assets_test",
        tags = ["manual"],
        deps = ["//flutter/tests/dart_asset_fixture/hook_library"],
    )
    _code_assets_refused_test(
        name = name + "_code_assets_refused",
        target_under_test = ":_custom_kernel_code_assets_test",
    )

    _global_stays_modular_test(
        name = name + "_test_global_stays_modular",
        target_under_test = ":_custom_kernel_defines_test",
    )
    _global_stays_modular_test(
        name = name + "_app_global_stays_modular",
        target_under_test = ":_custom_kernel_defines_app",
    )
    _own_defines_test(
        name = name + "_own_defines",
        target_under_test = ":_custom_kernel_defines_test_own",
    )
    _comma_stays_modular_test(
        name = name + "_test_comma_stays_modular",
        target_under_test = ":_custom_kernel_defines_test",
    )
    _comma_stays_modular_test(
        name = name + "_app_comma_stays_modular",
        target_under_test = ":_custom_kernel_defines_app",
    )
    _empty_unchanged_test(
        name = name + "_empty_unchanged",
        target_under_test = ":_custom_kernel_defines_test",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_test_global_stays_modular",
            ":" + name + "_app_global_stays_modular",
            ":" + name + "_own_defines",
            ":" + name + "_test_comma_stays_modular",
            ":" + name + "_app_comma_stays_modular",
            ":" + name + "_empty_unchanged",
            ":" + name + "_code_assets_refused",
        ],
    )
