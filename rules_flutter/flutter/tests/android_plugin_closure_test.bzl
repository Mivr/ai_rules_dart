"""Analysis and build tests for per-app Android plugin selection.

Four plugins stand in for a lock: `a` and `b` (with a transitive Maven jar on
`b`) are used by the two-plugin apps, `c` is unrelated to them, and `r` has an
Android library refused at analysis (standing in for `externalNativeBuild`).
`flutter_android_app` wires `flutter_android_plugin_closure` into its
`android_binary` and registrant: two-plugin apps receive only `a` and `b`,
unrelated apps ignore `r` while `r`'s own app fails, and the app using `a`, `b`
and `c` produces the same registrant, merged manifest permissions and dex
inputs as the `all_android_plugin_libs` aggregator.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load(
    "@rules_android//providers:providers.bzl",
    "AndroidLibraryResourceClassJarProvider",
    "AndroidNativeLibsInfo",
    "StarlarkAndroidResourcesInfo",
)
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_java//java/common:proguard_spec_info.bzl", "ProguardSpecInfo")
load("//flutter:android.bzl", "flutter_android_app", "flutter_android_manifest_merge")
load("//flutter:defs.bzl", "flutter_library", "flutter_plugin")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load(
    "//flutter/private:flutter_android_plugin_closure.bzl",
    "flutter_android_plugin_closure",
    "flutter_android_transitioned_library",
)
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps")

visibility(["//flutter/tests/..."])

_PLUGINS = ["a", "b", "c", "r"]

def _empty_preorder():
    """An empty `preorder` depset, matching `rules_android` resource providers."""
    return depset(order = "preorder")

def _resources_info(nodes, manifests):
    """Builds a `StarlarkAndroidResourcesInfo` with `preorder` depsets like `kt_android_library`."""
    empty = _empty_preorder()
    return StarlarkAndroidResourcesInfo(
        direct_resources_nodes = depset(nodes, order = "preorder"),
        transitive_resources_nodes = empty,
        transitive_assets = empty,
        transitive_assets_symbols = empty,
        transitive_compiled_assets = empty,
        direct_compiled_resources = empty,
        transitive_compiled_resources = empty,
        transitive_compiled_resources_with_public_xml = empty,
        transitive_manifests = depset(manifests, order = "preorder"),
        transitive_r_txts = empty,
        transitive_resource_files = empty,
        packages_to_r_txts = {},
        transitive_resource_apks = empty,
        package = "dev.closure",
    )

def _maven_jar_impl(ctx):
    """Emits a plain `JavaInfo` standing in for a plugin's Maven dependency."""
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")
    ctx.actions.write(jar, "")
    return [DefaultInfo(files = depset([jar])), JavaInfo(output_jar = jar, compile_jar = jar)]

_maven_jar = rule(
    implementation = _maven_jar_impl,
    doc = "A stand-in Maven runtime jar reached only through a plugin's `deps`.",
)

def _fake_android_lib_impl(ctx):
    """Emits the Android, Java, ProGuard and native providers a plugin library carries."""
    name = ctx.label.name
    jar = ctx.actions.declare_file(name + ".jar")
    r_jar = ctx.actions.declare_file(name + "_r.jar")
    manifest = ctx.actions.declare_file(name + "/AndroidManifest.xml")
    proguard = ctx.actions.declare_file(name + ".pro")
    native_so = ctx.actions.declare_file("lib" + name + ".so")
    for out in [jar, r_jar, proguard, native_so]:
        ctx.actions.write(out, "")
    ctx.actions.write(
        manifest,
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.closure">' +
        '<uses-permission android:name="dev.closure.PERMISSION_%s"/>' % ctx.attr.permission_suffix +
        "</manifest>\n",
    )
    r_java = JavaInfo(output_jar = r_jar, compile_jar = r_jar)
    dep_java = [d[JavaInfo] for d in ctx.attr.deps] + [r_java]
    node = struct(manifest = manifest, exports_manifest = True)
    return [
        DefaultInfo(files = depset([jar])),
        JavaInfo(output_jar = jar, compile_jar = jar, deps = dep_java, runtime_deps = dep_java),
        AndroidLibraryResourceClassJarProvider(jars = depset([r_jar], order = "preorder")),
        _resources_info([node], [manifest]),
        ProguardSpecInfo(depset([proguard], order = "preorder")),
        AndroidNativeLibsInfo(native_libs = depset([native_so], order = "preorder")),
    ]

