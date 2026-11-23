"""Apple plugin spoke parts of the `flutter pub get` analog.

Hosts the Apple half of `flutter_pub_package.bzl`'s spoke generator: source
and privacy-manifest detection for the SwiftPM (`ios/<pkg>/`,
`macos/<pkg>/`, `darwin/<pkg>`) and legacy (`<platform>/Classes`,
`darwin/Classes`) layouts, the `flutter_apple_plugin_library` pair renderer,
the `apple_libs` / `apple_privacy_files` selects and the
extra-loads/extra-targets joiners for the `flutter_plugin` template, and the
SwiftPM product links a plugin's `Package.swift` declares. Split out of
`flutter_pub_package.bzl` so that file stays under the god-file limit;
`flutter_pub_package.bzl` loads the pieces its pipeline still needs.
"""

load(
    ":flutter_pub_apple_byname.bzl",
    "apple_swiftpm_declares_package",
    "apple_swiftpm_names_product",
    "apple_swiftpm_resolve_byname",
)
load(
    ":flutter_pub_apple_deps.bzl",
    _apple_swiftpm_synthetic_manifest = "apple_swiftpm_synthetic_manifest",
    _select_apple_swiftpm_deps = "select_apple_swiftpm_deps",
)
load(":flutter_pub_apple_pods.bzl", "detect_apple_cocoapods_deps")
load(":flutter_pub_plugin_deps.bzl", "mapped_apple_plugin_deps")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_under_walk")
load(":podspec_read.bzl", "detect_apple_podspecs")
load(":starlark_literal.bzl", "starlark_string_literal")
load(":swiftpm_manifest.bzl", "parse_swiftpm_plugin_package")
load(":swiftpm_paths.bzl", "swiftpm_normalize_relative_path")
load(":swiftpm_resolved.bzl", "read_ios_native_deps", "read_swiftpm_checksums", "read_swiftpm_pins", "swiftpm_unpinned_errors")
load(":swiftpm_translate.bzl", "swiftpm_locate_package_dep")

visibility(["//flutter/..."])

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

def _ctx_has_files_readdir(ctx, relative_path):
    """A `has_files_under_walk` reader over one spoke directory via `ctx.path`.

    Args:
        ctx: The spoke's repository context.
        relative_path: The package-relative directory the walk is rooted at.

    Returns:
        A `readdir` callable as `has_files_under_walk` takes it: a missing
        directory reads as empty, matching the walk's old skip.
    """

    def readdir(rel_dir):
        """The immediate children of `relative_path/rel_dir`."""
        full = relative_path if rel_dir == "" else relative_path + "/" + rel_dir
        node = ctx.path(full)
        if not node.exists:
            return []
        return [struct(name = child.basename, is_dir = child.is_dir) for child in node.readdir()]

    return readdir

