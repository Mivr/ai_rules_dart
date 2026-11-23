"""Scale and macro-wiring tests for per-app Android plugin selection.

Exercises a 30-plugin fixture (`00`..`29`, with `29` refused on Android) wired
into both `flutter_android_app` and `flutter_android_aab`, plus a workspace
Android library passed in `deps`, and verifies that
`make_flutter_pub_hub_android_build_content` keeps `all_android_plugin_libs`
available for callers that name it directly.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "@rules_android//providers:providers.bzl",
    "AndroidLibraryResourceClassJarProvider",
)
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:android.bzl", "flutter_android_aab", "flutter_android_app")
load("//flutter:defs.bzl", "flutter_library", "flutter_plugin")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps")
load(
    "//flutter/private:flutter_pub_lock_hub.bzl",
    "make_flutter_pub_hub_android_build_content",
)

visibility(["//flutter/tests/..."])

_PLUGIN_IDS = [("0" + str(idx)) if idx < 10 else str(idx) for idx in range(30)]
_REACHED_IDS = ["07", "23"]

def _scale_android_jar_impl(ctx):
    """Emits minimal Java and resource-jar providers for one scale-fixture plugin."""
    stem = ctx.label.name
    code_jar = ctx.actions.declare_file(stem + ".jar")
    res_jar = ctx.actions.declare_file(stem + "_res.jar")
    ctx.actions.write(code_jar, "")
    ctx.actions.write(res_jar, "")
    res_java = JavaInfo(output_jar = res_jar, compile_jar = res_jar)
    return [
        DefaultInfo(files = depset([code_jar])),
        JavaInfo(
            output_jar = code_jar,
            compile_jar = code_jar,
            deps = [res_java],
            runtime_deps = [res_java],
        ),
        AndroidLibraryResourceClassJarProvider(jars = depset([res_jar], order = "preorder")),
    ]

_scale_android_jar = rule(
    implementation = _scale_android_jar_impl,
    doc = "Minimal Android plugin library fixture with a code jar and resource class jar.",
)

def _scale_unsupported_android_impl(ctx):
    """Refuses Android analysis, standing in for an unsupported native build in the lock."""
    fail("%s: native build unsupported" % ctx.label.name)

_scale_unsupported_android = rule(
    implementation = _scale_unsupported_android_impl,
    doc = "Android library fixture that fails analysis when reached.",
)

def _scale_app_target_impl(ctx):
    """Exposes `FlutterApplicationInfo` for a multi-package test fixture in one BUILD file."""
    collected = collect_flutter_plugin_deps(ctx.attr.deps)
    return [FlutterApplicationInfo(
        aot_strip = False,
        plugins = collected.all_plugins,
        android_plugin_libraries = collected.android_plugin_libraries,
    )]

_scale_app_target = rule(
    implementation = _scale_app_target_impl,
    attrs = {"deps": attr.label_list(doc = "Direct Dart and plugin targets of the app.")},
    doc = "Application stand-in carrying transitive plugin metadata.",
)

def _two_of_thirty_closure_test_impl(ctx):
    """A 2-plugin app in a 30-plugin package forwards only those 2 Android plugin libraries."""
    env = analysistest.begin(ctx)
    closure = analysistest.target_under_test(env)
    res_jars = [f.basename for f in closure[AndroidLibraryResourceClassJarProvider].jars.to_list()]
    res_set = {name: True for name in res_jars}
    code_jars = [
        jar.basename
        for jar in closure[JavaInfo].runtime_output_jars
        if jar.basename not in res_set
    ]
    asserts.equals(env, ["_scale_android_07.jar", "_scale_android_23.jar"], code_jars)
    asserts.equals(env, ["_scale_android_07_res.jar", "_scale_android_23_res.jar"], res_jars)
    return analysistest.end(env)

_two_of_thirty_closure_test = analysistest.make(_two_of_thirty_closure_test_impl)

def _two_of_thirty_registrant_test_impl(ctx):
    """The generated registrant names the 2 reached plugins and none of the other 28."""
    env = analysistest.begin(ctx)
    writes = [action for action in analysistest.target_actions(env) if action.mnemonic == "FileWrite"]
    asserts.equals(env, 1, len(writes))
    source = writes[0].content
    pos_23 = source.find("new dev.scale.p23.ScalePlugin23()")
    pos_07 = source.find("new dev.scale.p07.ScalePlugin07()")
    asserts.true(env, pos_23 >= 0, "ScalePlugin23 missing from registrant")
    asserts.true(env, pos_07 > pos_23, "ScalePlugin07 must follow ScalePlugin23")
    for pid in _PLUGIN_IDS:
        if pid not in _REACHED_IDS:
            asserts.false(env, ("ScalePlugin" + pid) in source, "unexpected ScalePlugin" + pid)
    return analysistest.end(env)

_two_of_thirty_registrant_test = analysistest.make(_two_of_thirty_registrant_test_impl)

def _hub_and_extra_deps_wiring_test_impl(ctx):
    """Checks hub aggregator retention and extra `deps` wiring on APK and AAB macros."""
    env = unittest.begin(ctx)
    hub_build = make_flutter_pub_hub_android_build_content(
        ["alpha", "beta", "gamma"],
        "deps",
        {"gamma": "@deps__scc_0//:gamma"},
    )
    asserts.true(env, 'name = "all_android_plugin_libs"' in hub_build)
    asserts.true(env, "@deps__alpha//android:lib" in hub_build)
    asserts.true(env, "@deps__beta//android:lib" in hub_build)
    asserts.true(env, "@deps__scc_0//gamma/android:lib" in hub_build)

    for target_deps, expected in [
        (ctx.attr.apk_binary_deps, ":___scale_apk_two_android_plugin_deps"),
        (ctx.attr.apk_registrant_deps, ":___scale_apk_two_android_plugin_deps"),
        (ctx.attr.apk_manifest_libs, ":___scale_apk_two_android_plugin_deps"),
        (ctx.attr.aab_registrant_deps, ":___scale_aab_two_android_plugin_deps"),
        (ctx.attr.aab_manifest_libs, ":___scale_aab_two_android_plugin_deps"),
    ]:
        asserts.true(env, expected in target_deps, str(target_deps))
        asserts.true(env, ":_scale_extra_android_lib" in target_deps, str(target_deps))

    asserts.equals(env, ":___scale_aab_two_android_plugins", ctx.attr.aab_closure_ref)
    asserts.true(env, ":___scale_aab_two_engine" in ctx.attr.aab_already_dexed, str(ctx.attr.aab_already_dexed))
    asserts.true(env, ":___scale_aab_two_android_plugin_deps" in ctx.attr.aab_rule_deps, str(ctx.attr.aab_rule_deps))
    for label_str in ctx.attr.apk_binary_deps + ctx.attr.aab_rule_deps:
        asserts.false(env, "all_android_plugin_libs" in label_str, label_str)
    return unittest.end(env)

_hub_and_extra_deps_wiring_test = unittest.make(
    _hub_and_extra_deps_wiring_test_impl,
    attrs = {
        "aab_already_dexed": attr.string_list(doc = "Normalized `already_dexed` of AAB plugin deps."),
        "aab_closure_ref": attr.string(doc = "Normalized `closure` label of AAB plugin deps."),
        "aab_manifest_libs": attr.string_list(doc = "Normalized `libraries` of AAB manifest merge."),
        "aab_registrant_deps": attr.string_list(doc = "Normalized `deps` of AAB registrant."),
        "aab_rule_deps": attr.string_list(doc = "Normalized `deps` across all emitted AAB rules."),
        "apk_binary_deps": attr.string_list(doc = "Normalized `deps` of APK `android_binary`."),
        "apk_manifest_libs": attr.string_list(doc = "Normalized `libraries` of APK manifest merge."),
        "apk_registrant_deps": attr.string_list(doc = "Normalized `deps` of APK registrant."),
    },
)

def _canon(items):
    """Normalizes same-package label strings to `:target`."""
    pkg_prefix = "//" + native.package_name() + ":"
    out = []
    for item in items:
        text = str(item).removeprefix("@@")
        if text.startswith(pkg_prefix):
            text = ":" + text[len(pkg_prefix):]
        elif not (text.startswith(":") or text.startswith("@") or text.startswith("//")):
            text = ":" + text
        out.append(text)
    return out

def _collect_aab_rule_deps():
    """Collects `deps` and `libraries` strings across every `_scale_aab_two` rule."""
    collected = []
    for rule_name, attrs in native.existing_rules().items():
        if "scale_aab_two" not in rule_name:
            continue
        for attr_name in ("deps", "libraries"):
            val = attrs.get(attr_name)
            if type(val) in ("list", "tuple"):
                collected.extend(_canon(val))
    return collected

def _declare_scale_fixture():
    """Declares 30 plugins, a workspace library, an extra Android dep, and APK/AAB targets."""
    _scale_android_jar(name = "_scale_extra_android_lib", tags = ["manual"])
    for pid in _PLUGIN_IDS:
        if pid == "29":
            _scale_unsupported_android(name = "_scale_android_29", tags = ["manual"])
        else:
            _scale_android_jar(name = "_scale_android_" + pid, tags = ["manual"])
        flutter_plugin(
            name = "_scale_plugin_" + pid,
            package_name = "scale_plugin_" + pid,
            platforms = ["android"],
            plugin_class = "ScalePlugin" + pid,
            android_package = "dev.scale.p" + pid,
            android_libs = select({
                "@platforms//os:android": [":_scale_android_" + pid],
                "//conditions:default": [],
            }),
            tags = ["manual"],
        )
    flutter_library(
        name = "_scale_feature_lib",
        package_name = "scale_feature_lib",
        srcs = ["lib/compile_api_dep.dart"],
        deps = [":_scale_plugin_23"],
        tags = ["manual"],
    )
    _scale_app_target(
        name = "_scale_app_two",
        deps = [":_scale_feature_lib", ":_scale_plugin_07"],
        tags = ["manual"],
    )
    flutter_android_app(
        name = "_scale_apk_two",
        package_name = "dev.scale.two",
        application = ":_scale_app_two",
        deps = [":_scale_extra_android_lib"],
        pub_hub_name = "deps",
        tags = ["manual"],
    )
    flutter_android_aab(
        name = "_scale_aab_two",
        package_name = "dev.scale.two",
        application = ":_scale_app_two",
        deps = [":_scale_extra_android_lib"],
        pub_hub_name = "deps",
        tags = ["manual"],
    )

def android_plugin_scale_test_suite(name):
    """Declares the 30-plugin closure scaling and APK/AAB macro-wiring test suite.

    Args:
      name: Name of the `test_suite` target.
    """
    _declare_scale_fixture()
    apk_bin = native.existing_rule("___scale_apk_two_binary")
    apk_reg = native.existing_rule("___scale_apk_two_registrant")
    apk_man = native.existing_rule("___scale_apk_two_manifest_with_library_permissions")
    aab_deps = native.existing_rule("___scale_aab_two_android_plugin_deps")
    aab_reg = native.existing_rule("___scale_aab_two_registrant")
    aab_man = native.existing_rule("___scale_aab_two_manifest_with_library_permissions")

    _two_of_thirty_closure_test(
        name = name + "_two_of_thirty_closure",
        target_under_test = ":___scale_apk_two_android_plugins",
        size = "small",
    )
    _two_of_thirty_registrant_test(
        name = name + "_two_of_thirty_registrant",
        target_under_test = ":___scale_apk_two_registrant_src",
        size = "small",
    )
    _hub_and_extra_deps_wiring_test(
        name = name + "_hub_and_extra_deps_wiring",
        aab_already_dexed = _canon(aab_deps["already_dexed"]),
        aab_closure_ref = _canon([aab_deps["closure"]])[0],
        aab_manifest_libs = _canon(aab_man["libraries"]),
        aab_registrant_deps = _canon(aab_reg["deps"]),
        aab_rule_deps = _collect_aab_rule_deps(),
        apk_binary_deps = _canon(apk_bin["deps"]),
        apk_manifest_libs = _canon(apk_man["libraries"]),
        apk_registrant_deps = _canon(apk_reg["deps"]),
        size = "small",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_two_of_thirty_closure",
            ":" + name + "_two_of_thirty_registrant",
            ":" + name + "_hub_and_extra_deps_wiring",
        ],
    )