_fake_android_lib = rule(
    implementation = _fake_android_lib_impl,
    attrs = {
        "deps": attr.label_list(providers = [JavaInfo], doc = "Transitive Java/Maven dependencies."),
        "permission_suffix": attr.string(mandatory = True, doc = "Permission suffix for the exported manifest."),
    },
    doc = "A stand-in `kt_android_library` with an exported manifest, resource jar, ProGuard spec and `.so`.",
)

def _legacy_aggregator_impl(ctx):
    """Re-exports every library in `exports`, standing in for `all_android_plugin_libs`."""
    exports = ctx.attr.exports
    res_exports = [e for e in exports if StarlarkAndroidResourcesInfo in e]
    nodes = [n for e in res_exports for n in e[StarlarkAndroidResourcesInfo].direct_resources_nodes.to_list()]
    manifests = [m for e in res_exports for m in e[StarlarkAndroidResourcesInfo].transitive_manifests.to_list()]
    return [
        DefaultInfo(),
        java_common.merge([e[JavaInfo] for e in exports]),
        AndroidLibraryResourceClassJarProvider(
            jars = depset(
                transitive = [
                    e[AndroidLibraryResourceClassJarProvider].jars
                    for e in exports
                    if AndroidLibraryResourceClassJarProvider in e
                ],
                order = "preorder",
            ),
        ),
        _resources_info(nodes, manifests),
        ProguardSpecInfo(
            depset(
                transitive = [e[ProguardSpecInfo].specs for e in exports if ProguardSpecInfo in e],
                order = "preorder",
            ),
        ),
        AndroidNativeLibsInfo(
            native_libs = depset(
                transitive = [e[AndroidNativeLibsInfo].native_libs for e in exports if AndroidNativeLibsInfo in e],
                order = "preorder",
            ),
        ),
    ]

_legacy_aggregator = rule(
    implementation = _legacy_aggregator_impl,
    attrs = {"exports": attr.label_list(mandatory = True, doc = "Plugin libraries re-exported together.")},
    doc = "Stand-in for `@<hub>//android:all_android_plugin_libs` (`kt_android_library(exports = ...)`).",
)

def _refused_android_lib_impl(ctx):
    """Fails analysis, standing in for a plugin whose Android native build is unsupported."""
    fail("%s: native build unsupported" % ctx.label.name)

_refused_android_lib = rule(
    implementation = _refused_android_lib_impl,
    doc = "An Android library whose analysis is refused, as an unsupported native build is.",
)

def _fake_app_impl(ctx):
    """Collects transitive plugin metadata into `FlutterApplicationInfo` without compiling Dart."""
    plugins = collect_flutter_plugin_deps(ctx.attr.deps)
    return [FlutterApplicationInfo(
        aot_strip = False,
        plugins = plugins.all_plugins,
        android_plugin_libraries = plugins.android_plugin_libraries,
    )]

_fake_app = rule(
    implementation = _fake_app_impl,
    attrs = {"deps": attr.label_list(doc = "The Dart targets the app depends on.")},
    doc = "An application stand-in: the plugin metadata of its dependencies, without compiling Dart.",
)

def _manifest_permissions_test_impl(ctx):
    """Writes a shell check verifying required and absent permissions in a merged manifest."""
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    path = ctx.file.manifest.short_path
    checks = ["#!/usr/bin/env bash", "set -euo pipefail"]
    for perm in ctx.attr.present:
        checks.append("grep -Fq %r %r" % (perm, path))
    for perm in ctx.attr.absent:
        checks.append("! grep -Fq %r %r" % (perm, path))
    ctx.actions.write(output = out, content = "\n".join(checks) + "\n", is_executable = True)
    return [DefaultInfo(executable = out, runfiles = ctx.runfiles(files = [ctx.file.manifest]))]