def has_files_under(ctx, relative_path, extensions = None, package_name = "", bound = PUB_WALK_BOUND):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions` (any file when `extensions` is None).
    `ctx.path(p).readdir()` is the documented repo-rule way to walk a
    directory; recursing in Starlark keeps the logic local instead of
    forking out to `find`. The walk shares the pub spoke bound
    (`PUB_WALK_BOUND`): reaching it with directories unvisited fails the
    fetch naming the package, the directory, and the bound, instead of
    silently reporting no sources from a half-walked tree.

    Args:
        ctx: The spoke's repository context.
        relative_path: The package-relative directory to sweep.
        extensions: File extensions to match, or None for any file.
        package_name: The pub package name, for walk error messages.
        bound: The maximum directories the shared walk visits.

    Returns:
        True when the directory holds at least one matching file.
    """
    root = ctx.path(relative_path)
    if not root.exists:
        return False
    found = has_files_under_walk(
        _ctx_has_files_readdir(ctx, relative_path),
        "",
        package_name,
        extensions,
        bound,
    )
    if found.error:
        fail(found.error)
    return found.found

def _detect_apple_source_dirs(ctx, package_name, platform, shared_darwin_source):
    """List Apple source directory globs for the given platform.

    Returns the relative-to-package-root directories that contain Apple
    sources for `platform`. Empty list when no sources are detected.
    """
    candidates = []

    # Modern SwiftPM layout: <platform>/<pkg>/Sources/<pkg>/...
    swiftpm_dir = "{plat}/{pkg}/Sources/{pkg}".format(plat = platform, pkg = package_name)
    if has_files_under(ctx, swiftpm_dir, _APPLE_SRC_EXTENSIONS, package_name):
        candidates.append(swiftpm_dir)

    # Shared darwin source layout: darwin/Classes/...
    if shared_darwin_source:
        darwin_dir = "darwin/Classes"
        if has_files_under(ctx, darwin_dir, _APPLE_SRC_EXTENSIONS, package_name):
            candidates.append(darwin_dir)

        # Legacy darwin SwiftPM (older path_provider_foundation versions).
        darwin_swiftpm_dir = "darwin/{pkg}/Sources/{pkg}".format(pkg = package_name)
        if has_files_under(ctx, darwin_swiftpm_dir, _APPLE_SRC_EXTENSIONS, package_name):
            candidates.append(darwin_swiftpm_dir)

    # Legacy split layout: <platform>/Classes/...
    legacy_dir = "{plat}/Classes".format(plat = platform)
    if has_files_under(ctx, legacy_dir, _APPLE_SRC_EXTENSIONS, package_name):
        candidates.append(legacy_dir)

    return candidates

def _detect_apple_include_dirs(ctx, source_dirs, package_name):
    """Collect SwiftPM-canonical public-header directories for the given Apple sources.

    SwiftPM's `publicHeadersPath: "include"` (the default) places public
    headers at `Sources/<Target>/include/[<Module>/]Foo.h` and adds the
    `include` directory to the lib's own header search path. Plugins
    relying on this convention `#import "Foo.h"` (bare basename) from
    sibling `.m` files; without an explicit `-I` flag clang can't find
    the header. Mirror SwiftPM by adding both `include` and the
    `include/<pkg>` nested subdirectory (when present) — covers
    headers placed directly under `include/` and the more common
    umbrella-style layout.
    """
    include_dirs = []
    for src_dir in source_dirs:
        include_root = src_dir + "/include"
        include_root_path = ctx.path(include_root)
        if include_root_path.exists:
            include_dirs.append(include_root)
            nested = include_root + "/" + package_name
            if ctx.path(nested).exists:
                include_dirs.append(nested)
    return include_dirs

def glob_block(srcs_dirs, extensions):
    """Format a `glob([...])` expression covering the given extensions.

    Each directory in `srcs_dirs` is recursively swept for files matching
    any extension in `extensions`. `test/` and `example/` subtrees are
    excluded — pub plugins routinely ship integration tests next to
    their plugin source, but those should never be linked into the
    runner.

    Args:
        srcs_dirs: Package-relative source directories to sweep.
        extensions: File extensions to include in the glob.

    Returns:
        A `glob(...)` expression string with test/example excludes.
    """
    patterns = []
    excludes = []
    for d in srcs_dirs:
        for ext in extensions:
            patterns.append("{}/**/*.{}".format(d, ext))
        excludes.append("{}/test/**".format(d))
        excludes.append("{}/example/**".format(d))

    # Directories embed the pub package name, which lock classification
    # already refused when quotable; every pattern still renders through the
    # escaping helper, so an odd name lands inert inside a string literal.
    quoted = ["        " + starlark_string_literal(p) + "," for p in patterns]
    excl_quoted = ["        " + starlark_string_literal(e) + "," for e in excludes]
    return "glob(\n        [\n{}\n        ],\n        exclude = [\n{}\n        ],\n        allow_empty = True,\n    )".format("\n".join(quoted), "\n".join(excl_quoted))

def apple_plugin_targets(name, srcs_dirs, include_dirs, platform, plugin_defines = []):
    """The `flutter_apple_plugin_library` pair (device + xtool) for one platform.

    Args:
        name: The pub package name used for the target names.
        srcs_dirs: Package-relative source directories.
        include_dirs: Header search paths for the library.
        platform: `"ios"` or `"macos"`.
        plugin_defines: Preprocessor defines for both generated libraries, in
            the order given. Empty emits no attribute, so the text matches
            the pre-`ios_plugin_defines` output byte for byte.

    Returns:
        The rendered device + xtool library targets.
    """

    # `name` is a lock package name (refused quotable at classification) and
    # `platform` is a fixed literal at every call site; `srcs` globs, the
    # `includes` list and the defines render through the escaping helper.
    defines_block = ""
    if plugin_defines:
        defines_block = "    plugin_defines = {},\n".format(starlark_string_literal(plugin_defines))
    return """
flutter_apple_plugin_library(
    name = "{name}_apple_{platform}",
    srcs = {srcs},
    includes = {includes},
{defines}    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{name}_apple_{platform}_xtool",
    srcs = {srcs},
    includes = {includes},
{defines}    module_name = "{name}",
    platform = "{platform}",
    backend = "xtool",
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = glob_block(srcs_dirs, _APPLE_SRC_EXTENSIONS),
        includes = starlark_string_literal(include_dirs),
        defines = defines_block,
    )

def plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs):
    """The `apple_libs` select routing each OS to its device/xtool library.

    Args:
        name: The pub package name used for the library target names.
        apple_macos_srcs_dirs: Detected macOS source directories.
        apple_ios_srcs_dirs: Detected iOS source directories.

    Returns:
        The rendered `apple_libs` select, or empty when no Apple sources.
    """
    if not (apple_macos_srcs_dirs or apple_ios_srcs_dirs):
        return ""

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
    macos_xtool_branch = '            ":{name}_apple_macos_xtool",'.format(name = name) if apple_macos_srcs_dirs else ""
    ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
    ios_xtool_branch = '            ":{name}_apple_ios_xtool",'.format(name = name) if apple_ios_srcs_dirs else ""
    return """    apple_libs = select({{
        "@rules_flutter//flutter/settings:macos_xtool_backend": [
{macos_xtool_branch}
        ],
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@rules_flutter//flutter/settings:ios_xtool_backend": [
{ios_xtool_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_branch = macos_branch,
        macos_xtool_branch = macos_xtool_branch,
        ios_branch = ios_branch,
        ios_xtool_branch = ios_xtool_branch,
    )

def plugin_privacy_files_arg(apple_macos_privacy_manifests, apple_ios_privacy_manifests):
    """The `apple_privacy_files` select splitting manifests per platform.

    Split per-platform via select() so the macOS bundle never picks up
    iOS-only manifests (and vice versa) — different platforms can declare
    different privacy uses, and Apple's submission validator aggregates
    whatever it finds in the per-platform bundle.

    Args:
        apple_macos_privacy_manifests: macOS privacy manifest paths.
        apple_ios_privacy_manifests: iOS privacy manifest paths.

    Returns:
        The rendered `apple_privacy_files` select, or empty when none.
    """
    if not (apple_macos_privacy_manifests or apple_ios_privacy_manifests):
        return ""

    # Manifest paths are walked from detected source directories plus a
    # fixed file name; each renders through the escaping helper.
    macos_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_macos_privacy_manifests])
    ios_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_ios_privacy_manifests])
    return """    apple_privacy_files = select({{
        "@platforms//os:macos": [
{macos_lines}
        ],
        "@platforms//os:ios": [
{ios_lines}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_lines = macos_lines,
        ios_lines = ios_lines,
    )

def detect_apple_plugin_sources(ctx, package_name, plugin_block):
    """Detects Apple sources per platform when pluginClass is set.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub package name to sweep.
        plugin_block: The parsed plugin block from the package pubspec.

    Returns:
        `struct(macos_srcs, ios_srcs, macos_includes, ios_includes,
        macos_manifests, ios_manifests)`.
    """
    apple_macos_srcs_dirs = []
    apple_ios_srcs_dirs = []
    apple_macos_include_dirs = []
    apple_ios_include_dirs = []

    macos_info = plugin_block.platforms.get("macos", {})
    ios_info = plugin_block.platforms.get("ios", {})
    macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
    ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

    if macos_info and macos_info.get("pluginClass", ""):
        apple_macos_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "macos",
            macos_shared_darwin,
        )
        apple_macos_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_macos_srcs_dirs,
            package_name,
        )

    if ios_info and ios_info.get("pluginClass", ""):
        apple_ios_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "ios",
            ios_shared_darwin,
        )
        apple_ios_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_ios_srcs_dirs,
            package_name,
        )

    podspecs = detect_apple_podspecs(
        ctx,
        package_name,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        macos_shared_darwin,
        ios_shared_darwin,
    )

    return struct(
        macos_srcs = apple_macos_srcs_dirs,
        ios_srcs = apple_ios_srcs_dirs,
        macos_includes = apple_macos_include_dirs,
        ios_includes = apple_ios_include_dirs,
        macos_manifests = podspecs.macos_manifests,
        ios_manifests = podspecs.ios_manifests,
        macos_podspec = podspecs.macos_podspec,
        ios_podspec = podspecs.ios_podspec,
    )

# Plugin template renderers moved out of `flutter_pub_package.bzl` (which
# must not grow): the desktop target, the srcs/hdrs glob splitter, and the
# extra-loads/extra-targets joiners the `flutter_plugin` template renders
# through. Public names with private aliases at the single load site in
# `flutter_pub_package.bzl`, since Bazel forbids importing private symbols.

def split_glob_block(srcs_dirs, src_exts, hdr_exts):
    """Format separate srcs/hdrs glob expressions for desktop plugins.

    Returns (srcs_glob, hdrs_glob) so the spoke can pass the lists to
    flutter_linux_plugin_library / flutter_windows_plugin_library
    separately — those rules require .h/.hh/.hpp on `hdrs` and the
    compilable extensions on `srcs`.

    Args:
        srcs_dirs: Package-relative source directories to sweep.
        src_exts: Compilable file extensions for `srcs`.
        hdr_exts: Header file extensions for `hdrs`.

    Returns:
        The `(srcs_glob, hdrs_glob)` expression pair.
    """
    return glob_block(srcs_dirs, src_exts), glob_block(srcs_dirs, hdr_exts)

_DESKTOP_HDR_EXTS = ("h", "hh", "hpp")
_DESKTOP_C_EXTS = ("cc", "cpp", "c")

