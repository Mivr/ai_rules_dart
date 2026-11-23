"""Analysis tests for the custom modular kernel's global-defines refusal (COV-66).

A custom modular kernel — a rule built on `FLUTTER_MODULAR_KERNEL_ATTRS`,
used through the public `//flutter:utils.bzl` — reads the global
`//flutter:extra_dart_defines` and fails at analysis when it is non-empty:
the `deps` edge resets the flag for the dependency modules, so letting the
entry keep it would silently split the closure and the defines would never
reach the kernel. A pipeline that knowingly builds without the global defines
sets `ignore_global_dart_defines` instead, and an empty flag changes nothing
either way.

The caller rules below load only the public `//flutter:utils.bzl`, the way a
downstream pipeline would. The tests pin:

- analysing a test kernel or an app kernel with a flag-bearing global fails,
  naming the target, the flag value, the opt-out attribute and the
  whole-program `flutter_kernel_compile_action` path;
- the same kernels with `ignore_global_dart_defines = True` analyse fine
  under the same flag, staying on the modular `DartKernel` + `DartKernelLink`
  actions with no whole-program `FlutterKernelCompile`;
- with the flag empty the opt-out changes nothing: the entry compile carries
  no `-D` flag and the default complete link stages no base dill.
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

def _reject_global_defines_test_impl(ctx):
    """The kernel refuses the flag-bearing global, naming the way out."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

def _optout_stays_modular_test_impl(ctx):
    """With the opt-out the kernel analyses under the flag and stays modular.

    The `deps` transition strips the flag for the dependency modules and the
    entry compile takes none of it, so the kernel still compiles as one
    `DartKernel` entry module plus a `DartKernelLink` — never the
    whole-program `FlutterKernelCompile` the built-in rules fall back to.
    """
    env = analysistest.begin(ctx)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.true(
        env,
        "DartKernel" in mnemonics,
        "the opted-out kernel must still compile a modular entry, got %s" % (mnemonics,),
    )
    asserts.true(
        env,
        "DartKernelLink" in mnemonics,
        "the opted-out kernel must still link modularly, got %s" % (mnemonics,),
    )
    asserts.equals(
        env,
        [],
        [m for m in mnemonics if m == "FlutterKernelCompile"],
        "the opted-out kernel must not run a whole-program compile",
    )
    return analysistest.end(env)

def _empty_optout_unchanged_test_impl(ctx):
    """With the flag empty the opt-out changes nothing.

    The entry compile carries no `-D` flag either way (the global is empty and
    the entry never invents defines), and the default complete link stages no
    base dill or keys — the same actions and outputs as without the opt-out.
    """
    env = analysistest.begin(ctx)
    entries = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(entries), "expected one modular entry compile")
    if entries:
        asserts.equals(
            env,
            [],
            [x for x in entries[0].argv if x.startswith("-D")],
            "the entry compile must carry no defines when the flag is empty",
        )
    links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(links), "expected one modular link")
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
    str(Label("//flutter:extra_dart_defines")): ["CUSTOM_KERNEL_GLOBAL=1", "CUSTOM_KERNEL_COMMA=a,b"],
}

_reject_global_defines_test = analysistest.make(
    _reject_global_defines_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
    config_settings = _WITH_GLOBAL_DEFINES,
)
_optout_stays_modular_test = analysistest.make(
    _optout_stays_modular_test_impl,
    config_settings = _WITH_GLOBAL_DEFINES,
)
_empty_optout_unchanged_test = analysistest.make(
    _empty_optout_unchanged_test_impl,
    config_settings = _DBG,
)

def custom_kernel_defines_test_suite(name):
    """Fixtures and tests for the global-defines refusal.

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
        name = "_custom_kernel_defines_test_optout",
        tags = ["manual"],
        ignore_global_dart_defines = True,
        deps = ["//flutter/tests/modular_api_fixture:dep_b"],
    )
    _refusal_app_kernel(
        name = "_custom_kernel_defines_app_optout",
        main = "modular_api_app_main.dart",
        srcs = ["modular_api_app_main.dart"],
        tags = ["manual"],
        ignore_global_dart_defines = True,
        deps = ["//flutter/tests/modular_api_fixture:dep_a"],
    )

    # Analysis negatives: a flag-bearing global has no whole-program fallback
    # to route to, so the build fails naming the target, the flag value, the
    # opt-out and the whole-program path — over both kernel variants.
    _reject_global_defines_test(
        name = name + "_test_rejects_global_defines",
        target_under_test = ":_custom_kernel_defines_test",
        expected_substrings = [
            "_custom_kernel_defines_test",
            "extra_dart_defines",
            "CUSTOM_KERNEL_GLOBAL=1",
            "ignore_global_dart_defines",
            "flutter_kernel_compile_action",
        ],
    )
    _reject_global_defines_test(
        name = name + "_app_rejects_global_defines",
        target_under_test = ":_custom_kernel_defines_app",
        expected_substrings = [
            "_custom_kernel_defines_app",
            "extra_dart_defines",
            "CUSTOM_KERNEL_GLOBAL=1",
            "ignore_global_dart_defines",
            "flutter_kernel_compile_action",
        ],
    )
    _optout_stays_modular_test(
        name = name + "_test_optout_stays_modular",
        target_under_test = ":_custom_kernel_defines_test_optout",
    )
    _optout_stays_modular_test(
        name = name + "_app_optout_stays_modular",
        target_under_test = ":_custom_kernel_defines_app_optout",
    )
    _empty_optout_unchanged_test(
        name = name + "_empty_optout_unchanged",
        target_under_test = ":_custom_kernel_defines_test_optout",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_test_rejects_global_defines",
            ":" + name + "_app_rejects_global_defines",
            ":" + name + "_test_optout_stays_modular",
            ":" + name + "_app_optout_stays_modular",
            ":" + name + "_empty_optout_unchanged",
        ],
    )