_manifest_permissions_test = rule(
    implementation = _manifest_permissions_test_impl,
    test = True,
    attrs = {
        "manifest": attr.label(allow_single_file = True, mandatory = True, doc = "Merged manifest XML."),
        "present": attr.string_list(doc = "Substrings that must appear in `manifest`."),
        "absent": attr.string_list(doc = "Substrings that must not appear in `manifest`."),
    },
    doc = "Checks which plugin permissions were lifted into a merged `AndroidManifest.xml`.",
)

def _basenames(files):
    """The basenames of `files` in order."""
    return [f.basename for f in files]

def _dex_jars_from_closure(closure):
    """Jars the `android_binary` dex aspect dexes on a direct `flutter_android_plugin_closure` dep."""
    excluded = {f.basename: True for f in closure[AndroidLibraryResourceClassJarProvider].jars.to_list()}
    return [
        jar.basename
        for jar in closure[JavaInfo].runtime_output_jars
        if jar.basename not in excluded
    ]

def _dex_jars_from_aggregator(aggregator):
    """Jars the `android_binary` dex aspect dexes across `all_android_plugin_libs` exports."""
    excluded = {f.basename: True for f in aggregator[AndroidLibraryResourceClassJarProvider].jars.to_list()}
    return [
        jar.basename
        for jar in aggregator[JavaInfo].transitive_runtime_jars.to_list()
        if jar.basename not in excluded
    ]

def _macro_wires_closure_test_impl(ctx):
    """`flutter_android_app` wires its per-app plugin closure and shared engine, never `all_android_plugin_libs`."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], ctx.attr.raw_already_dexed)
    asserts.equals(env, ":___closure_apk_ab_android_plugins", ctx.attr.deps_closure)
    asserts.true(env, ":___closure_apk_ab_android_plugin_deps" in ctx.attr.binary_deps)
    asserts.true(env, ":___closure_apk_ab_engine" in ctx.attr.binary_deps)
    asserts.true(env, ":___closure_apk_ab_android_plugin_deps" in ctx.attr.registrant_deps)
    asserts.true(env, ":___closure_apk_ab_engine" in ctx.attr.already_dexed)
    asserts.true(env, ":___closure_apk_ab_engine_raw" in ctx.attr.engine_exports)
    for dep in ctx.attr.binary_deps + ctx.attr.registrant_deps:
        asserts.false(env, "all_android_plugin_libs" in dep, dep)
    return unittest.end(env)

_macro_wires_closure_test = unittest.make(
    _macro_wires_closure_test_impl,
    attrs = {
        "already_dexed": attr.string_list(),
        "binary_deps": attr.string_list(),
        "deps_closure": attr.string(),
        "engine_exports": attr.string_list(),
        "raw_already_dexed": attr.string_list(),
        "registrant_deps": attr.string_list(),
    },
)

def _only_reached_test_impl(ctx):
    """The closure carries only the expected Android libraries in label order."""
    env = analysistest.begin(ctx)
    closure = analysistest.target_under_test(env)
    asserts.equals(env, ctx.attr.dex_jars, _dex_jars_from_closure(closure))
    asserts.equals(
        env,
        ctx.attr.r_jars,
        _basenames(closure[AndroidLibraryResourceClassJarProvider].jars.to_list()),
    )
    nodes = closure[StarlarkAndroidResourcesInfo].direct_resources_nodes.to_list()
    asserts.equals(env, ctx.attr.nodes, [n.manifest.dirname.split("/")[-1] for n in nodes])
    asserts.equals(env, ctx.attr.proguards, _basenames(closure[ProguardSpecInfo].specs.to_list()))
    asserts.equals(
        env,
        ctx.attr.native_libs,
        _basenames(closure[AndroidNativeLibsInfo].native_libs.to_list()),
    )
    return analysistest.end(env)

_only_reached_test = analysistest.make(
    _only_reached_test_impl,
    attrs = {
        "dex_jars": attr.string_list(),
        "native_libs": attr.string_list(),
        "nodes": attr.string_list(),
        "proguards": attr.string_list(),
        "r_jars": attr.string_list(),
    },
)

def _non_android_ignores_refused_test_impl(ctx):
    """On a non-Android platform, the `select()` edge leaves a refused Android library unreached."""
    env = analysistest.begin(ctx)
    app = analysistest.target_under_test(env)
    asserts.equals(env, [], app[FlutterApplicationInfo].android_plugin_libraries.to_list())
    return analysistest.end(env)

_non_android_ignores_refused_test = analysistest.make(_non_android_ignores_refused_test_impl)

def _refused_test_impl(ctx):
    """The Android app that depends on the refused plugin fails naming that library."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "_lib_r: native build unsupported")
    return analysistest.end(env)

