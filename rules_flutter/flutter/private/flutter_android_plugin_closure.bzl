"""The Android libraries of the plugins an app's Dart graph reaches.

Each plugin's Dart target carries an edge to its Android library
(`flutter_plugin(android_libs = ...)`; for a pub plugin the edge is selected
only under the Android platform). `flutter_android_plugin_closure` walks the
app's transitive Dart dependencies, gathers those libraries, and forwards their
Android providers into the `android_binary` in one deterministic order. An app
therefore compiles, dexes and packages the plugins it depends on and no others.
"""

load(
    "@rules_android//providers:providers.bzl",
    "AndroidCcLinkParamsInfo",
    "AndroidLibraryResourceClassJarProvider",
    "AndroidNativeLibsInfo",
    "BaselineProfileProvider",
    "StarlarkAndroidResourcesInfo",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java:java_import.bzl", "java_import")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_java//java/common:proguard_spec_info.bzl", "ProguardSpecInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS")
load(
    "//flutter/private:flutter_android_application.bzl",
    "android_platform_transition",
    "flutter_android_bundle",
)
load("//flutter/private:plugin_federation.bzl", "resolve_federated_plugins")

visibility(["//flutter/..."])

_PluginAndroidLibsInfo = provider(
    doc = "The Android library targets of a Dart target and its transitive Dart dependencies.",
    fields = {
        "libs": "depset[struct]: `struct(lib, package, scc)` entries for `android_libs` on reached plugins.",
    },
)

_PluginClosureInfo = provider(
    doc = "Collected Android plugin library targets from an application's Dart graph.",
    fields = {"libs": "list[Target]: Reached plugin Android library targets in label order."},
)

_ASPECT_ATTRS = ["deps", "library", "scc_members"]

def _aspect_attr_targets(rule_attr, name):
    """Target list from `rule_attr.<name>`, handling both label and label_list attrs."""
    val = getattr(rule_attr, name, None)
    if type(val) == "list":
        return val
    if type(val) == "Target":
        return [val]
    return []

def _scc_member_package(label):
    """Member package name for an `@<scc_repo>//<pkg>/android:lib` label, or `""`."""
    if label.name != "lib" or not label.package.endswith("/android"):
        return ""
    return label.package[:-len("/android")].rpartition("/")[2]

def _plugin_android_libs_aspect_impl(target, ctx):
    """Gathers direct `android_libs` tagged with their plugin package and transitive deps."""
    pkg_by_label = {}
    if FlutterInfo in target:
        for entry in target[FlutterInfo].android_plugin_libraries.to_list():
            pkg_by_label[entry.label] = entry.package
    direct = []
    for lib in _aspect_attr_targets(ctx.rule.attr, "android_libs"):
        if lib.label in pkg_by_label:
            direct.append(struct(lib = lib, package = pkg_by_label[lib.label], scc = False))
        else:
            scc_pkg = _scc_member_package(lib.label)
            direct.append(struct(lib = lib, package = scc_pkg, scc = bool(scc_pkg)))
    transitive = [
        dep[_PluginAndroidLibsInfo].libs
        for attr_name in _ASPECT_ATTRS
        for dep in _aspect_attr_targets(ctx.rule.attr, attr_name)
        if _PluginAndroidLibsInfo in dep
    ]
    return [_PluginAndroidLibsInfo(libs = depset(direct = direct, transitive = transitive))]

_plugin_android_libs_aspect = aspect(
    implementation = _plugin_android_libs_aspect_impl,
    attr_aspects = _ASPECT_ATTRS,
    doc = "Collects the `android_libs` of every plugin reachable through Dart dependencies.",
)

def _runtime_java_infos(java_infos, resource_class_jars, already_dexed):
    """`JavaInfo`s for the transitive runtime jars no library lists as its own output.

    The dexing aspect only walks `deps`, so a jar reaching the app solely through
    a plugin's own dependencies (a Maven AAR, say) must appear as an output of the
    forwarded `JavaInfo`. Resource class jars and jars the binary already dexes
    through its engine or registrant deps are left out.
    """
    excluded = {jar: True for jar in resource_class_jars.to_list()}
    for dep in already_dexed:
        for jar in dep[JavaInfo].transitive_runtime_jars.to_list():
            excluded[jar] = True
    direct_jars = {jar: True for info in java_infos for jar in info.runtime_output_jars}
    transitive = depset(transitive = [info.transitive_runtime_jars for info in java_infos]).to_list()
    return [
        JavaInfo(output_jar = jar, compile_jar = jar)
        for jar in transitive
        if jar not in direct_jars and jar not in excluded
    ]

