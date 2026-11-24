"""Helpers for flutter_apple_plugin_library on the xtool backend."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load(
    "//flutter:providers.bzl",
    "FlutterApplePluginInfo",
    "FlutterDarwinFrameworkInfo",
)

visibility(["//flutter/..."])

def classify_plugin_srcs(files):
    """Split rule srcs into a struct of swift, objc and header Files plus include dirs.

    Args:
        files: List of File objects.

    Returns:
        struct(swift, objc, headers, include_dirs).
    """
    swift_files = []
    objc_files = []
    headers = []
    include_dirs = {}
    for f in files:
        if f.path.endswith(".swift"):
            swift_files.append(f)
        elif (
            f.path.endswith(".m") or
            f.path.endswith(".mm") or
            f.path.endswith(".c") or
            f.path.endswith(".cc") or
            f.path.endswith(".cpp")
        ):
            objc_files.append(f)
        elif f.path.endswith(".h"):
            headers.append(f)
            include_dirs[f.dirname] = True
    return struct(
        swift = swift_files,
        objc = objc_files,
        headers = headers,
        include_dirs = include_dirs,
    )

def plugin_include_dirs(package, includes, include_dirs):
    """Fold package-relative `includes` into the header-dir set from sources.

    Args:
        package: Package path string.
        includes: List of package-relative include paths.
        include_dirs: Dict of existing include dirs.

    Returns:
        The mutated `include_dirs` dict.
    """
    for inc in includes:
        if package:
            include_dirs["%s/%s" % (package, inc)] = True
        else:
            include_dirs[inc] = True
    return include_dirs

def write_plugin_modulemap(ctx, module_name, headers):
    """Write the plugin's modulemap covering its headers.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        module_name: Module name string.
        headers: List of header File objects.

    Returns:
        The declared modulemap File.
    """
    modulemap_file = ctx.actions.declare_file("%s.modulemap" % ctx.label.name)
    mm_lines = ["module %s {" % module_name]
    for h in headers:
        mm_lines.append('  header "%s"' % h.basename)
    mm_lines.append("  export *")
    mm_lines.append("}")
    ctx.actions.write(
        output = modulemap_file,
        content = "\n".join(mm_lines) + "\n",
    )
    return modulemap_file

def collect_plugin_dep_infos(ctx):
    """Collect CcInfo, SwiftInfo and framework infos from the plugin's deps.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        struct(cc_infos, swift_infos, framework_infos).
    """
    return struct(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep],
        swift_infos = [dep[SwiftInfo] for dep in ctx.attr.deps if SwiftInfo in dep],
        framework_infos = depset(
            direct = [
                dep[FlutterDarwinFrameworkInfo]
                for dep in ctx.attr.deps
                if FlutterDarwinFrameworkInfo in dep and not dep.label.name.endswith("__flutter_framework")
            ],
            transitive = [
                dep[FlutterApplePluginInfo].framework_infos
                for dep in ctx.attr.deps
                if FlutterApplePluginInfo in dep and getattr(dep[FlutterApplePluginInfo], "framework_infos", None) != None
            ],
        ),
    )

def merge_plugin_sdk_lists(ctx, sdk_frameworks, sdk_dylibs):
    """Union the rule's SDK frameworks/dylibs with the ones plugin deps declare.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        sdk_frameworks: List of SDK frameworks.
        sdk_dylibs: List of SDK dylibs.

    Returns:
        (frameworks, dylibs) tuple.
    """
    frameworks = list(sdk_frameworks)
    dylibs = list(sdk_dylibs)
    for dep in ctx.attr.deps:
        if FlutterApplePluginInfo in dep:
            for fw in dep[FlutterApplePluginInfo].sdk_frameworks:
                if fw not in frameworks:
                    frameworks.append(fw)
            for dylib in dep[FlutterApplePluginInfo].sdk_dylibs:
                if dylib not in dylibs:
                    dylibs.append(dylib)
    return frameworks, dylibs

def objc_copts_xtool_refusal(name):
    """The message for `objc_copts` on the `xtool` backend, naming the plugin target.

    Args:
        name: Label name of the plugin target, included in the message so users can find it.

    Returns:
        The refusal message string for the caller to pass to `fail()`.
    """
    return (
        "flutter_apple_plugin_library: %s: objc_copts is not supported on the xtool backend; " % name +
        "the backend compiles every source in one swiftc invocation, so there is no " +
        "separate ObjC compile to pass them to"
    )

def plugin_defines_xtool_refusal(name):
    """The message for `plugin_defines` on the `xtool` backend, naming the plugin target.

    Args:
        name: Label name of the plugin target, included in the message so users can find it.

    Returns:
        The refusal message string for the caller to pass to `fail()`.
    """
    return (
        "flutter_apple_plugin_library: %s: plugin_defines is not supported on the xtool backend; " % name +
        "it compiles every source in one swiftc invocation with no define flags. " +
        "Remove flutter.pub(ios_plugin_defines = ...), or build with backend = \"rules_apple\"."
    )

def weak_sdk_frameworks_xtool_refusal(name):
    """The message for `weak_sdk_frameworks` on the `xtool` backend, naming the plugin target.

    Args:
        name: Label name of the plugin target, included in the message so users can find it.

    Returns:
        The refusal message string for the caller to pass to `fail()`.
    """
    return (
        "flutter_apple_plugin_library: %s: weak_sdk_frameworks is not supported on the xtool backend; " % name +
        "the backend compiles every source in one swiftc invocation with no weak framework flags. " +
        "Build with backend = \"rules_apple\"."
    )

def _flutter_xtool_apple_plugin_library_impl(ctx):
    """Build CcInfo, SwiftInfo, and FlutterApplePluginInfo for the xtool backend."""
    if ctx.attr.plugin_defines:
        fail(plugin_defines_xtool_refusal(ctx.label.name))
    if ctx.attr.weak_sdk_frameworks:
        fail(weak_sdk_frameworks_xtool_refusal(ctx.label.name))
    srcs = classify_plugin_srcs(ctx.files.srcs)
    include_dirs = plugin_include_dirs(ctx.label.package, ctx.attr.includes, srcs.include_dirs)

    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    modulemap_file = write_plugin_modulemap(ctx, module_name, srcs.headers)

    all_plugin_files = srcs.swift + srcs.objc + srcs.headers + [modulemap_file]
    own_cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(all_plugin_files),
            direct_public_headers = srcs.headers,
            direct_textual_headers = srcs.swift + srcs.objc + [modulemap_file],
            includes = depset(include_dirs.keys()),
        ),
    )
    dep_infos = collect_plugin_dep_infos(ctx)
    merged_cc_info = cc_common.merge_cc_infos(
        direct_cc_infos = [own_cc_info],
        cc_infos = dep_infos.cc_infos,
    )
    sdk_frameworks, sdk_dylibs = merge_plugin_sdk_lists(ctx, ctx.attr.sdk_frameworks, ctx.attr.sdk_dylibs)

    return [
        DefaultInfo(files = depset(all_plugin_files)),
        merged_cc_info,
        SwiftInfo(swift_infos = dep_infos.swift_infos),
        FlutterApplePluginInfo(
            module_name = module_name,
            platform = ctx.attr.platform,
            swift_srcs = depset(srcs.swift),
            objc_srcs = depset(srcs.objc),
            headers = depset(srcs.headers),
            modulemap = modulemap_file,
            sdk_frameworks = tuple(sdk_frameworks),
            weak_sdk_frameworks = (),
            sdk_dylibs = tuple(sdk_dylibs),
            framework_infos = dep_infos.framework_infos,
        ),
    ]

flutter_xtool_apple_plugin_library = rule(
    implementation = _flutter_xtool_apple_plugin_library_impl,
    attrs = {
        "deps": attr.label_list(
            default = [],
            doc = "Dependencies providing CcInfo or SwiftInfo.",
        ),
        "includes": attr.string_list(
            default = [],
            doc = "Header search paths relative to the package.",
        ),
        "module_name": attr.string(
            default = "",
            doc = "Module name for the plugin.",
        ),
        "platform": attr.string(
            default = "macos",
            doc = "Target Apple platform ('ios' or 'macos').",
            values = ["macos", "ios"],
        ),
        "plugin_defines": attr.string_list(
            default = [],
            doc = "Preprocessor defines for the plugin's Apple libraries. " +
                  "The xtool backend refuses a non-empty list because it " +
                  "compiles every source in one swiftc invocation with no " +
                  "define flags.",
        ),
        "sdk_dylibs": attr.string_list(
            default = [],
            doc = "Apple SDK dynamic libraries to link.",
        ),
        "sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK frameworks to link.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Swift, Objective-C, and header source files for the plugin.",
        ),
        "weak_sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK weak frameworks to link. Refused on xtool backend.",
        ),
    },
    provides = [
        DefaultInfo,
        CcInfo,
        SwiftInfo,
        FlutterApplePluginInfo,
    ],
    doc = "Host-agnostic Apple plugin library rule for the xtool backend.",
)

def _swift_generated_header_include_impl(ctx):
    """Publish the generated header's directory as a quote include path."""
    headers = [
        header
        for header in ctx.attr.swift[CcInfo].compilation_context.direct_public_headers
        if header.basename == ctx.attr.header_name
    ]
    if len(headers) != 1:
        fail(
            "flutter_apple_plugin_library: expected exactly one generated header %s on %s, got %s" % (
                ctx.attr.header_name,
                ctx.attr.swift.label,
                [header.path for header in headers],
            ),
        )
    return [CcInfo(
        compilation_context = cc_common.create_compilation_context(
            quote_includes = depset([headers[0].dirname]),
        ),
    )]

_swift_generated_header_include = rule(
    implementation = _swift_generated_header_include_impl,
    attrs = {
        "header_name": attr.string(
            mandatory = True,
            doc = "Basename of the Swift module's generated Objective-C header.",
        ),
        "swift": attr.label(
            mandatory = True,
            providers = [CcInfo],
            doc = "The `swift_library` whose generated header the ObjC sources import.",
        ),
    },
    doc = "Adds the directory of a Swift module's generated header to the quote " +
          "include path, so ObjC sources import it by its plain basename.",
)

def emit_plugin_swift_header_include_target(spec, swift_target, name = None):
    """Emit the target that makes `<module_name>-Swift.h` findable by basename.

    Args:
        spec: Plugin spec struct.
        swift_target: Target label string for the Swift library.
        name: Optional target name override.

    Returns:
        The emitted target label string.
    """
    target = name or ("_%s__swift_include" % spec.name)
    _swift_generated_header_include(
        name = target,
        header_name = "%s-Swift.h" % spec.module_name,
        swift = swift_target,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target