_refused_test = analysistest.make(_refused_test_impl, expect_failure = True)

def _all_matches_aggregator_test_impl(ctx):
    """An app using every plugin gets the same dex jars, ProGuard specs and native libs as the aggregator."""
    env = analysistest.begin(ctx)
    closure = analysistest.target_under_test(env)
    legacy = ctx.attr.legacy
    engine = ctx.attr.engine
    closure_jars = _dex_jars_from_closure(closure)
    engine_jars = _basenames(engine[JavaInfo].transitive_runtime_jars.to_list())
    asserts.equals(env, [], [j for j in closure_jars if j in engine_jars])
    asserts.equals(env, sorted(_dex_jars_from_aggregator(legacy)), sorted(closure_jars + engine_jars))
    asserts.equals(env, ["_lib_a.jar", "_lib_b.jar", "_lib_c.jar", "_maven_b.jar"], closure_jars)
    asserts.equals(
        env,
        _basenames(legacy[ProguardSpecInfo].specs.to_list()),
        _basenames(closure[ProguardSpecInfo].specs.to_list()),
    )
    asserts.equals(
        env,
        _basenames(legacy[AndroidNativeLibsInfo].native_libs.to_list()),
        _basenames(closure[AndroidNativeLibsInfo].native_libs.to_list()),
    )
    return analysistest.end(env)

_all_matches_aggregator_test = analysistest.make(
    _all_matches_aggregator_test_impl,
    attrs = {
        "engine": attr.label(mandatory = True),
        "legacy": attr.label(mandatory = True),
    },
)

def _registrant_test_impl(ctx):
    """The registrant of the all-plugins app registers every plugin class in deterministic order."""
    env = analysistest.begin(ctx)
    writes = [a for a in analysistest.target_actions(env) if a.mnemonic == "FileWrite"]
    asserts.equals(env, 1, len(writes))
    content = writes[0].content
    positions = [content.find("new %s()" % cls) for cls in ctx.attr.classes]
    for cls, pos in zip(ctx.attr.classes, positions):
        asserts.true(env, pos >= 0, "%s missing from the registrant" % cls)
    asserts.equals(env, sorted(positions), positions)
    return analysistest.end(env)

_registrant_test = analysistest.make(_registrant_test_impl, attrs = {"classes": attr.string_list()})

def _declare_plugins_and_libs():
    """Declares the four stand-in plugins, the shared engine jar, and the legacy aggregator."""
    _maven_jar(name = "_shared_androidx", tags = ["manual"])
    _maven_jar(name = "_maven_b", tags = ["manual"])
    flutter_android_transitioned_library(
        name = "_shared_engine",
        exports = [":_shared_androidx"],
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )
    plugin_deps = {"a": [":_shared_androidx"], "b": [":_maven_b"], "c": []}
    for p in _PLUGINS:
        if p == "r":
            _refused_android_lib(name = "_lib_r", tags = ["manual"])
        else:
            _fake_android_lib(
                name = "_lib_" + p,
                deps = plugin_deps[p],
                permission_suffix = p.upper(),
                tags = ["manual"],
            )
        flutter_plugin(
            name = "_closure_plugin_" + p,
            package_name = "closure_plugin_" + p,
            platforms = ["android"],
            plugin_class = "Plugin" + p.upper(),
            android_package = "dev.closure." + p,
            android_libs = select({
                "@platforms//os:android": [":_lib_" + p],
                "//conditions:default": [],
            }),
            tags = ["manual"],
        )
    _legacy_aggregator(
        name = "_legacy_aggregator_all",
        exports = [":_shared_androidx", ":_lib_a", ":_lib_b", ":_lib_c"],
        tags = ["manual"],
    )
    flutter_library(
        name = "_closure_workspace_lib",
        package_name = "closure_workspace_lib",
        srcs = ["lib/compile_api_dep.dart"],
        deps = [":_closure_plugin_b"],
        tags = ["manual"],
    )