def _merged_preorder(infos, field):
    """Merges depset `field` across `infos` in `preorder`."""
    return depset(
        transitive = [getattr(info, field, None) or depset(order = "preorder") for info in infos],
        order = "preorder",
    )

def _merge_resources_info(infos):
    """One `StarlarkAndroidResourcesInfo` standing for all of `infos`, or None."""
    if not infos:
        return None
    packages_to_r_txts = {}
    for info in infos:
        for package, r_txts in (getattr(info, "packages_to_r_txts", None) or {}).items():
            packages_to_r_txts[package] = depset(transitive = [packages_to_r_txts.get(package, depset()), r_txts])
    return StarlarkAndroidResourcesInfo(
        direct_resources_nodes = _merged_preorder(infos, "direct_resources_nodes"),
        transitive_resources_nodes = _merged_preorder(infos, "transitive_resources_nodes"),
        transitive_assets = _merged_preorder(infos, "transitive_assets"),
        transitive_assets_symbols = _merged_preorder(infos, "transitive_assets_symbols"),
        transitive_compiled_assets = _merged_preorder(infos, "transitive_compiled_assets"),
        direct_compiled_resources = _merged_preorder(infos, "direct_compiled_resources"),
        transitive_compiled_resources = _merged_preorder(infos, "transitive_compiled_resources"),
        transitive_compiled_resources_with_public_xml = _merged_preorder(
            infos,
            "transitive_compiled_resources_with_public_xml",
        ),
        transitive_manifests = _merged_preorder(infos, "transitive_manifests"),
        transitive_r_txts = _merged_preorder(infos, "transitive_r_txts"),
        transitive_resource_files = _merged_preorder(infos, "transitive_resource_files"),
        packages_to_r_txts = packages_to_r_txts,
        transitive_resource_apks = _merged_preorder(infos, "transitive_resource_apks"),
        package = getattr(infos[0], "package", None),
    )

def _merge_native_cc_info(libs):
    """Merged `AndroidCcLinkParamsInfo` across `libs`, or None when none carry C++ link inputs."""
    cc_infos = []
    for lib in libs:
        if AndroidCcLinkParamsInfo in lib:
            cc_infos.append(lib[AndroidCcLinkParamsInfo].link_params)
        if CcInfo in lib:
            cc_infos.append(lib[CcInfo])
    if not cc_infos:
        return None
    return AndroidCcLinkParamsInfo(link_params = cc_common.merge_cc_infos(cc_infos = cc_infos))

def _merge_output_groups(libs):
    """Forwards validation and internal top-level output groups from `libs`, or None."""
    hidden = [
        lib[OutputGroupInfo]._hidden_top_level_INTERNAL_
        for lib in libs
        if OutputGroupInfo in lib and hasattr(lib[OutputGroupInfo], "_hidden_top_level_INTERNAL_")
    ]
    validation = [
        lib[OutputGroupInfo]._validation
        for lib in libs
        if OutputGroupInfo in lib and hasattr(lib[OutputGroupInfo], "_validation")
    ]
    if not hidden and not validation:
        return None
    groups = {"_hidden_top_level_INTERNAL_": depset(transitive = hidden)}
    if validation:
        groups["_validation"] = depset(transitive = validation)
    return OutputGroupInfo(**groups)

def _android_plugin_resolution(application):
    """Resolved Android plugin map (`name -> plugin`) and federated-dropped package set."""
    plugins = getattr(application[FlutterApplicationInfo], "plugins", None) or []
    kept = {p.name: p for p in resolve_federated_plugins(plugins, "android")}
    dropped = {p.name: True for p in plugins if p.name not in kept}
    return kept, dropped

def _scc_member_needs_android_lib(lib, plugin):
    """Whether an SCC member's `android:lib` carries a plugin or compiled Android classes."""
    if plugin != None:
        platforms = getattr(plugin, "platforms", None) or {}
        android = platforms.get("android") or {}
        plugin_class = android.get("pluginClass", "")
        if (plugin_class and plugin_class != "none") or android.get("ffiPlugin") == True:
            return True
    return JavaInfo in lib and bool(lib[JavaInfo].runtime_output_jars)

