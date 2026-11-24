"""Compile a Flutter plugin's Apple sources into a swift_library or xtool plugin library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep on the `rules_apple` backend,
and selects a host-agnostic `flutter_xtool_apple_plugin_library` on the
`xtool` backend so Linux -> iOS/macOS cross-builds do not require an
Apple host `@rules_swift` toolchain.

Public Tier-2 API: re-exported from `flutter/macos.bzl` and
`flutter/ios.bzl` so users can wire a monorepo plugin's BUILD.bazel
without going through the `ext/` overlay system.

Usage:

    flutter_apple_plugin_library(
        name = "my_plugin_apple_macos",
        srcs = glob(["macos/Classes/**/*.swift"]),
        module_name = "my_plugin",
        platform = "macos",
    )
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter:providers.bzl", _FlutterApplePluginInfo = "FlutterApplePluginInfo")
load(":flutter_apple_framework_modulemap.bzl", "apple_framework_modulemap_import")
load(
    ":flutter_apple_plugin_defines.bzl",
    "plugin_objc_copts",
    "plugin_swift_copts",
)
load(
    ":flutter_apple_plugin_headers.bzl",
    "emit_plugin_private_header_dirs",
    "plugin_header_layout",
)
load(
    ":flutter_apple_plugin_library_helpers.bzl",
    _emit_plugin_swift_header_include_target = "emit_plugin_swift_header_include_target",
    _flutter_xtool_apple_plugin_library = "flutter_xtool_apple_plugin_library",
    _objc_copts_xtool_refusal = "objc_copts_xtool_refusal",
    _plugin_defines_xtool_refusal = "plugin_defines_xtool_refusal",
    _weak_sdk_frameworks_xtool_refusal = "weak_sdk_frameworks_xtool_refusal",
)
load(":flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugin_bundle = "flutter_apple_plugin_bundle")
load(":flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import")

visibility(["//flutter/..."])

FlutterApplePluginInfo = _FlutterApplePluginInfo
flutter_xtool_apple_plugin_library = _flutter_xtool_apple_plugin_library
objc_copts_xtool_refusal = _objc_copts_xtool_refusal
plugin_defines_xtool_refusal = _plugin_defines_xtool_refusal
weak_sdk_frameworks_xtool_refusal = _weak_sdk_frameworks_xtool_refusal

def _sdk_link_opts(frameworks, weak_frameworks, dylibs):
    """Link options naming SDK frameworks, weak frameworks and dylibs, in that order.

    `objc_library` refuses `sdk_frameworks`, `weak_sdk_frameworks` and
    `sdk_dylibs` under `--incompatible_disallow_sdk_frameworks_attributes`;
    the same names reach the final link as `linkopts`.

    Args:
        frameworks: Framework names, each linked as `-framework <name>`.
        weak_frameworks: Framework names, each linked as `-weak_framework <name>`.
        dylibs: Dylib names, each linked as `-l<name>`.

    Returns:
        The link option list.
    """
    opts = [o for fw in frameworks for o in ["-framework", fw]]
    opts += [o for fw in weak_frameworks for o in ["-weak_framework", fw]]
    return opts + ["-l" + dylib for dylib in dylibs]

def _split_srcs(srcs):
    """Split srcs into (swift_files, objc_files, headers).

    Returns lists by extension so we can route ObjC through objc_library
    while keeping Swift on swift_library.
    """
    swift_files = []
    objc_files = []
    headers = []
    for f in srcs:
        if f.endswith(".swift"):
            swift_files.append(f)
        elif f.endswith(".m") or f.endswith(".mm"):
            objc_files.append(f)
        elif f.endswith(".h"):
            headers.append(f)
    return swift_files, objc_files, headers

def _apple_plugin_engine_imports(platform, engine):
    """The Flutter framework import labels for an Apple plugin platform."""
    if platform == "macos":
        return [engine] if engine else [Label("@flutter_macos_engine//:engine_library")]
    return [engine] if engine else [Label("@flutter_ios_engine//:Flutter_xcframework")]

def _emit_xtool_plugin_branch(spec):
    """Emit the framework import and host-agnostic plugin target on the `xtool` backend."""
    flutter_darwin_xcframework_import(
        name = spec.framework_target,
        framework_name = "FlutterMacOS" if spec.platform == "macos" else "Flutter",
        xcframework_imports = spec.engine_imports,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    flutter_xtool_apple_plugin_library(
        name = spec.name,
        srcs = spec.srcs,
        module_name = spec.module_name,
        platform = spec.platform,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        weak_sdk_frameworks = spec.weak_sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        deps = [spec.framework_dep] + spec.deps,
        plugin_defines = spec.plugin_defines,
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
    )

def _emit_apple_engine_framework(name, platform, imports, visibility):
    """Emit the engine import `name` + "_raw" and its module-map wrapper `name`."""

    # The wrapper puts `Modules/module.modulemap` into `CcInfo` headers so
    # `@import Flutter;` resolves in a sandboxed compile.
    compatible = ["@platforms//os:%s" % platform]
    macos = platform == "macos"
    (apple_dynamic_framework_import if macos else apple_dynamic_xcframework_import)(
        name = name + "_raw",
        tags = ["manual"],
        target_compatible_with = compatible,
        visibility = ["//visibility:private"],
        **{"framework_imports" if macos else "xcframework_imports": imports}
    )
    apple_framework_modulemap_import(
        name = name,
        dep = ":" + name + "_raw",
        tags = ["manual"],
        target_compatible_with = compatible,
        visibility = visibility,
    )

def apple_engine_framework_targets(name):
    """Declare the `<name>_ios` and `<name>_macos` engine wrappers every Apple plugin shares."""
    for platform in ("ios", "macos"):
        _emit_apple_engine_framework(
            "%s_%s" % (name, platform),
            platform,
            _apple_plugin_engine_imports(platform, None),
            ["//visibility:public"],
        )

def _engine_framework_dep(platform, engine):
    """The shared wrapper label for `platform`; an `engine` override gets one per package and label."""
    if engine == None:
        return str(Label("//flutter/private:apple_engine_framework_" + platform))
    name = "_flutter_framework_" + "".join([c if c.isalnum() else "_" for c in str(engine).elems()])
    if not native.existing_rule(name):
        _emit_apple_engine_framework(name, platform, [engine], ["//visibility:private"])
    return ":" + name

def _emit_plugin_objc_target(spec, objc_files, layout):
    """Emit the inner `objc_library`; return `(objc_module_name, dep_label_or_None)`."""
    if not objc_files:
        return "", None
    objc_target = "_%s__objc" % spec.name
    objc_module_name = "%s_objc" % spec.module_name
    objc_library(
        name = objc_target,
        srcs = objc_files + layout.private,
        hdrs = layout.public,
        includes = spec.includes,
        linkopts = _sdk_link_opts(spec.sdk_frameworks, spec.weak_sdk_frameworks, spec.sdk_dylibs),
        module_name = objc_module_name,
        enable_modules = True,
        copts = plugin_objc_copts(spec.copts, spec.objc_copts, spec.plugin_defines),
        deps = [spec.framework_dep] + list(spec.deps),
        implementation_deps = emit_plugin_private_header_dirs(spec, layout.search),
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return objc_module_name, ":" + objc_target

def _emit_plugin_objc_module_target(spec, headers):
    """Emit the headers-only ObjC module the Swift half imports.

    The module carries the plugin's public headers under
    `<module_name>_objc`, so Swift can `import "<module_name>_objc"` without
    depending on the implementation library that needs the Swift header.
    """
    target = "_%s__objc_module" % spec.name
    objc_library(
        name = target,
        hdrs = headers,
        includes = spec.includes,
        module_name = "%s_objc" % spec.module_name,
        enable_modules = True,
        deps = [spec.framework_dep],
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target

def _emit_plugin_mixed_objc_target(spec, objc_files, layout, swift_deps):
    """Emit the ObjC half of a mixed plugin; it depends on the Swift module.

    Depending on the Swift library makes `<module_name>-Swift.h` a declared
    input of every ObjC compile; the companion include target contributes the
    header's directory as a quote include path, so
    `#import "<module_name>-Swift.h"` resolves by its basename from a source
    `.m`/`.mm` file. The implementation library deliberately has no Clang
    module of its own: `<module_name>_objc` names the headers-only module the
    Swift half imports, and two targets cannot publish the same module name.
    """
    target = "_%s__objc" % spec.name
    objc_library(
        name = target,
        srcs = objc_files + layout.private,
        hdrs = layout.public,
        includes = spec.includes,
        linkopts = _sdk_link_opts(spec.sdk_frameworks, spec.weak_sdk_frameworks, spec.sdk_dylibs),
        enable_modules = True,
        copts = plugin_objc_copts(spec.copts, spec.objc_copts, spec.plugin_defines),
        deps = [spec.framework_dep] + swift_deps,
        implementation_deps = emit_plugin_private_header_dirs(spec, layout.search),
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target

def _plugin_bridging_copts(spec, headers):
    """Find the `<module>-Bridging-Header.h` and return `(header_or_None, copts)`.

    A found header also gets the Clang includes a CocoaPods prefix header
    supplies: `Foundation/Foundation.h`, then `UIKit/UIKit.h` on iOS or
    `AppKit/AppKit.h` on macOS, so a plugin header that names `NSObject` or a
    view class without importing the framework still parses. A plugin with no
    bridging header gets its own copts unchanged.
    """
    extra_copts = plugin_swift_copts(spec.copts, spec.plugin_defines)
    for h in headers:
        if h.endswith("%s-Bridging-Header.h" % spec.module_name):
            if spec.platform == "ios":
                framework_header = "UIKit/UIKit.h"
            elif spec.platform == "macos":
                framework_header = "AppKit/AppKit.h"
            else:
                fail(
                    "flutter_apple_plugin_library: platform must be 'ios' or 'macos', got '%s'" % spec.platform,
                )
            extra_copts = extra_copts + [
                "-Xcc",
                "-include",
                "-Xcc",
                "Foundation/Foundation.h",
                "-Xcc",
                "-include",
                "-Xcc",
                framework_header,
                "-import-objc-header",
                "$(execpath %s)" % h,
            ]
            return h, extra_copts
    return None, extra_copts

def _plugin_swift_srcs(spec, swift_files, objc_module_name):
    """Return the swift_library srcs, emitting a re-export placeholder when empty."""
    if swift_files:
        return swift_files
    placeholder_target = "_%s__swift_placeholder" % spec.name
    placeholder_file = "_%s__placeholder.swift" % spec.name
    placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % spec.module_name]
    if objc_module_name:
        placeholder_content.append("@_exported import %s" % objc_module_name)
    write_file(
        name = placeholder_target,
        out = placeholder_file,
        content = placeholder_content,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
    )
    return [":" + placeholder_target]

def _emit_plugin_swift_target(
        spec,
        target_name,
        swift_files,
        deps,
        extra_copts,
        bridging_header,
        generates_header,
        kwargs):
    """Emit a plugin `swift_library`, optionally publishing its ObjC header.

    Args:
        spec: The plugin's struct of shared attributes.
        target_name: Name for the `swift_library`.
        swift_files: Swift source files (or the placeholder target).
        deps: Labels the Swift compile depends on.
        extra_copts: The plugin's copts plus any bridging-header flags.
        bridging_header: The `<module>-Bridging-Header.h`, or `None`.
        generates_header: Whether to publish `<module_name>-Swift.h`.
        kwargs: Extra attributes forwarded from the public macro.
    """
    swift_kwargs = dict(kwargs)
    if generates_header:
        swift_kwargs["generates_header"] = True
        swift_kwargs["generated_header_name"] = "%s-Swift.h" % spec.module_name

    swift_library(
        name = target_name,
        srcs = swift_files,
        module_name = spec.module_name,
        copts = extra_copts,
        deps = deps,
        swiftc_inputs = [bridging_header] if bridging_header else [],
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
        **swift_kwargs
    )

def _emit_plugin_bundle_target(spec, deps, swift_files, objc_files, headers):
    """Emit the public target that merges the Swift and ObjC halves."""
    _flutter_apple_plugin_bundle(
        name = spec.name,
        deps = deps,
        module_name = spec.module_name,
        platform = spec.platform,
        swift_srcs = swift_files,
        objc_srcs = objc_files,
        headers = headers,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
    )

def _emit_mixed_plugin(spec, swift_files, objc_files, layout, kwargs):
    """Emit the two-layer ObjC/Swift build for a plugin with both halves."""
    objc_module = _emit_plugin_objc_module_target(spec, layout.public)
    bridging_header, extra_copts = _plugin_bridging_copts(spec, layout.all)

    swift_target = "_%s__swift" % spec.name
    swift_deps = [spec.framework_dep, objc_module] + list(spec.deps)
    _emit_plugin_swift_target(
        spec,
        swift_target,
        swift_files,
        swift_deps,
        extra_copts,
        bridging_header,
        True,
        kwargs,
    )

    swift_include = _emit_plugin_swift_header_include_target(spec, ":" + swift_target)
    objc_target = _emit_plugin_mixed_objc_target(
        spec,
        objc_files,
        layout,
        [":" + swift_target, swift_include],
    )
    _emit_plugin_bundle_target(spec, [":" + swift_target, objc_target], swift_files, objc_files, layout.public)

def flutter_apple_plugin_objc_settings(
        includes = [],
        copts = [],
        cxxopts = [],
        linkopts = [],
        private_includes = [],
        sdk_frameworks = [],
        weak_sdk_frameworks = [],
        sdk_dylibs = []):
    """Assemble the translated settings of one ObjC-only local library.

    BUILD files cannot spell `struct(...)` directly, so the generated
    spoke calls this helper to pass the settings as one parameter object.

    Args:
        includes: Public header search directories.
        copts: Target-local C-family compile options from `cSettings`; their
            `.define` entries reach `.c`, `.m` and `.mm` compiles alike.
        cxxopts: C++ compile options (`cxxopts`).
        linkopts: Link options from `linkerSettings`.
        private_includes: Target-local `.headerSearchPath` directories.
        sdk_frameworks: Apple SDK frameworks to link and report.
        weak_sdk_frameworks: Apple SDK weak frameworks to link and report.
        sdk_dylibs: Apple SDK dynamic libraries to link and report.

    Returns:
        The settings struct `flutter_apple_plugin_objc_library` takes.
    """
    return struct(
        includes = includes,
        copts = copts,
        cxxopts = cxxopts,
        linkopts = linkopts,
        private_includes = private_includes,
        sdk_frameworks = sdk_frameworks,
        weak_sdk_frameworks = weak_sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
    )

def flutter_apple_plugin_objc_library(
        name,
        srcs = [],
        hdrs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        settings = None,
        plugin_defines = [],
        visibility = None):
    """Build a plugin-local C-family target as an ObjC-only library.

    The inner `objc_library` carries `module_name`, the Flutter framework
    import, and the target's translated settings (public includes,
    `copts` from `cSettings`, `cxxopts` from `cxxSettings`, `linkopts`
    from `linkerSettings`, and target-local `.headerSearchPath`
    directories). The named target forwards CcInfo/SwiftInfo and exposes
    `FlutterApplePluginInfo`, so the aggregator and
    `flutter_plugin(apple_libs = ...)` accept it exactly like a Swift
    local target.

    Args:
        name: Target name. Pass to the primary library's `deps`.
        srcs: Compilable C-family sources plus private headers.
        hdrs: Public headers exposed to dependents of the inner `objc_library`.
        module_name: The target's `c99name`, used as the clang module.
        platform: `"macos"` or `"ios"`. Picks the Flutter framework dep.
        deps: Same-package local libraries this target depends on.
        settings: `struct(includes, copts, cxxopts, linkopts,
            private_includes, sdk_frameworks, weak_sdk_frameworks,
            sdk_dylibs)` of translated target settings.
        plugin_defines: Preprocessor defines for that plugin's Apple
            libraries, each `NAME` or `NAME=VALUE`, appended to `copts`
            after the target's own settings so they stay target-local.
        visibility: Visibility of the named target; the inner library stays private to the package.
    """
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_objc_library: platform must be 'macos' or 'ios', got '%s'" % platform)
    if module_name == None:
        module_name = name
    if settings == None:
        settings = flutter_apple_plugin_objc_settings()
    target_compatible_with = ["@platforms//os:%s" % platform]
    objc_deps = [_engine_framework_dep(platform, None)] + deps
    private_target = "_%s__private_headers" % name
    implementation_deps = []
    private_includes = settings.private_includes
    if type(private_includes) != "list" or private_includes:
        objc_library(
            name = private_target,
            includes = private_includes,
            tags = ["manual"],
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        implementation_deps.append(":" + private_target)
    objc_library(
        name = "_%s__objc" % name,
        srcs = srcs,
        hdrs = hdrs,
        includes = settings.includes,
        copts = plugin_objc_copts(getattr(settings, "copts", []), [], plugin_defines),
        cxxopts = settings.cxxopts,
        linkopts = settings.linkopts + _sdk_link_opts(
            settings.sdk_frameworks,
            getattr(settings, "weak_sdk_frameworks", []),
            settings.sdk_dylibs,
        ),
        module_name = module_name,
        enable_modules = True,
        deps = objc_deps,
        implementation_deps = implementation_deps,
        tags = ["manual"],
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:private"],
    )
    _flutter_apple_plugin_bundle(
        name = name,
        clang_module_deps = [":_%s__objc" % name],
        module_name = module_name,
        platform = platform,
        swift_srcs = [],
        objc_srcs = srcs,
        headers = hdrs,
        sdk_frameworks = settings.sdk_frameworks,
        sdk_dylibs = settings.sdk_dylibs,
        tags = ["manual"],
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

def _validate_plugin_args(name, platform, backend, objc_copts):
    """Validate platform, backend, and macro-only argument compatibility."""
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_library: platform must be 'macos' or 'ios', got '%s'" % platform)
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_apple_plugin_library: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    if backend == "xtool" and objc_copts:
        fail(objc_copts_xtool_refusal(name))

def _with_pure_swift_linkopts(spec, extra_attrs):
    """Return a copy of `extra_attrs` adding SDK framework and dylib linkopts."""
    swift_linkopts = _sdk_link_opts(spec.sdk_frameworks, spec.weak_sdk_frameworks, spec.sdk_dylibs)
    out = dict(extra_attrs)
    if swift_linkopts:
        if "linkopts" in out:
            prev = out["linkopts"]
            out["linkopts"] = (list(prev) if type(prev) == "list" else prev) + swift_linkopts
        else:
            out["linkopts"] = swift_linkopts
    return out

def _emit_rules_apple_plugin(spec, extra_attrs):
    """Emit the `rules_apple` target graph for a plugin library."""
    swift_files, objc_files, headers = _split_srcs(spec.srcs)
    layout = plugin_header_layout(headers, objc_files, spec.includes)

    if swift_files and objc_files:
        _emit_mixed_plugin(spec, swift_files, objc_files, layout, extra_attrs)
        return

    swift_deps = [spec.framework_dep] + spec.deps

    objc_module_name, objc_dep = _emit_plugin_objc_target(spec, objc_files, layout)
    if objc_dep:
        if type(swift_deps) == "list":
            swift_deps.append(objc_dep)
        else:
            swift_deps = swift_deps + [objc_dep]

    bridging_header, extra_copts = _plugin_bridging_copts(spec, layout.all)

    # A header-less ObjC target gets no clang module, so there is nothing to re-export.
    swift_files = _plugin_swift_srcs(spec, swift_files, objc_module_name if layout.public else "")

    swift_attrs = _with_pure_swift_linkopts(spec, extra_attrs) if not objc_files else extra_attrs

    _emit_plugin_swift_target(
        spec,
        spec.name,
        swift_files,
        swift_deps,
        extra_copts,
        bridging_header,
        False,
        swift_attrs,
    )

def flutter_apple_plugin_library(
        name,
        srcs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        copts = [],
        objc_copts = [],
        plugin_defines = [],
        includes = [],
        sdk_frameworks = [],
        weak_sdk_frameworks = [],
        sdk_dylibs = [],
        engine = None,
        backend = "rules_apple",
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library.

    Auto-routes `.m`/`.mm` files through an internal `objc_library` and
    feeds it into the `swift_library` as a dep.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, ObjC, and header source files.
        module_name: Swift module name. Defaults to `name`.
        platform: `"macos"` or `"ios"`. Picks the Flutter framework dep.
        deps: Additional swift_library / cc_library deps (other plugins), also
            given to the inner `objc_library` so its sources see their public
            headers and modules.
        copts: Additional Swift compile options, also passed to the inner
            `objc_library` as today.
        objc_copts: C and ObjC compile options for the inner `objc_library`
            only, appended after `copts`. They never reach the `swift_library`.
            The `xtool` backend refuses a non-empty list, because it has no
            separate ObjC compile.
        plugin_defines: Preprocessor defines for that plugin's Apple
            libraries, each `NAME` or `NAME=VALUE`. Every entry reaches the
            C-family compile as `-D<entry>`; only a value-less `NAME` reaches
            the Swift compile, as `-D<NAME>`, because a Swift condition has no
            value. The `xtool` backend refuses a non-empty list.
        includes: Header search paths forwarded to the inner `objc_library`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`).
        weak_sdk_frameworks: Apple SDK weak frameworks to link (e.g. `["MetricKit"]`).
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`).
        engine: Optional override for the Flutter engine framework label.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        visibility: Visibility of the generated target; defaults to the package default.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    _validate_plugin_args(name, platform, backend, objc_copts)

    if tags == None:
        tags = ["manual"]
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    if module_name == None:
        module_name = name

    target_compatible_with = kwargs.pop(
        "target_compatible_with",
        ["@platforms//os:%s" % platform],
    )

    xtool = backend == "xtool"
    framework_dep = ":_%s__flutter_framework" % name if xtool else _engine_framework_dep(platform, engine)
    spec = struct(
        name = name,
        srcs = srcs,
        module_name = module_name,
        platform = platform,
        deps = deps,
        copts = copts,
        objc_copts = objc_copts,
        plugin_defines = plugin_defines,
        includes = includes,
        sdk_frameworks = sdk_frameworks,
        weak_sdk_frameworks = weak_sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        engine_imports = _apple_plugin_engine_imports(platform, engine),
        framework_target = "_%s__flutter_framework" % name,
        framework_dep = framework_dep,
        internal_tags = internal_tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        tags = tags,
    )

    if xtool:
        _emit_xtool_plugin_branch(spec)
    else:
        _emit_rules_apple_plugin(spec, kwargs)