def _declare_federated_plugins():
    """Declares a federated umbrella, its default Android plugin, and a direct override."""
    for suffix in ["def", "alt"]:
        _fake_android_lib(
            name = "_lib_fed_" + suffix,
            deps = [],
            permission_suffix = "FED_" + suffix.upper(),
            tags = ["manual"],
        )
    flutter_plugin(
        name = "_closure_plugin_fed_def",
        package_name = "fed_def",
        plugin_platforms_json = json.encode({
            "android": {"package": "dev.closure.fed_def", "pluginClass": "FedDef"},
        }),
        android_libs = select({
            "@platforms//os:android": [":_lib_fed_def"],
            "//conditions:default": [],
        }),
        tags = ["manual"],
    )
    flutter_plugin(
        name = "_closure_plugin_fed_umbrella",
        package_name = "fed_umbrella",
        deps = [":_closure_plugin_fed_def"],
        plugin_platforms_json = json.encode({"android": {"default_package": "fed_def"}}),
        tags = ["manual"],
    )
    flutter_plugin(
        name = "_closure_plugin_fed_alt",
        package_name = "fed_alt",
        plugin_platforms_json = json.encode({
            "__implements__": "fed_umbrella",
            "android": {"package": "dev.closure.fed_alt", "pluginClass": "FedAlt"},
        }),
        android_libs = select({
            "@platforms//os:android": [":_lib_fed_alt"],
            "//conditions:default": [],
        }),
        tags = ["manual"],
    )