def _plugin_android_libs(application):
    """The plugin Android libraries `application`'s Dart graph reaches, in label order.

    Args:
        application: A target the plugin aspect ran on.

    Returns:
        The library targets for plugins kept after Android federated resolution,
        deduplicated and sorted by label so the order does not depend on how the
        Dart graph is laid out.
    """
    kept, dropped = _android_plugin_resolution(application)
    by_label = {}
    for entry in application[_PluginAndroidLibsInfo].libs.to_list():
        if entry.package and entry.package in dropped:
            continue
        if entry.scc and not _scc_member_needs_android_lib(entry.lib, kept.get(entry.package)):
            continue
        by_label[str(entry.lib.label)] = entry.lib
    return [by_label[label] for label in sorted(by_label)]

def _append_optional_providers(providers, libs):
    """Appends resource, ProGuard, native, baseline-profile and validation providers from `libs`."""
    resources = _merge_resources_info([
        lib[StarlarkAndroidResourcesInfo]
        for lib in libs
        if StarlarkAndroidResourcesInfo in lib
    ])
    if resources:
        providers.append(resources)
    specs = [lib[ProguardSpecInfo].specs for lib in libs if ProguardSpecInfo in lib]
    if specs:
        providers.append(ProguardSpecInfo(depset(transitive = specs, order = "preorder")))
    native_libs = [lib[AndroidNativeLibsInfo].native_libs for lib in libs if AndroidNativeLibsInfo in lib]
    if native_libs:
        providers.append(AndroidNativeLibsInfo(native_libs = depset(transitive = native_libs, order = "preorder")))
    cc_params = _merge_native_cc_info(libs)
    if cc_params:
        providers.append(cc_params)
    profiles = [lib[BaselineProfileProvider].files for lib in libs if BaselineProfileProvider in lib]
    if profiles:
        providers.append(BaselineProfileProvider(files = depset(transitive = profiles)))
    output_groups = _merge_output_groups(libs)
    if output_groups:
        providers.append(output_groups)

def _resource_class_jars(libs):
    """Merged `AndroidLibraryResourceClassJarProvider` depset across `libs`."""
    return depset(
        transitive = [
            lib[AndroidLibraryResourceClassJarProvider].jars
            for lib in libs
            if AndroidLibraryResourceClassJarProvider in lib
        ],
        order = "preorder",
    )

def _flutter_android_plugin_closure_impl(ctx):
    """Forwards merged Java, resource, ProGuard and native providers for reached plugins."""
    if bool(ctx.attr.application) == bool(ctx.attr.closure):
        fail("Exactly one of `application` or `closure` must be set on %s." % ctx.label)
    if ctx.attr.application:
        libs = _plugin_android_libs(ctx.attr.application)
    else:
        libs = ctx.attr.closure[_PluginClosureInfo].libs
    java_infos = [lib[JavaInfo] for lib in libs if JavaInfo in lib]
    class_jars = _resource_class_jars(libs)
    extra_java = _runtime_java_infos(java_infos, class_jars, ctx.attr.already_dexed)
    providers = [
        DefaultInfo(),
        _PluginClosureInfo(libs = libs),
        java_common.merge(java_infos + extra_java),
        AndroidLibraryResourceClassJarProvider(jars = class_jars),
    ]
    _append_optional_providers(providers, libs)
    return providers

flutter_android_plugin_closure = rule(
    implementation = _flutter_android_plugin_closure_impl,
    cfg = android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "The Flutter application (or integration-test app) whose transitive Dart " +
                  "dependencies name the plugins to forward. Mutually exclusive with `closure`.",
            providers = [FlutterApplicationInfo],
            aspects = [_plugin_android_libs_aspect],
        ),
        "closure": attr.label(
            doc = "An existing `flutter_android_plugin_closure` target whose collected plugin " +
                  "libraries are reused while applying `already_dexed`.",
            providers = [_PluginClosureInfo],
        ),
        "already_dexed": attr.label_list(
            doc = "Targets already in the consuming `android_binary`'s `deps` in a matching " +
                  "configuration, whose runtime jars must not be dexed a second time.",
            default = [],
            providers = [JavaInfo],
        ),
        "android_abi": attr.string(
            doc = "Android ABI to transition `application` to (\"arm64-v8a\" or \"x86_64\"). " +
                  "Defaults to `\"\"`, which infers the ABI from the active platform or CPU.",
            default = "",
            values = [""] + ANDROID_ABIS.keys(),
        ),
        "constraints": attr.string_list(
            doc = "Java/Android target constraints read by `rules_android` aspects.",
            default = ["android"],
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Forwards the Android providers of the plugins in an app's transitive Dart dependencies.",
)