def desktop_plugin_target(name, src_dir, platform):
    """The `flutter_<platform>_plugin_library` target for one desktop platform.

    Args:
        name: Classified lock package name used as the target name prefix.
        src_dir: Plugin source directory globbed for C/C++ sources and headers.
        platform: Desktop platform, either `"linux"` or `"windows"`.

    Returns:
        The BUILD snippet text declaring the plugin library target.
    """

    # Same shape as above: `name` is a classified lock package name and
    # `platform` is `"linux"` or `"windows"` at every call site.
    srcs, hdrs = split_glob_block([src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
    return """
flutter_{platform}_plugin_library(
    name = "{name}_{platform}",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["{platform}/include"],
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = srcs,
        hdrs = hdrs,
    )

def plugin_extra_loads(apple_macos_srcs_dirs, apple_ios_srcs_dirs, linux_src_dir, windows_src_dir):
    """The extra `load` lines a plugin spoke needs, joined for the template.

    Args:
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".

    Returns:
        The `load(...)` lines joined with newlines.
    """
    extra_loads = []
    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')
    return "\n".join(extra_loads)

def plugin_extra_targets(
        name,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        linux_src_dir,
        windows_src_dir,
        plugin_defines = []):
    """The per-platform plugin library targets, joined for the template.

    NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    spoke BUILD. Instead, they're exposed via a sibling `android/`
    sub-package (see make_android_subpackage_build_content) which loads
    @rules_android + @rules_kotlin lazily — only when something queries
    `@<spoke>//android:lib`. Mac-only / web-only workspaces never trigger
    the parse and don't pay the @rules_android / @rules_kotlin cost.
    The application-side `flutter_android_app` macro depends on the hub's
    `android/all_android_plugin_libs` aggregator, which deps on every
    spoke's `android:lib` — so Android-targeted builds pick up all
    plugin libraries automatically.

    Args:
        name: The pub package name used for the target names.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        plugin_defines: Preprocessor defines for the Apple libraries, in the
            order given. Empty emits no attribute.

    Returns:
        The rendered per-platform library targets joined with newlines.
    """
    extra_targets = []
    if apple_macos_srcs_dirs:
        extra_targets.append(apple_plugin_targets(
            name,
            apple_macos_srcs_dirs,
            apple_macos_include_dirs,
            "macos",
            plugin_defines,
        ))
    if apple_ios_srcs_dirs:
        extra_targets.append(apple_plugin_targets(
            name,
            apple_ios_srcs_dirs,
            apple_ios_include_dirs,
            "ios",
            plugin_defines,
        ))
    if linux_src_dir:
        extra_targets.append(desktop_plugin_target(name, linux_src_dir, "linux"))
    if windows_src_dir:
        extra_targets.append(desktop_plugin_target(name, windows_src_dir, "windows"))
    return "\n".join(extra_targets)

def _apple_swiftpm_mapping_hint(identity, product):
    """The `swift_package_product_deps` hint appended to unpinned refusals.

    Args:
        identity: The SwiftPM identity, lowercased for the suggested key.
        product: The product name, exactly as the manifest spells it.

    Returns:
        One sentence naming the mapping attribute and the key.
    """
    return ' Map it with flutter.pub(swift_package_product_deps = {"' + identity.lower() + ":" + product + '": "<label>"}).'

def _apple_swiftpm_mapped_label(product_deps, identity, product):
    """Resolve a product through the hub's `<identity>:<product>` map.

    The identity half matches case-insensitively (like the pin lookup);
    the product half matches exactly.

    Args:
        product_deps: The hub's `<identity>:<product>` -> label map.
        identity: The package identity to match.
        product: The product name to match.

    Returns:
        The mapped label string, or None.
    """
    lowered = identity.lower()
    for key in product_deps:
        colon = key.find(":")
        if colon < 0:
            continue
        if key[:colon].lower() == lowered and key[colon + 1:] == product:
            return product_deps[key]
    return None

def _apple_swiftpm_dep_mapped_label(plugin_name, dep, pkg_deps, product_deps):
    """Resolve one product dep through the hub's mapping, if it has one.

    Args:
        plugin_name: The pub plugin name, for `swiftpm_locate_package_dep`.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        product_deps: The hub's `<identity>:<product>` -> label map.

    Returns:
        The mapped label string, or None.
    """
    mapped = _apple_swiftpm_mapped_label(product_deps, dep.package, dep.name)
    if mapped != None:
        return mapped
    located = swiftpm_locate_package_dep(plugin_name, dep.package, pkg_deps)
    if located.ok:
        return _apple_swiftpm_mapped_label(product_deps, located.dep_identity, dep.name)
    return None

def _apple_swiftpm_pinned_identity(pinned, identity):
    """The resolved file's spelling of one pinned identity.

    Args:
        pinned: The pinned identities from the hub's resolved file.
        identity: The identity to match, case-insensitively.

    Returns:
        The pinned spelling, or None when the identity is not pinned.
    """
    lowered = identity.lower()
    for pin_id in pinned:
        if pin_id.lower() == lowered:
            return pin_id
    return None

def _apple_swiftpm_is_path_package(pkg_deps, package):
    """Whether a product's package resolves to a `path:` declaration.

    Args:
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        package: The product's `package:` reference.

    Returns:
        True when the matching declaration is a local path package.
    """
    lowered = package.lower()
    for decl in pkg_deps:
        if decl.name:
            if decl.name.lower() == lowered and decl.ref_kind == "path":
                return True
        elif decl.ref_kind == "path":
            path = decl.ref.replace("\\", "/")
            if path[path.rfind("/") + 1:].lower() == lowered:
                return True
    return False

def _apple_swiftpm_dep_hint(plugin_name, dep, pkg_deps, pins):
    """The mapping hint for one product dep, when a mapping would fix it.

    A path dependency, a package with no declaration, and a pin that
    exists but cannot be fetched keep their own reason: a mapping is not
    the fix for those.

    Args:
        plugin_name: The pub plugin name, for messages.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        pins: `struct(resolved, pinned, unpinned, hub)`.

    Returns:
        The hint suffix, or "" when the refusal needs no hint.
    """
    if _apple_swiftpm_is_path_package(pkg_deps, dep.package):
        return ""
    located = swiftpm_locate_package_dep(plugin_name, dep.package, pkg_deps)
    if not pins.resolved:
        identity = located.dep_identity if located.ok else dep.package
        return _apple_swiftpm_mapping_hint(identity, dep.name)
    if not located.ok:
        return ""
    canonical = _apple_swiftpm_pinned_identity(pins.pinned, located.dep_identity)
    if canonical == None:
        return _apple_swiftpm_mapping_hint(located.dep_identity, dep.name)
    return ""

def _apple_swiftpm_keeps_dep(dep, pkg_deps, platform):
    """True when this platform links one plugin-target product dep.

    Drops the products the spoke never links: a `condition:` excluding
    this platform and the template's `FlutterFramework` path product
    (the rules link Flutter themselves). Same-package dependencies never
    reach here: only `.product` references are passed in.

    Args:
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        platform: `"ios"` or `"macos"`, for condition filtering.

    Returns:
        True when the spoke links this product on this platform.
    """
    condition = getattr(dep, "condition", None)
    if condition != None and platform not in condition.platforms:
        return False
    if dep.package.lower() != "flutterframework":
        return True
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == "flutterframework":
            return decl.ref_kind == "path"
    return False

def _apple_swiftpm_manifest_target(model, manifest_dir, srcs_dirs):
    """Find the manifest target the spoke builds from this manifest.

    Args:
        model: The parsed manifest model.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.

    Returns:
        The matching target struct, or None when the manifest builds
        nothing the spoke emits.
    """
    for target in model.targets:
        if target.kind != "target":
            continue
        declared = target.path if target.path != None else "Sources/" + target.name
        normalized = swiftpm_normalize_relative_path(declared)
        if not normalized.ok:
            continue
        target_dir = manifest_dir if normalized.path == "" else manifest_dir + "/" + normalized.path
        if target_dir in srcs_dirs:
            return target
    return None

def apple_swiftpm_manifest_products(plugin_name, manifest_text, manifest_dir, srcs_dirs, platform):
    """Parse one plugin manifest down to the product dependencies it links.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_text: The `Package.swift` text.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.
        platform: `"ios"` or `"macos"`, for condition filtering.

    Returns:
        `struct(ok, error, products, pkg_deps, target)`: `products` are
        the kept `.product` dependencies in manifest order; `pkg_deps`
        are the manifest's `.package(...)` declarations; `target` is the
        manifest target the spoke builds, or None. A manifest the parser
        cannot read is ok only when its tokens spell no `.package` at all.
        `products` also holds the `kind == "same"` dependencies that name
        no target of the manifest: products of another package by name.
    """
    parsed = parse_swiftpm_plugin_package(plugin_name, manifest_text)
    if not parsed.ok:
        if not apple_swiftpm_declares_package(manifest_text):
            return struct(ok = True, error = "", products = [], pkg_deps = [], target = None)
        return struct(ok = False, error = parsed.error, products = [], pkg_deps = [], target = None)
    target = _apple_swiftpm_manifest_target(parsed.model, manifest_dir, srcs_dirs)
    if target == None:
        return struct(ok = True, error = "", products = [], pkg_deps = parsed.model.pkg_deps, target = None)
    local = [other.name.lower() for other in parsed.model.targets if other.name]
    pkgs = parsed.model.pkg_deps
    products = [
        dep
        for dep in target.deps
        if apple_swiftpm_names_product(dep, local) and _apple_swiftpm_keeps_dep(dep, pkgs, platform)
    ]
    return struct(ok = True, error = "", products = products, pkg_deps = parsed.model.pkg_deps, target = target)

def _apple_swiftpm_linked_dep(plugin_name, dep, pkg_deps, product_deps):
    """The product dependency one kept target dependency links.

    A product reference links as written; a by-name reference becomes the
    product of the declared package that owns it, or fails the fetch.

    Args:
        plugin_name: The pub plugin name, for messages.
        dep: The kept dependency reference (`kind` product or same).
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        product_deps: The hub's `<identity>:<product>` -> label map.

    Returns:
        `struct(ok, error, dep)`.
    """
    if dep.kind == "product":
        return struct(ok = True, error = "", dep = dep)

    def is_mapped(package, product):
        """Whether the hub maps this product of this package."""
        probe = struct(package = package, name = product)
        return _apple_swiftpm_dep_mapped_label(plugin_name, probe, pkg_deps, product_deps) != None

    return apple_swiftpm_resolve_byname(plugin_name, dep, pkg_deps, is_mapped)

def _apple_swiftpm_labels_for_products(plugin_name, manifest_dir, srcs_dirs, platform, pins, prepared, product_deps):
    """Resolve one manifest's kept product dependencies to spoke labels.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub)`.
        prepared: The `apple_swiftpm_manifest_products` result.
        product_deps: The hub's `<identity>:<product>` -> label map.

    Returns:
        `struct(ok, error, labels)`: the spoke dep labels in manifest
        order, deduplicated.
    """
    labels = []
    seen = {}
    for listed in prepared.products:
        linked = _apple_swiftpm_linked_dep(plugin_name, listed, prepared.pkg_deps, product_deps)
        if not linked.ok:
            return struct(ok = False, error = linked.error, labels = [])
        dep = linked.dep
        mapped = _apple_swiftpm_dep_mapped_label(plugin_name, dep, prepared.pkg_deps, product_deps)
        if mapped != None:
            selected = struct(ok = True, error = "", labels = [mapped])
        else:
            synthetic = _apple_swiftpm_synthetic_manifest(prepared.target, prepared.pkg_deps, dep)
            selected = _select_apple_swiftpm_deps(plugin_name, synthetic, manifest_dir, srcs_dirs, platform, pins)
            if not selected.ok:
                hint = _apple_swiftpm_dep_hint(plugin_name, dep, prepared.pkg_deps, pins)
                if hint:
                    selected = struct(ok = False, error = selected.error + hint, labels = [])
        if not selected.ok:
            return struct(ok = False, error = selected.error, labels = [])
        for label in selected.labels:
            if label not in seen:
                seen[label] = True
                labels.append(label)
    return struct(ok = True, error = "", labels = labels)

def select_apple_swiftpm_deps(plugin_name, manifest_text, manifest_dir, srcs_dirs, platform, pins, product_deps = {}):
    """Read one plugin manifest's SwiftPM product links for one platform.

    Parses the manifest with the lenient plugin entry point (target
    settings, such as `resources` or `swiftSettings`, are skipped: they
    cannot change the dependency list, and the spoke keeps its own source,
    header and privacy-manifest detection), finds the plugin target the
    spoke builds, and resolves its `.product(name:package:)`
    dependencies (matched as in step 1) to a mapped label, a sibling
    plugin library or the hub's pinned repositories, keeping only the
    products whose `condition:` allows this platform. Same-package
    dependencies and the template's `FlutterFramework` path product are
    skipped, so a manifest from Flutter's plugin template links nothing.
    A manifest the parser cannot read fails only when its text declares
    a package dependency at all (its tokens spell `.package`): a
    dependency-free manifest keeps building exactly as today. The
    resolved-file refusal applies only when a product this platform
    actually links needs a SwiftPM package, and names that package; a
    sibling plugin path dependency resolves without one.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_text: The `Package.swift` text.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub, lock_packages,
            lock_label)` (see the resolver).
        product_deps: The hub's `<identity>:<product>` -> label map. A
            mapped product resolves before both unpinned refusals.

    Returns:
        `struct(ok, error, labels)`: the spoke dep labels in manifest
        order, deduplicated.
    """
    prepared = apple_swiftpm_manifest_products(plugin_name, manifest_text, manifest_dir, srcs_dirs, platform)
    if not prepared.ok:
        return struct(ok = False, error = prepared.error, labels = [])
    return _apple_swiftpm_labels_for_products(
        plugin_name,
        manifest_dir,
        srcs_dirs,
        platform,
        pins,
        prepared,
        product_deps,
    )

def apple_swiftpm_pins(
        resolved_content,
        checksums_content,
        resolved_label,
        checksums_label,
        hub_name,
        lock_packages = [],
        lock_label = "",
        scc_targets = {}):
    """Assemble one plugin's view of the hub's SwiftPM pins.

    The resolved file supplies the pinned identities and revisions; the
    checksum file supplies the digests. Every pin that cannot be fetched
    gets its refusal in `unpinned`, so a product this plugin links fails
    while reading its manifest, before any archive is downloaded, naming
    the plugin, its manifest and the missing checksum entry.

    Args:
        resolved_content: The hub's `Package.resolved` text.
        checksums_content: The hub's checksum table text, or None.
        resolved_label: The resolved label, for messages.
        checksums_label: The checksum-file label, for messages.
        hub_name: The `flutter.pub` hub name.
        lock_packages: The package names in the hub's `pubspec.lock`.
        lock_label: The hub's `pubspec.lock` label, for messages.
        scc_targets: Mapping `package -> "@<scc_repo>//:<package>"` for SCC members.

    Returns:
        `struct(ok, error, pins)`: `pins` is
        `struct(resolved, pinned, unpinned, hub, lock_packages,
        lock_label, scc_targets)` for the plugin's manifest reader.
    """
    pins = read_swiftpm_pins(resolved_content, resolved_label)
    if not pins.ok:
        return struct(ok = False, error = pins.error, pins = None)
    sha256_by_identity = {}
    if checksums_content != None:
        checksums = read_swiftpm_checksums(checksums_content, checksums_label)
        if not checksums.ok:
            return struct(ok = False, error = checksums.error, pins = None)
        sha256_by_identity = checksums.sha256_by_identity
    return struct(
        ok = True,
        error = "",
        pins = struct(
            resolved = resolved_label,
            pinned = sorted([pin.identity for pin in pins.pins]),
            unpinned = swiftpm_unpinned_errors(pins.pins, sha256_by_identity, hub_name, resolved_label),
            hub = hub_name,
            lock_packages = lock_packages,
            lock_label = lock_label,
            scc_targets = scc_targets,
        ),
    )

def _apple_swiftpm_pins(ctx, resolved_label, checksums_label, hub_name):
    """Read the hub's pin and checksum files for one plugin's links.

    Both labels come from the `flutter.pub` tag and are repository
    attributes of every pub spoke, but an unread label does not make a
    spoke depend on the file. This function reads them only after a
    `Package.swift` is found, so a pure-Dart spoke keeps its marker when
    a pin or a checksum is added, removed or changed. A plugin that
    links a pin reads the checksum table, so changing that pin's digest
    re-fetches the plugin and its refusal names the missing entry.

    Args:
        ctx: The spoke's repository context.
        resolved_label: The hub's `swift_package_resolved` label, or None.
        checksums_label: The hub's checksum-file label, or None.
        hub_name: The `flutter.pub` hub name.

    Returns:
        `struct(resolved, pinned, unpinned, hub, lock_packages, lock_label, scc_targets)`
        for the plugin's manifest reader.
    """
    lock_packages = ctx.attr.lock_packages
    lock_label = str(ctx.attr.pubspec_lock) if ctx.attr.pubspec_lock != None else ""
    scc_targets = ctx.attr.scc_targets if hasattr(ctx.attr, "scc_targets") else {}
    if resolved_label == None:
        return struct(
            resolved = "",
            pinned = [],
            unpinned = {},
            hub = hub_name,
            lock_packages = lock_packages,
            lock_label = lock_label,
            scc_targets = scc_targets,
        )
    label = str(resolved_label)
    checksums_content = ctx.read(checksums_label) if checksums_label != None else None
    checksums_text = str(checksums_label) if checksums_label != None else ""
    built = apple_swiftpm_pins(
        ctx.read(resolved_label),
        checksums_content,
        label,
        checksums_text,
        hub_name,
        lock_packages,
        lock_label,
        scc_targets,
    )
    if not built.ok:
        fail(built.error)
    return built.pins

def _apple_swiftpm_product_deps(ctx, native_deps_label, hub_name):
    """Read the hub's iOS native-deps mapping for one plugin's links.

    The label is a constant repository attribute of every pub spoke, but
    an unread label does not make a spoke depend on the file. This
    function is called only after a manifest yields at least one kept
    product dependency, so a pure-Dart spoke, or an Apple plugin with no
    manifest or no product dependency, keeps its marker when a mapping is
    added, removed or changed.

    Args:
        ctx: The spoke's repository context.
        native_deps_label: The hub's `ios_native_deps` label, or None.
        hub_name: The `flutter.pub` hub name, for messages.

    Returns:
        The hub's `<identity>:<product>` -> label map.
    """
    if native_deps_label == None:
        return {}
    label = str(native_deps_label)
    if not ctx.path(native_deps_label).exists:
        fail((
            "flutter.pub hub {hub}: its iOS native-deps file {label} is " +
            "missing: regenerate the hub."
        ).format(hub = repr(hub_name), label = label))
    built = read_ios_native_deps(ctx.read(native_deps_label), label, hub_name)
    if not built.ok:
        fail(built.error)
    return built.product_deps

def _detect_apple_swiftpm_platform(
        ctx,
        package_name,
        platform,
        srcs_dirs,
        resolved_label,
        checksums_label,
        native_deps_label,
        hub_name):
    """Collect one platform's SwiftPM product labels.

    Reads the platform's `<platform>/<pkg>/Package.swift` and the shared
    `darwin/<pkg>/Package.swift` when present. The resolved and checksum
    files are read only after a manifest is found; the native-deps map is
    read only when that manifest yields a product dependency, so a plugin
    without one never depends on the hub's pin list, checksum table or
    mapping. A refusal fails the fetch: the spoke never downloads
    anything itself.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        srcs_dirs: The platform's detected source directories.
        resolved_label: The hub's `swift_package_resolved` label, or None.
        checksums_label: The hub's checksum-file label, or None.
        native_deps_label: The hub's `ios_native_deps` label, or None.
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        The platform's spoke dep labels, deduplicated.
    """
    labels = []
    if not srcs_dirs:
        return labels
    pins = None
    product_deps = None
    seen = {}
    for manifest_dir in [platform + "/" + package_name, "darwin/" + package_name]:
        manifest = manifest_dir + "/Package.swift"
        if not ctx.path(manifest).exists:
            continue
        if pins == None:
            pins = _apple_swiftpm_pins(ctx, resolved_label, checksums_label, hub_name)
        prepared = apple_swiftpm_manifest_products(package_name, ctx.read(manifest), manifest_dir, srcs_dirs, platform)
        if not prepared.ok:
            fail(prepared.error)
        if not prepared.products:
            continue
        if product_deps == None:
            product_deps = _apple_swiftpm_product_deps(ctx, native_deps_label, hub_name)
        selected = _apple_swiftpm_labels_for_products(
            package_name,
            manifest_dir,
            srcs_dirs,
            platform,
            pins,
            prepared,
            product_deps,
        )
        if not selected.ok:
            fail(selected.error)
        for label in selected.labels:
            if label not in seen:
                seen[label] = True
                labels.append(label)
    return labels

def detect_apple_swiftpm_deps(ctx, package_name, apple):
    """Link the plugin's `Package.swift` products for both Apple platforms.

    Args:
        ctx: The spoke's repository context, carrying the hub's resolved
            label, checksum-file label, native-deps label and name.
        package_name: The pub plugin name.
        apple: The `detect_apple_plugin_sources` struct.

    Returns:
        `struct(macos, ios)`: The per-platform spoke dep label lists.
    """
    plugin_deps = ctx.attr.plugin_native_deps if hasattr(ctx.attr, "plugin_native_deps") else None
    mapped = mapped_apple_plugin_deps(
        str(plugin_deps) if plugin_deps else None,
        apple.macos_srcs,
        apple.ios_srcs,
    )
    if mapped.mapped:
        return struct(macos = mapped.macos, ios = mapped.ios)

    if hasattr(ctx.attr, "podfile_lock") and ctx.attr.podfile_lock != None:
        return detect_apple_cocoapods_deps(ctx, package_name, apple, _detect_apple_swiftpm_platform)

    resolved, sha = ctx.attr.package_resolved, ctx.attr.package_sha256
    ndeps, hub = ctx.attr.ios_native_deps, ctx.attr.hub_name
    return struct(
        macos = _detect_apple_swiftpm_platform(
            ctx,
            package_name,
            "macos",
            apple.macos_srcs,
            resolved,
            sha,
            ndeps,
            hub,
        ),
        ios = _detect_apple_swiftpm_platform(
            ctx,
            package_name,
            "ios",
            apple.ios_srcs,
            resolved,
            sha,
            ndeps,
            hub,
        ),
    )

def _with_apple_swiftpm_platform_deps(content, package_name, platform, labels):
    """Splice one platform's labels into its device and xtool blocks.

    Each `flutter_apple_plugin_library` block gains a `deps = [...]`
    entry before its `visibility`. Both blocks must be present: labels
    only exist when the platform built sources, which always renders
    the device + xtool pair.

    Args:
        content: The rendered spoke BUILD content.
        package_name: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        labels: The platform's spoke dep labels.

    Returns:
        The patched BUILD content.
    """
    deps_block = "    deps = [\n"
    for label in sorted(labels):
        deps_block += "        " + starlark_string_literal(label) + ",\n"
    deps_block += "    ],\n"
    for suffix in ["", "_xtool"]:
        target = "{name}_apple_{platform}{suffix}".format(name = package_name, platform = platform, suffix = suffix)
        marker = '    name = "{target}",\n'.format(target = target)
        head, sep, tail = content.partition(marker)
        vis_head, vis_sep, vis_tail = tail.partition("\n    visibility = ")
        if not sep or not vis_sep:
            fail(
                "Flutter plugin {plugin}: expected a `{target}` library target to carry its SwiftPM dependencies.".format(
                    plugin = repr(package_name),
                    target = target,
                ),
            )
        content = head + sep + vis_head + "\n" + deps_block + vis_sep + vis_tail
    return content

def with_apple_swiftpm_deps(content, package_name, macos_labels, ios_labels):
    """Splice SwiftPM product labels into the rendered Apple library targets.

    `make_flutter_plugin_build_content`'s signature is frozen, so the
    per-platform labels land here, after rendering. A platform with no
    labels leaves its blocks untouched, so spokes without a `Package.swift`
    render byte-identical content.

    Args:
        content: The rendered spoke BUILD content.
        package_name: The pub plugin name.
        macos_labels: The macOS SwiftPM spoke dep labels.
        ios_labels: The iOS SwiftPM spoke dep labels.

    Returns:
        The patched BUILD content.
    """
    if macos_labels:
        content = _with_apple_swiftpm_platform_deps(content, package_name, "macos", macos_labels)
    if ios_labels:
        content = _with_apple_swiftpm_platform_deps(content, package_name, "ios", ios_labels)
    return content