def _declare_apps_and_manifests():
    """Declares per-combination plugin closures, macro-wired apps, and manifest merges."""
    for app, deps in {
        "ab": [":_closure_plugin_b", ":_closure_plugin_a"],
        "via_lib": [":_closure_workspace_lib", ":_closure_plugin_a"],
        "all": [":_closure_plugin_c", ":_closure_plugin_a", ":_closure_plugin_b"],
        "fed": [":_closure_plugin_fed_umbrella", ":_closure_plugin_fed_alt"],
        "r": [":_closure_plugin_r"],
    }.items():
        _fake_app(name = "_closure_app_" + app, deps = deps, tags = ["manual"])
        flutter_android_plugin_closure(
            name = "_closure_plugins_" + app + "_raw",
            application = ":_closure_app_" + app,
            android_abi = "arm64-v8a",
            tags = ["manual"],
        )
        flutter_android_plugin_closure(
            name = "_closure_plugins_" + app,
            closure = ":_closure_plugins_" + app + "_raw",
            android_abi = "arm64-v8a",
            already_dexed = [":_shared_engine"],
            tags = ["manual"],
        )
    for app in ["ab", "all"]:
        flutter_android_app(
            name = "_closure_apk_" + app,
            package_name = "dev.closure." + app,
            application = ":_closure_app_" + app,
            pub_hub_name = "deps",
            tags = ["manual"],
        )
    write_file(
        name = "_closure_base_manifest",
        out = "_closure_base_manifest/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.closure.app">',
            '    <application android:label="ClosureApp"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )
    for suffix, libs in [
        ("ab", [":_shared_engine", ":_closure_plugins_ab"]),
        ("all", [":_shared_engine", ":_closure_plugins_all"]),
        ("legacy_all", [":_legacy_aggregator_all"]),
    ]:
        flutter_android_manifest_merge(
            name = "_closure_manifest_" + suffix,
            base = ":_closure_base_manifest",
            libraries = libs,
            tags = ["manual"],
        )

def _normalize_dep_labels(deps):
    """Normalizes same-package label strings so `:_x` and `_x` compare uniformly."""
    return [d if d.startswith(":") or d.startswith("@") or d.startswith("//") else ":" + d for d in deps]

def _declare_macro_wiring_test(name):
    """Declares the load-time check on the targets `flutter_android_app` emits."""
    binary_rule = native.existing_rule("___closure_apk_ab_binary")
    registrant_rule = native.existing_rule("___closure_apk_ab_registrant")
    raw_closure_rule = native.existing_rule("___closure_apk_ab_android_plugins")
    deps_closure_rule = native.existing_rule("___closure_apk_ab_android_plugin_deps")
    engine_rule = native.existing_rule("___closure_apk_ab_engine")
    _macro_wires_closure_test(
        name = name + "_macro_wiring",
        already_dexed = _normalize_dep_labels([str(d) for d in deps_closure_rule["already_dexed"]]),
        binary_deps = _normalize_dep_labels(binary_rule["deps"]),
        deps_closure = _normalize_dep_labels([str(deps_closure_rule["closure"])])[0],
        engine_exports = _normalize_dep_labels(engine_rule["exports"]),
        raw_already_dexed = _normalize_dep_labels([str(d) for d in (raw_closure_rule.get("already_dexed") or [])]),
        registrant_deps = _normalize_dep_labels(registrant_rule["deps"]),
        size = "small",
    )

def _declare_legacy_parity_tests(name):
    """Declares tests checking parity with the legacy aggregator when all plugins are used."""
    _all_matches_aggregator_test(
        name = name + "_all_matches_aggregator",
        target_under_test = ":_closure_plugins_all",
        engine = ":_shared_engine",
        legacy = ":_legacy_aggregator_all",
        size = "small",
    )
    _registrant_test(
        name = name + "_registrant_all",
        target_under_test = ":___closure_apk_all_registrant_src",
        classes = ["dev.closure.c.PluginC", "dev.closure.a.PluginA", "dev.closure.b.PluginB"],
        size = "small",
    )
    _manifest_permissions_test(
        name = name + "_manifest_all_permissions",
        manifest = ":_closure_manifest_all",
        present = ["dev.closure.PERMISSION_A", "dev.closure.PERMISSION_B", "dev.closure.PERMISSION_C"],
        size = "small",
    )
    diff_test(
        name = name + "_manifest_all_equals_legacy",
        file1 = ":_closure_manifest_all",
        file2 = ":_closure_manifest_legacy_all",
        size = "small",
    )

def android_plugin_closure_test_suite(name):
    """Instantiates the plugin-selection fixtures and tests.

    Args:
      name: The `test_suite` name.
    """
    _declare_plugins_and_libs()
    _declare_federated_plugins()
    _declare_apps_and_manifests()
    _declare_macro_wiring_test(name)
    _declare_legacy_parity_tests(name)
    for app in ["ab", "via_lib"]:
        _only_reached_test(
            name = name + "_only_reached_" + app,
            target_under_test = ":_closure_plugins_" + app,
            dex_jars = ["_lib_a.jar", "_lib_b.jar", "_maven_b.jar"],
            r_jars = ["_lib_a_r.jar", "_lib_b_r.jar"],
            nodes = ["_lib_a", "_lib_b"],
            proguards = ["_lib_a.pro", "_lib_b.pro"],
            native_libs = ["lib_lib_a.so", "lib_lib_b.so"],
            size = "small",
        )
    _only_reached_test(
        name = name + "_federated_override",
        target_under_test = ":_closure_plugins_fed",
        dex_jars = ["_lib_fed_alt.jar"],
        r_jars = ["_lib_fed_alt_r.jar"],
        nodes = ["_lib_fed_alt"],
        proguards = ["_lib_fed_alt.pro"],
        native_libs = ["lib_lib_fed_alt.so"],
        size = "small",
    )
    _manifest_permissions_test(
        name = name + "_manifest_ab_permissions",
        manifest = ":_closure_manifest_ab",
        present = ["dev.closure.PERMISSION_A", "dev.closure.PERMISSION_B"],
        absent = ["dev.closure.PERMISSION_C"],
        size = "small",
    )
    _non_android_ignores_refused_test(
        name = name + "_non_android_ignores_refused",
        target_under_test = ":_closure_app_r",
        size = "small",
    )
    _refused_test(
        name = name + "_refused_fails_dependents",
        target_under_test = ":_closure_plugins_r",
        size = "small",
    )
    native.test_suite(name = name, tests = [":" + name + "_" + t for t in [
        "macro_wiring",
        "only_reached_ab",
        "only_reached_via_lib",
        "federated_override",
        "manifest_ab_permissions",
        "non_android_ignores_refused",
        "refused_fails_dependents",
        "all_matches_aggregator",
        "registrant_all",
        "manifest_all_permissions",
        "manifest_all_equals_legacy",
    ]])