def declare_android_plugin_closure(name, application, android_abi, engine, tags, visibility = None):
    """Declares the per-app Android plugin closure and its deduplicated binary-deps view.

    `__<name>_android_plugins` collects the Android libraries reached from
    `application`'s Dart graph without pulling in `engine`, so action queries
    and compile-only consumers can analyze it without Android SDK toolchains
    when no plugin is reached. `__<name>_android_plugin_deps` filters out
    runtime jars already dexed through `engine` and the Kotlin standard library
    before feeding `android_binary`.

    Args:
        name: Outer app or integration-test target name.
        application: The `flutter_application` (or integration-test app) label.
        android_abi: Full Android ABI string (`"arm64-v8a"` or `"x86_64"`).
        engine: Transitioned `flutter_android_engine` label in `android_binary` `deps`.
        tags: Bazel tags applied to both helper targets.
        visibility: Optional visibility applied to both helper targets.
    """
    flutter_android_plugin_closure(
        name = "__%s_android_plugins" % name,
        application = application,
        android_abi = android_abi,
        tags = tags,
        visibility = visibility,
    )
    flutter_android_plugin_closure(
        name = "__%s_android_plugin_deps" % name,
        closure = ":__%s_android_plugins" % name,
        android_abi = android_abi,
        already_dexed = [
            engine,
            Label("@rules_kotlin//kotlin/compiler:kotlin-stdlib"),
        ],
        tags = tags,
        visibility = visibility,
    )

def _flutter_android_transitioned_library_impl(ctx):
    """Forwards merged Android and Java providers from `exports` in the transitioned ABI."""
    exports = ctx.attr.exports
    files = [lib[DefaultInfo].files for lib in exports]
    providers = [
        DefaultInfo(files = depset(transitive = files)),
        java_common.merge([lib[JavaInfo] for lib in exports if JavaInfo in lib]),
        AndroidLibraryResourceClassJarProvider(jars = _resource_class_jars(exports)),
    ]
    _append_optional_providers(providers, exports)
    return providers

flutter_android_transitioned_library = rule(
    implementation = _flutter_android_transitioned_library_impl,
    cfg = android_platform_transition,
    attrs = {
        "exports": attr.label_list(
            doc = "Android libraries to analyze under `android_abi` and re-export.",
            mandatory = True,
        ),
        "android_abi": attr.string(
            doc = "Android ABI to transition `exports` to (\"arm64-v8a\" or \"x86_64\"). " +
                  "Defaults to `\"\"`, which infers the ABI from the active platform or CPU.",
            default = "",
            values = [""] + ANDROID_ABIS.keys(),
        ),
        "constraints": attr.string_list(
            doc = "Java/Android target constraints read by `rules_android` aspects.",
            default = ["android"],
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exports Android libraries built in the Android platform configuration of `android_abi`.",
)

def declare_android_bundle_targets(
        name,
        application,
        full_abi,
        tags = None,
        visibility = None,
        analyze_size = False,
        java_import_fn = java_import):
    """Declares the shared bundle, native-libs `java_import` and transitioned engine targets.

    Expects `:__<name>_engine_raw` to be declared by the caller via
    `flutter_android_engine`, and wraps it into `:__<name>_engine` in the same
    Android ABI configuration as `declare_android_plugin_closure`.

    Args:
        name: Outer app or integration-test target name.
        application: The `flutter_application` (or integration-test app) label.
        full_abi: Full Android ABI string (`"arm64-v8a"` or `"x86_64"`).
        tags: Optional Bazel tags applied to all helper targets.
        visibility: Optional visibility applied to all helper targets.
        analyze_size: Whether to enable `analyze_size` and expose `__<name>_size_json`.
        java_import_fn: Rule used to wrap `native_libs.jar` as a Java library.
    """
    flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        android_abi = full_abi,
        analyze_size = analyze_size,
        tags = tags,
        visibility = visibility,
    )
    if analyze_size:
        native.filegroup(
            name = "__%s_size_json" % name,
            srcs = [":__%s_bundle" % name],
            output_group = "analyze_size",
            tags = tags,
            visibility = visibility,
        )
    native.filegroup(
        name = "__%s_native_libs_jar" % name,
        srcs = [":__%s_bundle" % name],
        output_group = "native_libs_jar",
        tags = tags,
        visibility = visibility,
    )
    java_import_fn(
        name = "__%s_native_libs" % name,
        jars = [":__%s_native_libs_jar" % name],
        tags = tags,
        visibility = visibility,
    )
    flutter_android_transitioned_library(
        name = "__%s_engine" % name,
        exports = [":__%s_engine_raw" % name],
        android_abi = full_abi,
        tags = tags,
        visibility = visibility,
    )
