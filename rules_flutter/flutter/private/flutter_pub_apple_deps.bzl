"""SwiftPM product links for a Flutter pub plugin's Apple libraries.

Pure functions over a parsed `Package.swift` and the hub's pin state. They
find the manifest target the plugin spoke builds, drop the products this
platform does not link, and resolve the rest to Bazel labels: a sibling
plugin's path package to that plugin's own Apple library, a remote pin to
its `<hub>__swiftpm-<identity>` spoke. Split out of
`flutter_pub_apple.bzl` so the plugin spoke's fetch code and this resolver
stay under the god-file limit; `flutter_pub_apple.bzl` loads
`select_apple_swiftpm_deps` back.
"""

load(":swiftpm_manifest.bzl", "parse_swiftpm_plugin_package")
load(":swiftpm_resolved.bzl", "swiftpm_spoke_name")
load(":swiftpm_translate.bzl", "swiftpm_locate_package_dep")

visibility(["//flutter/..."])

def _apple_swiftpm_plugin_target(model, manifest_dir, srcs_dirs):
    """Find the manifest target the spoke builds from this manifest.

    The plugin's target is the one whose source directory (its `path:`,
    else the default `Sources/<name>`) is one of the `Sources/<pkg>`
    directories the spoke emits for this platform.

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
        target_dir = manifest_dir + "/" + (target.path if target.path else "Sources/" + target.name)
        if target_dir in srcs_dirs:
            return target
    return None

def _apple_is_flutterframework_skip(dep, pkg_deps):
    """True when a product dep names the template's FlutterFramework path package.

    Flutter's plugin template declares `.package(name: "FlutterFramework",
    path: ...)` and links it the Xcode way; the rules link Flutter
    themselves, so that product is skipped. The match is name-first, as
    in step 1: only when the manifest's first `FlutterFramework`-named
    declaration is the path one does the skip apply.

    Args:
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        True when the product resolves to the template path package.
    """
    if dep.package.lower() != "flutterframework":
        return False
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == "flutterframework":
            return decl.ref_kind == "path"
    return False

def _apple_keeps_product_dep(dep, pkg_deps, platform):
    """True when this platform links one plugin-target product dep.

    Drops the products the spoke never links: a `condition:` excluding
    this platform and the template's `FlutterFramework` path product
    (the rules link Flutter themselves). Same-package dependencies
    never reach here: only `.product` references are passed in.

    Args:
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        platform: `"ios"` or `"macos"`, for condition filtering.

    Returns:
        True when the spoke links this product on this platform.
    """
    if getattr(dep, "condition", None) != None and platform not in dep.condition.platforms:
        return False
    if _apple_is_flutterframework_skip(dep, pkg_deps):
        return False
    return True

def _apple_path_package_name(decl):
    """The package name a path declaration carries.

    A `.package(name:path:)` declaration names its package with `name:`;
    a bare `.package(path:)` names it by the path's last segment.

    Args:
        decl: The parsed `.package(...)` declaration.

    Returns:
        The name, or "" when a bare declaration's path has no segment.
    """
    if decl.name:
        return decl.name
    path = decl.ref.replace("\\", "/")
    return path[path.rfind("/") + 1:]

def _apple_relative_path_step(path):
    """The one path segment a `../<X>` locator names.

    Args:
        path: The declaration's `path:` string.

    Returns:
        The segment, or "" when the path is not exactly one `..` step
        followed by one segment (absolute paths, `.`, `../x/y` and
        further `..` steps are refused).
    """
    if not path.startswith("../"):
        return ""
    segment = path[3:]
    if not segment or segment == "." or segment == ".." or "/" in segment or "\\" in segment:
        return ""
    return segment

def _apple_path_dep_for(package, pkg_deps):
    """Find the path declaration a `.product(package:)` reference names.

    Matches `package:` against a declaration's `name:` first, as
    `swiftpm_locate_package_dep` does, then against a bare path
    declaration's last path segment. A name that resolves to a non-path
    declaration returns None, leaving the normal url/id lookup in charge.

    Args:
        package: The product's `package:` reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        The matching path declaration struct, or None.
    """
    lowered = package.lower()
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == lowered:
            return decl if decl.ref_kind == "path" else None
    for decl in pkg_deps:
        if decl.ref_kind == "path" and not decl.name:
            if _apple_path_package_name(decl).lower() == lowered:
                return decl
    return None

def _apple_pins_lock_label(pins):
    """The hub's `pubspec.lock` label carried by the pin struct.

    Args:
        pins: The hub's pin struct for one plugin.

    Returns:
        The label text, or "" when the caller supplied no lock label.
    """
    for field in ["lock_label", "pubspec_lock", "lock"]:
        value = getattr(pins, field, "")
        if value:
            return value
    return ""

def _apple_pins_lock_packages(pins):
    """The hub's lock package names carried by the pin struct.

    Args:
        pins: The hub's pin struct for one plugin.

    Returns:
        The package names, or an empty list when none were supplied.
    """
    return getattr(pins, "lock_packages", [])

def _apple_path_refusal(plugin_name, manifest_dir, package_name, path, lock_label):
    """Message 7 for a path dependency that is not a locked sibling plugin.

    Args:
        plugin_name: The pub plugin name depending on the path.
        manifest_dir: The manifest's package-relative directory.
        package_name: The local package name the declaration gives.
        path: The declaration's `path:` string.
        lock_label: The hub's `pubspec.lock` label, for messages.

    Returns:
        The refusal text.
    """
    return (
        "Flutter plugin \"{plugin}\": its {manifest}/Package.swift depends on " +
        "local package \"{package}\" (path \"{path}\"), which is not an Apple " +
        "plugin in the hub's pubspec.lock ({lock})."
    ).format(
        plugin = plugin_name,
        manifest = manifest_dir,
        package = package_name,
        path = path,
        lock = lock_label,
    )

def _apple_sibling_plugin_label(plugin_name, manifest_dir, decl, platform, pins):
    """Resolve a sibling plugin path declaration to its Apple library label.

    The declaration must be exactly `../<X>` for a package `X` in the
    hub's lock other than this plugin; the label uses the lock's spelling
    of the name, because the spoke repository and its Apple library target
    are named by the pub package. A locked package whose spoke emits no
    Apple library for this platform still gets the label: a spoke cannot
    read another package's pubspec at fetch time, so that reference fails
    later at analysis naming the emitted target.

    Args:
        plugin_name: The pub plugin name, for messages and the self check.
        manifest_dir: The manifest's package-relative directory.
        decl: The matched path declaration.
        platform: `"ios"` or `"macos"`, for the label suffix.
        pins: The hub's pin struct, carrying the lock names and label.

    Returns:
        `struct(ok, error, labels)`: one sibling Apple library label, or
        message 7.
    """
    package_name = _apple_path_package_name(decl)
    segment = _apple_relative_path_step(decl.ref)
    canonical = ""
    if segment and segment.lower() == package_name.lower():
        for locked_name in _apple_pins_lock_packages(pins):
            if locked_name.lower() == package_name.lower():
                canonical = locked_name
                break
    if not canonical or canonical.lower() == plugin_name.lower():
        return struct(
            ok = False,
            error = _apple_path_refusal(
                plugin_name,
                manifest_dir,
                package_name,
                decl.ref,
                _apple_pins_lock_label(pins),
            ),
            labels = [],
        )
    scc_targets = pins.scc_targets if hasattr(pins, "scc_targets") and pins.scc_targets else {}
    if canonical in scc_targets:
        scc_repo = scc_targets[canonical].partition("//:")[0]
        return struct(
            ok = True,
            error = "",
            labels = [scc_repo + "//:" + canonical + "_apple_" + platform],
        )
    return struct(
        ok = True,
        error = "",
        labels = ["@" + pins.hub + "__" + canonical + "//:" + canonical + "_apple_" + platform],
    )

def _apple_swiftpm_need_prefix(plugin_name, manifest_dir, identity):
    """The opening of a remote product's refusal.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        identity: The SwiftPM package identity.

    Returns:
        The sentence opening, with the identity still unquoted by the caller.
    """
    return (
        "Flutter plugin {plugin}: its `{manifest}/Package.swift` needs " +
        "SwiftPM package {identity}"
    ).format(
        plugin = repr(plugin_name),
        manifest = manifest_dir,
        identity = repr(identity),
    )

def _apple_swiftpm_no_resolved_error(plugin_name, manifest_dir, identity, hub_name):
    """The refusal when a needed package has no resolved file to read.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        identity: The SwiftPM package identity.
        hub_name: The `flutter.pub` hub name.

    Returns:
        The refusal text.
    """
    return _apple_swiftpm_need_prefix(plugin_name, manifest_dir, identity) + (
        ", but the `flutter.pub` hub {hub} sets no `swift_package_resolved`: " +
        "point it at the app's `Package.resolved`."
    ).format(hub = repr(hub_name))

def _apple_swiftpm_not_pinned_error(plugin_name, manifest_dir, identity, resolved_label):
    """The refusal when a needed package is absent from the resolved file.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        identity: The SwiftPM package identity.
        resolved_label: The hub's resolved-file label, for messages.

    Returns:
        The refusal text.
    """
    return _apple_swiftpm_need_prefix(plugin_name, manifest_dir, identity) + (
        ", which is not pinned in the hub's `Package.resolved` ({resolved}): " +
        "re-resolve the app with Xcode so the pin lands in the resolved file."
    ).format(resolved = resolved_label)

def _apple_swiftpm_unpinned_error(plugin_name, manifest_dir, identity, reason):
    """The refusal for a pinned package whose archive cannot be fetched.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        identity: The SwiftPM package identity.
        reason: The pin's fetch refusal.

    Returns:
        The refusal text.
    """
    return _apple_swiftpm_need_prefix(plugin_name, manifest_dir, identity) + ": {reason}".format(reason = reason)

def _apple_swiftpm_dep_labels(plugin_name, manifest_dir, dep, pkg_deps, platform, pins):
    """Resolve one plugin-target product dep to spoke labels.

    A `path:` declaration resolves to the sibling plugin's Apple library
    when it is a locked package; anything else that is not a remote pin
    gets message 7.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub, lock_packages,
            lock_label)`: the hub's resolved label, the pinned identities,
            the identity-to-refusal dict for unfetchable pins, the hub
            name for dep labels, and the lock names and label.

    Returns:
        `struct(ok, error, labels)`: `labels` holds zero (skipped) or one
        label.
    """
    if not _apple_keeps_product_dep(dep, pkg_deps, platform):
        return struct(ok = True, error = "", labels = [])
    path_decl = _apple_path_dep_for(dep.package, pkg_deps)
    if path_decl != None:
        return _apple_sibling_plugin_label(plugin_name, manifest_dir, path_decl, platform, pins)
    if not pins.resolved:
        located = swiftpm_locate_package_dep(plugin_name, dep.package, pkg_deps)
        identity = located.dep_identity if located.ok else dep.package
        return struct(
            ok = False,
            error = _apple_swiftpm_no_resolved_error(plugin_name, manifest_dir, identity, pins.hub),
            labels = [],
        )
    located = swiftpm_locate_package_dep(plugin_name, dep.package, pkg_deps)
    if not located.ok:
        return struct(ok = False, error = located.error, labels = [])
    canonical = None
    for pin_id in pins.pinned:
        if pin_id.lower() == located.dep_identity.lower():
            canonical = pin_id
            break
    if canonical == None:
        return struct(
            ok = False,
            error = _apple_swiftpm_not_pinned_error(plugin_name, manifest_dir, located.dep_identity, pins.resolved),
            labels = [],
        )
    if canonical in pins.unpinned:
        return struct(
            ok = False,
            error = _apple_swiftpm_unpinned_error(
                plugin_name,
                manifest_dir,
                located.dep_identity,
                pins.unpinned[canonical],
            ),
            labels = [],
        )
    return struct(ok = True, error = "", labels = ["@" + swiftpm_spoke_name(pins.hub, canonical) + "//:" + dep.name])

def select_apple_swiftpm_deps(plugin_name, manifest_text, manifest_dir, srcs_dirs, platform, pins):
    """Read one plugin manifest's SwiftPM product links for one platform.

    Parses the manifest with the lenient plugin entry point (target
    settings, such as `resources` or `swiftSettings`, are skipped: they
    cannot change the dependency list, and the spoke keeps its own source,
    header and privacy-manifest detection), finds the plugin target the
    spoke builds, and resolves its `.product(name:package:)`
    dependencies (matched as in step 1) to sibling plugin libraries or the
    hub's pinned repositories, keeping only the products whose
    `condition:` allows this platform. Same-package dependencies and the
    template's `FlutterFramework` path product are skipped, so a manifest
    from Flutter's plugin template links nothing. A manifest the parser
    cannot read fails only when its text declares a package dependency
    at all (contains `.package(`): a dependency-free manifest keeps
    building exactly as today. The resolved-file refusal applies only
    when a product this platform actually links needs a SwiftPM
    package, and names that package; a sibling plugin path dependency
    resolves without one.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_text: The `Package.swift` text.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub, lock_packages,
            lock_label)` (see `_apple_swiftpm_dep_labels`).

    Returns:
        `struct(ok, error, labels)`: the spoke dep labels in manifest
        order, deduplicated.
    """
    parsed = parse_swiftpm_plugin_package(plugin_name, manifest_text)
    if not parsed.ok:
        if ".package(" not in manifest_text:
            return struct(ok = True, error = "", labels = [])
        return struct(ok = False, error = parsed.error, labels = [])
    target = _apple_swiftpm_plugin_target(parsed.model, manifest_dir, srcs_dirs)
    if target == None:
        return struct(ok = True, error = "", labels = [])
    products = [
        dep
        for dep in target.deps
        if dep.kind == "product" and _apple_keeps_product_dep(dep, parsed.model.pkg_deps, platform)
    ]
    labels = []
    seen = {}
    for dep in products:
        resolved = _apple_swiftpm_dep_labels(plugin_name, manifest_dir, dep, parsed.model.pkg_deps, platform, pins)
        if not resolved.ok:
            return struct(ok = False, error = resolved.error, labels = [])
        for label in resolved.labels:
            if label not in seen:
                seen[label] = True
                labels.append(label)
    return struct(ok = True, error = "", labels = labels)

def _apple_swiftpm_package_dep_text(decl):
    """Render one manifest `.package(...)` declaration for the resolver.

    Args:
        decl: The parsed `.package(...)` declaration.

    Returns:
        The SwiftPM declaration text, with string values JSON-quoted.
    """
    parts = []
    if decl.name:
        parts.append("name: " + json.encode(decl.name))
    if decl.ref:
        parts.append(decl.ref_kind + ": " + json.encode(decl.ref))
    return ".package(" + ", ".join(parts) + ")"

def _apple_swiftpm_product_dep_text(dep):
    """Render one `.product(name:package:)` dependency for the resolver.

    Args:
        dep: The parsed product dependency reference.

    Returns:
        The SwiftPM dependency text, with string values JSON-quoted.
    """
    return ".product(name: " + json.encode(dep.name) + ", package: " + json.encode(dep.package) + ")"

def apple_swiftpm_synthetic_manifest(target, pkg_deps, dep):
    """Build a one-product manifest the unchanged pin resolver can read.

    The resolver lives in `flutter_pub_apple_deps.bzl` and takes a whole
    manifest. Handing it the same target with only this unmapped product
    keeps its pin, checksum, path-package and refusal behaviour exactly,
    while the mapping for the other products is applied in the caller.

    Args:
        target: The manifest target the spoke builds.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        dep: The one product dependency to resolve.

    Returns:
        A `Package.swift` text declaring that target and product.
    """
    packages = ", ".join([_apple_swiftpm_package_dep_text(decl) for decl in pkg_deps])
    path_line = ""
    if target.path:
        path_line = "            path: " + json.encode(target.path) + ",\n"
    return (
        "// swift-tools-version: 5.9\n" +
        "import PackageDescription\n\n" +
        "let package = Package(\n" +
        "    name: " + json.encode(target.name) + ",\n" +
        "    dependencies: [" + packages + "],\n" +
        "    targets: [\n" +
        "        .target(\n" +
        "            name: " + json.encode(target.name) + ",\n" +
        path_line +
        "            dependencies: [" + _apple_swiftpm_product_dep_text(dep) + "],\n" +
        "        ),\n" +
        "    ],\n" +
        ")\n"
    )
