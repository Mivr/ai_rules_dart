"""Tests for the public/private header split and private search paths of plugin ObjC targets.

On the `rules_apple` backend `flutter_apple_plugin_library` keeps `.h` files
outside `includes` out of the public headers and the Clang module, and gives the
ObjC compile their directories as search paths through `implementation_deps`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:ios.bzl", "flutter_apple_plugin_library")

visibility(["//flutter/tests/..."])

def _surface_test_impl(ctx):
    """The inner ObjC target lists public headers in `hdrs` and private ones in `srcs`."""
    env = unittest.begin(ctx)
    asserts.equals(env, ctx.attr.expected_hdrs, ctx.attr.hdrs, "hdrs")
    asserts.equals(env, ctx.attr.expected_srcs, ctx.attr.srcs, "srcs")
    asserts.equals(env, ctx.attr.expected_includes, ctx.attr.includes, "includes")
    asserts.equals(env, ctx.attr.expected_impl_deps, ctx.attr.impl_deps, "implementation_deps")
    asserts.equals(env, [], ctx.attr.deps_leaks, "private header targets must not be in deps")
    return unittest.end(env)

_surface_test = unittest.make(
    _surface_test_impl,
    attrs = {
        "deps_leaks": attr.string_list(),
        "expected_hdrs": attr.string_list(),
        "expected_impl_deps": attr.string_list(),
        "expected_includes": attr.string_list(),
        "expected_srcs": attr.string_list(),
        "hdrs": attr.string_list(),
        "impl_deps": attr.string_list(),
        "includes": attr.string_list(),
        "srcs": attr.string_list(),
    },
)

def _leak_free_public_target_test_impl(ctx):
    """The public plugin target exposes only public headers and no private search path."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    cc = tut[CcInfo].compilation_context
    headers = [h.path for h in cc.direct_public_headers]
    for needle in ctx.attr.forbidden_header_substrings:
        asserts.false(env, [h for h in headers if needle in h], "%s leaked into headers: %s" % (needle, headers))
    for needle in ctx.attr.required_header_substrings:
        asserts.true(env, [h for h in headers if needle in h], "%s missing from headers: %s" % (needle, headers))
    dirs = cc.includes.to_list() + cc.system_includes.to_list() + cc.quote_includes.to_list()
    for needle in ctx.attr.forbidden_dir_substrings:
        asserts.false(env, [d for d in dirs if needle in d], "%s leaked into search paths: %s" % (needle, dirs))
    return analysistest.end(env)

def _config_settings():
    """Config settings that analyze an iOS target off macOS."""
    return {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    }

_leak_free_public_target_test = analysistest.make(
    _leak_free_public_target_test_impl,
    attrs = {
        "forbidden_dir_substrings": attr.string_list(),
        "forbidden_header_substrings": attr.string_list(),
        "required_header_substrings": attr.string_list(),
    },
    config_settings = _config_settings(),
)

def _objc_compile_flags_test_impl(ctx):
    """The ObjC compile carries search-path flags for each private header directory."""
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "ObjcCompile"]
    asserts.true(env, actions, "expected an ObjcCompile action")
    if actions:
        argv = actions[0].argv
        for suffix in ctx.attr.dir_suffixes:
            found = False
            for i in range(len(argv)):
                if argv[i] in ("-iquote", "-isystem") and i + 1 < len(argv) and argv[i + 1].endswith(suffix):
                    found = True
            asserts.true(env, found, "no -iquote/-isystem for %s in %s" % (suffix, argv))
    return analysistest.end(env)

_objc_compile_flags_test = analysistest.make(
    _objc_compile_flags_test_impl,
    attrs = {"dir_suffixes": attr.string_list()},
    config_settings = _config_settings(),
)

def _files(src, names):
    """Declare empty source files at the given package-relative paths under `src`."""
    for n in names:
        write_file(
            name = "%s_%s" % (src, n.replace("/", "_")),
            out = "%s/%s" % (src, n),
            content = [""],
            tags = ["manual"],
        )
    return ["%s/%s" % (src, n) for n in names]

def _plain(labels):
    """Labels as written in the plugin's srcs, without a leading colon."""
    return [str(x).lstrip(":") if str(x).startswith(":apple") else str(x) for x in labels]

def _surface(name, plugin, **expected):
    """Declare a surface test over the plugin's inner ObjC target."""
    rule = native.existing_rules()["_%s__objc" % plugin]
    _surface_test(
        name = name,
        hdrs = _plain(rule["hdrs"]),
        srcs = _plain(rule["srcs"]),
        includes = rule["includes"],
        impl_deps = rule.get("implementation_deps", []),
        deps_leaks = [d for d in rule["deps"] if "__private_header_dirs" in d],
        size = "small",
        **expected
    )

def apple_private_headers_test_suite(name):
    """Declares the plugin fixtures and the header-split tests over them.

    Args:
        name: Prefix for every target declared here.
    """
    tests = []

    # permission_handler_apple-shaped pure ObjC plugin.
    src = name + "_pha"
    pha = _files(src, [
        "Plugin.m",
        "Plugin.h",
        "Manager.h",
        "include/pkg/Plugin.h",
        "strategies/Strategy.h",
        "strategies/Strategy.m",
        "util/Codec.h",
        "util/Codec.m",
    ])
    flutter_apple_plugin_library(
        name = name + "_pha_plugin",
        srcs = pha,
        module_name = name + "_pha_mod",
        platform = "ios",
        includes = [src + "/include", src + "/include/pkg"],
        tags = ["manual"],
    )
    ms = [p for p in pha if p.endswith(".m")]
    _surface(
        name + "_pha_surface",
        name + "_pha_plugin",
        expected_hdrs = [src + "/include/pkg/Plugin.h"],
        expected_srcs = ms + [p for p in pha if p.endswith(".h") and "/include/" not in p],
        expected_includes = [src + "/include", src + "/include/pkg"],
        expected_impl_deps = [":_%s_pha_plugin__private_header_dirs" % name],
    )
    _leak_free_public_target_test(
        name = name + "_pha_objc_cc",
        target_under_test = ":_%s_pha_plugin__objc" % name,
        required_header_substrings = ["include/pkg/Plugin.h"],
        forbidden_header_substrings = ["strategies/", "util/", "Manager.h", "pha/Plugin.h"],
        forbidden_dir_substrings = ["strategies", "util"],
        size = "small",
    )
    _leak_free_public_target_test(
        name = name + "_pha_public_cc",
        target_under_test = ":" + name + "_pha_plugin",
        forbidden_dir_substrings = ["strategies", "util"],
        size = "small",
    )
    _objc_compile_flags_test(
        name = name + "_pha_compile",
        target_under_test = ":_%s_pha_plugin__objc" % name,
        dir_suffixes = [src, src + "/strategies", src + "/util"],
        size = "small",
    )
    tests += [name + "_pha_surface", name + "_pha_objc_cc", name + "_pha_public_cc", name + "_pha_compile"]

    # Mixed ObjC + Swift plugin with a private header in internal/.
    msrc = name + "_mix"
    mix = _files(msrc, ["a.m", "include/Pub.h", "internal/Priv.h", "s.swift"])
    flutter_apple_plugin_library(
        name = name + "_mix_plugin",
        srcs = mix,
        module_name = name + "_mix_mod",
        platform = "ios",
        includes = [msrc + "/include"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    mod = after["_%s_mix_plugin__objc_module" % name]
    _surface_test(
        name = name + "_mix_module_surface",
        hdrs = _plain(mod["hdrs"]),
        srcs = mod.get("srcs", []),
        includes = mod["includes"],
        impl_deps = mod.get("implementation_deps", []),
        expected_hdrs = [msrc + "/include/Pub.h"],
        expected_srcs = [],
        expected_includes = [msrc + "/include"],
        expected_impl_deps = [],
        size = "small",
    )
    _surface(
        name + "_mix_surface",
        name + "_mix_plugin",
        expected_hdrs = [msrc + "/include/Pub.h"],
        expected_srcs = [msrc + "/a.m", msrc + "/internal/Priv.h"],
        expected_includes = [msrc + "/include"],
        expected_impl_deps = [":_%s_mix_plugin__private_header_dirs" % name],
    )
    _leak_free_public_target_test(
        name = name + "_mix_objc_cc",
        target_under_test = ":_%s_mix_plugin__objc" % name,
        required_header_substrings = ["include/Pub.h"],
        forbidden_header_substrings = ["Priv.h"],
        forbidden_dir_substrings = ["internal"],
        size = "small",
    )
    _leak_free_public_target_test(
        name = name + "_mix_public_cc",
        target_under_test = ":" + name + "_mix_plugin",
        forbidden_dir_substrings = ["internal"],
        size = "small",
    )
    tests += [name + "_mix_module_surface", name + "_mix_surface", name + "_mix_objc_cc", name + "_mix_public_cc"]

    # Empty includes: every header stays public, search paths still attach.
    esrc = name + "_empty"
    emp = _files(esrc, ["Classes/A.m", "Classes/A.h", "Classes/Sub/B.m", "Classes/Sub/B.h"])
    flutter_apple_plugin_library(
        name = name + "_empty_plugin",
        srcs = emp,
        module_name = name + "_empty_mod",
        platform = "ios",
        includes = [],
        tags = ["manual"],
    )
    _surface(
        name + "_empty_surface",
        name + "_empty_plugin",
        expected_hdrs = [esrc + "/Classes/A.h", esrc + "/Classes/Sub/B.h"],
        expected_srcs = [esrc + "/Classes/A.m", esrc + "/Classes/Sub/B.m"],
        expected_includes = [],
        expected_impl_deps = [":_%s_empty_plugin__private_header_dirs" % name],
    )
    _objc_compile_flags_test(
        name = name + "_empty_compile",
        target_under_test = ":_%s_empty_plugin__objc" % name,
        dir_suffixes = [esrc + "/Classes", esrc + "/Classes/Sub"],
        size = "small",
    )
    tests += [name + "_empty_surface", name + "_empty_compile"]

    # Non-empty includes matching no header: private headers only, no re-export.
    psrc = name + "_priv"
    priv = _files(psrc, ["P.m", "P.h"])
    flutter_apple_plugin_library(
        name = name + "_priv_plugin",
        srcs = priv,
        module_name = name + "_priv_mod",
        platform = "ios",
        includes = [psrc + "/include"],
        tags = ["manual"],
    )
    _surface(
        name + "_priv_surface",
        name + "_priv_plugin",
        expected_hdrs = [],
        expected_srcs = [psrc + "/P.m", psrc + "/P.h"],
        expected_includes = [psrc + "/include"],
        expected_impl_deps = [":_%s_priv_plugin__private_header_dirs" % name],
    )
    placeholder = native.existing_rules()["_%s_priv_plugin__swift_placeholder" % name]
    _placeholder_test(
        name = name + "_priv_placeholder",
        content = placeholder["content"],
        size = "small",
    )
    tests += [name + "_priv_surface", name + "_priv_placeholder"]

    native.test_suite(name = name, tests = [":" + t for t in tests])

def _placeholder_test_impl(ctx):
    """A header-less module has nothing to re-export."""
    env = unittest.begin(ctx)
    asserts.false(env, "@_exported" in "".join(ctx.attr.content), "unexpected re-export: %s" % ctx.attr.content)
    return unittest.end(env)

_placeholder_test = unittest.make(_placeholder_test_impl, attrs = {"content": attr.string_list()})
