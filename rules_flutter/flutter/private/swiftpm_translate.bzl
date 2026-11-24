"""`Package.swift` model to Bazel BUILD translation for SwiftPM spokes.

Pure functions over the `parse_swiftpm_package` model: the repository rule
(`swiftpm_package.bzl`) resolves target directories and Swift sources at
fetch time, then calls `swiftpm_reachable_targets` (dependency resolution,
reachability, special-kind refusals) and `swiftpm_emit_build` (BUILD text)
here. Starlark unit tests drive both without any fetch.
"""

load(
    ":swiftpm_clang.bzl",
    "swiftpm_clang_module_spec",
    "swiftpm_clang_rule",
    "swiftpm_render_clang_library",
)
load(":swiftpm_settings.bzl", "swiftpm_render_list_attr", "swiftpm_target_setting_entries")

visibility(["//flutter/..."])

_SWIFTPM_C99_OK = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

def swiftpm_c99name(name):
    """Mangle a target name the way SwiftPM's `c99name` does.

    SwiftPM (`spm_mangledToC99ExtendedIdentifier`) replaces every character
    outside the C99 ranges with `_`, one for one: no collapsing, no
    stripping, no leading-digit fix. Starlark indexes strings by byte, so
    a non-ASCII character becomes one `_` per UTF-8 byte rather than
    SwiftPM's one per scalar; target names are ASCII in practice, and the
    difference only matters there.

    Args:
        name: The target name.

    Returns:
        The `module_name` for the target's `swift_library`.
    """
    out = [name[i] if name[i] in _SWIFTPM_C99_OK else "_" for i in range(len(name))]
    return "".join(out)

def swiftpm_language_mode(tools_major, tools_minor, modes):
    """Pick the `-swift-version` language mode for one package.

    Args:
        tools_major: The manifest's tools major version.
        tools_minor: The manifest's tools minor version.
        modes: The parsed `swiftLanguageVersions`/`swiftLanguageModes`
            entries (structs with `major` and `minor`).

    Returns:
        `struct(major, minor)`: the maximum declared mode, else Swift 6
        for tools 6.0+, 5 for tools 5.x, and 4.2/4 for those tools.
    """
    best = None
    for mode in modes:
        if best == None or (mode.major, mode.minor) > (best.major, best.minor):
            best = mode
    if best != None:
        return struct(major = best.major, minor = best.minor)
    if tools_major >= 6:
        return struct(major = 6, minor = 0)
    if tools_major == 5:
        return struct(major = 5, minor = 0)
    return struct(major = 4, minor = tools_minor)

def swiftpm_url_identity(url):
    """Derive a package identity from a `.package(url:)` locator.

    Args:
        url: The url string.

    Returns:
        The last URL path segment minus an optional `.git` suffix ("" when
        the url has no usable segment).
    """
    segment = url
    for _ in range(len(url) + 1):
        slash = segment.rfind("/")
        if slash < 0:
            break
        segment = segment[slash + 1:]
        if segment:
            break
    if segment.endswith(".git"):
        segment = segment[:len(segment) - 4]
    return segment

def _swiftpm_build_files_hint(identity):
    """The escape-hatch pointer every untranslatable target carries."""
    return "Point at a hand-written BUILD file with swift_package_build_files[{identity}] = \"<label>\" to build it another way.".format(identity = repr(identity))

def _swiftpm_special_kind_error(identity, kind, name):
    """The refusal for a reachable target with no Bazel translation.

    Args:
        identity: The SwiftPM package identity.
        kind: The target kind (`executableTarget`, `binaryTarget`,
            `systemLibrary`, `plugin`, `macro`).
        name: The target name ("" when the manifest gave none yet).

    Returns:
        The fetch failure.
    """
    reasons = {
        "executableTarget": "an executable target (a command-line tool)",
        "binaryTarget": "a binary target (a prebuilt artifact)",
        "systemLibrary": "a system library target (a pkg-config/module-map shim)",
        "plugin": "a plugin target (a build-tool plugin)",
        "macro": "a macro target (a compiler plugin)",
    }
    shown = repr(name) if name else "an unnamed target"
    return "SwiftPM package {identity}: target {shown} is {reason}, which has no Bazel translation. {hint}".format(
        identity = repr(identity),
        shown = shown,
        reason = reasons.get(kind, "a special target kind"),
        hint = _swiftpm_build_files_hint(identity),
    )

def swiftpm_locate_package_dep(identity, package, pkg_deps):
    """Resolve a `.product(name:package:)` reference to a pin identity.

    Matches `package:` against a `name:` of a `.package(...)` of the same
    manifest first, else against a `.package(...)`'s url (last URL path
    segment minus an optional `.git`); `id:` declarations match through
    their `name:` only. Every comparison is case-insensitive: manifests
    keep their own case while `Package.resolved` lowercases the identity.
    The pub plugin spoke reuses this matcher so its products resolve
    exactly as the hub's do.

    Args:
        identity: The SwiftPM package identity.
        package: The `package:` reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        `struct(ok, error, dep_identity)`.
    """
    lowered = package.lower()
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == lowered:
            return _swiftpm_decl_identity(identity, package, decl)
    for decl in pkg_deps:
        if decl.ref_kind == "url" and swiftpm_url_identity(decl.ref).lower() == lowered:
            return _swiftpm_decl_identity(identity, package, decl)
    return _swiftpm_dep_identity_fail("SwiftPM package {identity}: `.product(package: {package})` names no package declared in this manifest.".format(identity = repr(identity), package = repr(package)))

def _swiftpm_dep_identity_fail(error):
    """Failure result for package dependency identity resolution."""
    return struct(dep_identity = "", error = error, ok = False)

def _swiftpm_decl_identity(identity, package, decl):
    """Read the pin identity out of one matched `.package(...)`.

    Args:
        identity: The SwiftPM package identity.
        package: The `package:` reference being resolved, for messages.
        decl: The matched declaration.

    Returns:
        `struct(ok, error, dep_identity)`.
    """
    if decl.ref == "":
        return _swiftpm_dep_identity_fail("SwiftPM package {identity}: `.product(package: {package})` matches a `.package(...)` declaring no url or id.".format(identity = repr(identity), package = repr(package)))
    if decl.ref_kind == "path":
        return _swiftpm_dep_identity_fail("SwiftPM package {identity}: `.product(package: {package})` matches a local path dependency, which has no fetchable identity.".format(identity = repr(identity), package = repr(package)))
    if decl.ref_kind == "id":
        return struct(ok = True, error = "", dep_identity = decl.ref)
    found = swiftpm_url_identity(decl.ref)
    if not found:
        return _swiftpm_dep_identity_fail("SwiftPM package {identity}: `.product(package: {package})` matches a `.package(...)` whose url has no usable last path segment.".format(identity = repr(identity), package = repr(package)))
    return struct(ok = True, error = "", dep_identity = found)

def _swiftpm_resolve_same_dep(identity, targets, by_name, target_name, dep):
    """Resolve a same-package `.byName`/`.target` dependency to a target.

    Exact names win; otherwise the match is case-insensitive, because
    `Package.resolved` lowercases the identity while manifests keep
    their own case.

    Args:
        identity: The SwiftPM package identity.
        targets: The parsed target list, in manifest order.
        by_name: The same list indexed by exact target name.
        target_name: The depending target's name, for messages.
        dep: The parsed same-package dependency reference.

    Returns:
        `struct(ok, error, target)`.
    """
    if dep.name in by_name:
        return struct(ok = True, error = "", target = by_name[dep.name])
    lowered = dep.name.lower()
    for candidate in targets:
        if candidate.name and candidate.name.lower() == lowered:
            return struct(ok = True, error = "", target = candidate)
    msg = "SwiftPM package {identity}: target {target} depends on unknown target {name}. A by-name dependency on a product of another package is not supported: write `.product(name: {name}, package: \"<package>\")`, or build the package with swift_package_build_files[{identity}].".format(identity = repr(identity), name = repr(dep.name), target = repr(target_name))
    return struct(error = msg, ok = False, target = None)

def _swiftpm_check_product_targets(identity, model, by_name):
    """Refuse products naming unknown or test targets.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        by_name: The parsed targets indexed by exact name.

    Returns:
        "" or the fetch failure.
    """
    for product in model.products:
        for name in product.targets:
            if name not in by_name:
                return "SwiftPM package {identity}: product {product} names unknown target {name}.".format(identity = repr(identity), product = repr(product.name), name = repr(name))
            if by_name[name].kind == "testTarget":
                return "SwiftPM package {identity}: product {product} names test target {name}, which is ignored.".format(identity = repr(identity), product = repr(product.name), name = repr(name))
    return ""

def _swiftpm_label_fail(error):
    """Failure result for product dependency label resolution."""
    return struct(error = error, label = "", ok = False)

def _swiftpm_product_dep_label(identity, hub_name, dep, pkg_deps, pin_identities):
    """Resolve one `.product(name:package:)` dep to a spoke label.

    Args:
        identity: The SwiftPM package identity.
        hub_name: The `flutter.pub` hub name, for dep labels.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        pin_identities: The identities pinned in `Package.resolved`, or
            None when the caller has no hub-wide pin list. The repo rule
            passes None: `Package.resolved` identities are lower-case, so
            the manifest reference resolves without the list, and the
            spoke's attributes carry no hub-wide pin state.

    Returns:
        `struct(ok, error, label)`.
    """
    located = swiftpm_locate_package_dep(identity, dep.package, pkg_deps)
    if not located.ok:
        return _swiftpm_label_fail(located.error)
    if pin_identities == None:
        canonical = located.dep_identity.lower()
        return struct(ok = True, error = "", label = "@" + hub_name + "__swiftpm-" + canonical + "//:" + dep.name)
    canonical = None
    for pin_id in pin_identities:
        if pin_id.lower() == located.dep_identity.lower():
            canonical = pin_id
            break
    if canonical == None:
        err = "SwiftPM package {identity}: `.product(package: {package})` matches package {dep} which is not pinned in Package.resolved.".format(
            dep = repr(located.dep_identity),
            identity = repr(identity),
            package = repr(dep.package),
        )
        return _swiftpm_label_fail(err)
    return struct(ok = True, error = "", label = "@" + hub_name + "__swiftpm-" + canonical + "//:" + dep.name)

def _swiftpm_target_edge_fail(error):
    """Failure result for `_swiftpm_target_edge`."""
    return struct(error = error, followed = [], labels = [], ok = False)

def _swiftpm_target_edge(identity, model, target, by_name, pin_identities, hub_name):
    """Resolve one target's dependencies to Bazel labels.

    A dependency carrying a `condition:` keeps its listed platforms: the
    emitter renders it inside a `select()` on the target platform's OS,
    so the hub builds one library for every Apple platform. Platforms
    other than iOS and macOS are ignored, and a dependency gated on
    neither drops out of every rendered attribute. Reachability follows
    only dependencies kept on some platform: a target needed on any
    platform must be built, while a dropped one stays out.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        target: The target struct.
        by_name: The parsed targets indexed by exact name.
        pin_identities: The identities pinned in `Package.resolved`, or
            None when the caller has none (see `_swiftpm_product_dep_label`).
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        `struct(ok, error, labels, followed)`: `labels` holds
        `struct(text, platforms)` entries with `platforms` None or the
        `.when(platforms:)` list; `followed` names the same-package
        targets for the reachability walk.
    """
    labels = []
    followed = []
    for dep in target.deps:
        platforms = dep.condition.platforms if getattr(dep, "condition", None) != None else None
        if dep.kind == "same":
            resolved = _swiftpm_resolve_same_dep(identity, model.targets, by_name, target.name, dep)
            if not resolved.ok:
                return _swiftpm_target_edge_fail(resolved.error)
            if resolved.target.kind == "testTarget":
                err = "SwiftPM package {identity}: target {target} depends on test target {name}, which is ignored.".format(
                    identity = repr(identity),
                    name = repr(resolved.target.name),
                    target = repr(target.name),
                )
                return _swiftpm_target_edge_fail(err)
            labels.append(struct(text = ":" + resolved.target.name + "_lib", platforms = platforms))
            if platforms == None or platforms:
                followed.append(resolved.target.name)
        else:
            located = _swiftpm_product_dep_label(identity, hub_name, dep, model.pkg_deps, pin_identities)
            if not located.ok:
                return _swiftpm_target_edge_fail(located.error)
            labels.append(struct(text = located.label, platforms = platforms))
    return struct(ok = True, error = "", labels = labels, followed = followed)

def _swiftpm_walk_reachable(model, same_edges):
    """Walk the targets each library product reaches.

    Args:
        model: The parsed manifest model.
        same_edges: The per-target followed same-package target names.

    Returns:
        The reached-name dict.
    """
    reached = {}
    stack = []
    for product in model.products:
        for name in product.targets:
            if name not in reached:
                reached[name] = True
                stack.append(name)
    for _ in range(len(model.targets) + 1):
        if not stack:
            break
        current = stack.pop()
        for name in same_edges.get(current, []):
            if name not in reached:
                reached[name] = True
                stack.append(name)
    return reached

def _swiftpm_collect_reached(identity, model, reached):
    """List the reached targets in manifest order, refusing specials.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        reached: The reached-name dict.

    Returns:
        `struct(ok, error, names)`.
    """
    names = []
    for target in model.targets:
        if target.name and target.name in reached:
            if target.kind in ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]:
                err = _swiftpm_special_kind_error(identity, target.kind, target.name)
                return struct(error = err, names = [], ok = False)
            names.append(target.name)
    return struct(ok = True, error = "", names = names)

def swiftpm_reachable_targets(identity, model, pin_identities, hub_name):
    """Resolve dependencies and walk the targets a product reaches.

    Seeds from every `.library` product's targets and follows same-package
    target dependencies. Test targets are ignored: a product naming one,
    or a target depending on one, fails the fetch. A reached
    `executableTarget`, `binaryTarget`, `systemLibrary`, `plugin` or
    `macro` target fails with a refusal pointing at
    `swift_package_build_files`.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        pin_identities: The identities pinned in `Package.resolved`, or
            None when the caller has no hub-wide pin list. The repo rule
            passes None so a pin added elsewhere does not change the
            spoke's attributes; the manifest reference itself names the
            identity.
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        `struct(ok, error, names, edges)`: `names` lists reached regular
        targets in manifest order; `edges` maps each reached name to its
        dep entry list (`struct(text, platforms)` with `:other_lib` for
        same-package targets and `@<hub>__swiftpm-<id>//:<product>` for
        products, `platforms` None or the `.when(platforms:)` list).
    """
    by_name = {target.name: target for target in model.targets if target.name}
    invalid = _swiftpm_check_product_targets(identity, model, by_name)
    if invalid:
        return struct(ok = False, error = invalid, names = [], edges = {})
    edges = {}
    same_edges = {}
    for target in model.targets:
        if not target.name or target.kind in ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]:
            continue
        resolved = _swiftpm_target_edge(identity, model, target, by_name, pin_identities, hub_name)
        if not resolved.ok:
            return struct(ok = False, error = resolved.error, names = [], edges = {})
        edges[target.name] = resolved.labels
        same_edges[target.name] = resolved.followed
    reached = _swiftpm_walk_reachable(model, same_edges)
    collected = _swiftpm_collect_reached(identity, model, reached)
    if not collected.ok:
        return struct(ok = False, error = collected.error, names = [], edges = {})
    return struct(ok = True, error = "", names = collected.names, edges = edges)

def _swiftpm_copts_flag(mode):
    """The `-swift-version` flag value for one language mode."""
    if mode.minor == 0:
        return str(mode.major)
    return str(mode.major) + "." + str(mode.minor)

def _swiftpm_build_string(text):
    """Quote arbitrary text as a BUILD string literal.

    Args:
        text: The raw manifest text that is being translated.

    Returns:
        The double-quoted literal with `\\` and `"` escaped.
    """
    return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _swiftpm_emit_swift_library(identity, model, target, edges, files, mode):
    """Emit one `swift_library` for a reached Swift target.

    `swiftSettings` `.define` entries become target-local `-D` flags in
    `copts` (never `defines`, which reaches every dependent), the
    upcoming and experimental feature settings become `copts` flags,
    `linkerSettings` become `linkopts`, and `.when(platforms:)`-gated
    settings and dependencies render as `select()`s on the target
    platform's OS.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        target: The target struct.
        edges: The dep entry map from `swiftpm_reachable_targets`.
        files: `struct(dir, srcs)` with the target's directory and
            explicit Swift sources, package-root relative.
        mode: The language mode struct.

    Returns:
        `struct(ok, error, text)`.
    """
    settings = swiftpm_target_setting_entries(target, files.dir, "swift")
    if not settings.ok:
        return struct(ok = False, error = "SwiftPM package {identity}: {detail}.".format(identity = repr(identity), detail = settings.detail), text = "")
    lines = ["swift_library("]
    lines.append("    name = " + _swiftpm_build_string(target.name + "_lib") + ",")
    lines.append("    srcs = [")
    for src in sorted(files.srcs):
        lines.append("        {src},".format(src = repr(src)))
    lines.append("    ],")
    lines.append("    module_name = {module},".format(module = repr(swiftpm_c99name(target.name))))
    if model.tools_major > 5 or (model.tools_major == 5 and model.tools_minor >= 9):
        lines.append("    package_name = {package},".format(package = repr(identity)))
    gated_copts = [entry for entry in settings.copts if entry.platforms != None and sorted(entry.platforms) != ["ios", "macos"]]
    if not gated_copts:
        plain_copts = ["-swift-version", _swiftpm_copts_flag(mode)] + [entry.text for entry in settings.copts]
        lines.append("    copts = [{items}],".format(items = ", ".join([repr(text) for text in plain_copts])))
    else:
        lists = swiftpm_render_list_attr("copts", ["-swift-version", _swiftpm_copts_flag(mode)], settings.copts)
        lines.append(lists)
    for attr, values in [("linkopts", settings.linkopts), ("deps", edges.get(target.name, []))]:
        lists = swiftpm_render_list_attr(attr, [], values)
        if lists:
            lines.append(lists)
    lines.append("    visibility = [\"//visibility:public\"],")
    lines.append(")")
    return struct(ok = True, error = "", text = "\n".join(lines))

def _swiftpm_emit_fail(error):
    """Failure result for C-family and target block emission."""
    return struct(
        error = error,
        needs_hint = False,
        ok = False,
        rule = "",
        text = "",
    )

def _swiftpm_emit_clang_library(identity, target, edges, files):
    """Emit one `cc_library`/`objc_library` for a reached C-family target.

    The interop hint points at the target's module map, explicit or
    generated, so the one map Swift and clang use is SwiftPM's: without
    it rules_swift would generate a different map from `hdrs` while the
    written map sat unreferenced (and implicitly visible through
    `includes`) as a second definition of the same module. A
    `.headerSearchPath` from target settings is target-local: it goes on
    a private-headers helper the library reaches through
    `implementation_deps`, so no dependent gets it on its include path.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct.
        edges: The dep entry map from `swiftpm_reachable_targets`.
        files: `struct(dir, srcs, c_srcs, public_hdrs, private_hdrs,
            explicit_map, map_in_include)` with the target's directory,
            sources, headers and explicit module map, package-root
            relative.

    Returns:
        `struct(ok, error, text, rule, needs_hint)`: `rule` is
        `"cc_library"` or `"objc_library"`; `needs_hint` when the target
        has public headers and the emitter must load
        `swift_interop_hint`.
    """
    module_name = swiftpm_c99name(target.name)
    c_srcs = getattr(files, "c_srcs", [])
    hdrs = getattr(files, "public_hdrs", [])
    raw_map = getattr(files, "explicit_map", None)
    spec = swiftpm_clang_module_spec(target, module_name, files.dir, c_srcs, hdrs, raw_map)
    if not spec.ok:
        return _swiftpm_emit_fail("SwiftPM package {identity}: {detail}.".format(detail = spec.detail, identity = repr(identity)))
    settings = swiftpm_target_setting_entries(target, files.dir, "clang")
    if not settings.ok:
        return _swiftpm_emit_fail("SwiftPM package {identity}: {detail}.".format(detail = settings.detail, identity = repr(identity)))
    rule = swiftpm_clang_rule(c_srcs)
    explicit_map = raw_map != None
    includes = []
    if explicit_map and getattr(files, "map_in_include", False):
        # The explicit map lives under the public-headers directory: the
        # quoted header includes in the sources resolve only with that
        # directory on the search path, the way SwiftPM compiles such
        # targets. This directory is public, so it propagates.
        map_dir = files.explicit_map[:files.explicit_map.rfind("/")]
        includes.append(struct(text = map_dir, platforms = None))
    if not explicit_map and spec.module_map != None:
        # The generated map lives in the public-headers directory, which
        # the sources include from: it goes on the search path the way
        # SwiftPM compiles such targets. This directory is public, so it
        # propagates.
        includes = [struct(text = spec.include_dir, platforms = None)] + includes
    text = swiftpm_render_clang_library(struct(
        library_name = target.name + "_lib",
        rule = rule,
        srcs = sorted(getattr(files, "c_srcs", [])),
        public_headers = sorted(getattr(files, "public_hdrs", [])),
        private_headers = sorted(getattr(files, "private_hdrs", [])),
        module_name = module_name if spec.module_map != None else "",
        module_map = spec.module_map,
        explicit_map = explicit_map,
        c_only = settings.c_only,
        cxx = settings.cxx,
        linkopts = settings.linkopts,
        includes = includes,
        private_includes = settings.private_includes,
        deps = edges.get(target.name, []),
        tags = ["manual"],
    ))
    return struct(ok = True, error = "", text = text, rule = rule, needs_hint = spec.module_map != None)

def _swiftpm_clang_load_for(rule):
    """The Bazel load line one C-family rule needs, if any.

    Args:
        rule: `"cc_library"`, `"objc_library"` or "".

    Returns:
        The load line, or "" when the rule needs none.
    """
    if rule == "objc_library":
        return "load(\"@rules_cc//cc:objc_library.bzl\", \"objc_library\")"
    if rule == "cc_library":
        return "load(\"@rules_cc//cc:cc_library.bzl\", \"cc_library\")"
    return ""

def _swiftpm_emit_target_block(identity, model, by_name, target_name, edges, files, mode):
    """Emit one reached target's `swift_library` or C-family library.

    A target mixing Swift and C-family sources fails: it has no single
    Bazel rule.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        by_name: The parsed targets indexed by exact name.
        target_name: The reached target's name.
        edges: The dep entry map from `swiftpm_reachable_targets`.
        files: The target's collected files struct.
        mode: The language mode struct.

    Returns:
        `struct(ok, error, text, rule, needs_hint)`: `rule` is
        `"cc_library"`/`"objc_library"` for C-family targets, else "";
        `needs_hint` when the emitter must load `swift_interop_hint`.
    """
    c_srcs = getattr(files, "c_srcs", [])
    if files.srcs and c_srcs:
        return _swiftpm_emit_fail("SwiftPM package {identity}: target {name} mixes Swift and C-family sources, which has no Bazel translation.".format(identity = repr(identity), name = repr(target_name)))
    if c_srcs:
        emitted = _swiftpm_emit_clang_library(identity, by_name[target_name], edges, files)
        if not emitted.ok:
            return _swiftpm_emit_fail(emitted.error)
        return struct(ok = True, error = "", text = emitted.text, rule = emitted.rule, needs_hint = emitted.needs_hint)
    emitted = _swiftpm_emit_swift_library(identity, model, by_name[target_name], edges, files, mode)
    if not emitted.ok:
        return _swiftpm_emit_fail(emitted.error)
    return struct(ok = True, error = "", text = emitted.text, rule = "", needs_hint = False)

def _swiftpm_emit_product_block(product):
    """Emit one product's `alias` or `swift_library_group`.

    Args:
        product: The parsed product struct (`name`, `targets`).

    Returns:
        The text of the `alias` or `swift_library_group` rule for the product.
    """
    if len(product.targets) == 1:
        return "alias(\n    name = {name},\n    actual = {actual},\n    visibility = [\"//visibility:public\"],\n)".format(name = repr(product.name), actual = repr(":" + product.targets[0] + "_lib"))
    deps = [_swiftpm_build_string(":" + target_name + "_lib") for target_name in product.targets]
    return "swift_library_group(\n    name = {name},\n    deps = [\n        {deps},\n    ],\n    visibility = [\"//visibility:public\"],\n)".format(name = repr(product.name), deps = ",\n        ".join(deps))

def swiftpm_emit_build(identity, model, names, edges, files_by_target):
    """Emit the spoke BUILD file for one translated package.

    One `swift_library` per reached Swift target (named `<target>_lib`),
    one `cc_library`/`objc_library` per reached C-family target, one
    `alias` per single-target product (even when the product and target
    names differ), and one `swift_library_group` per multi-target
    product. A target mixing Swift and C-family sources fails: it has no
    single Bazel rule. Rule loads beyond `swift_library` render only when
    a reached target needs them, so Swift-only packages keep their exact
    BUILD text.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        names: The reached target names from `swiftpm_reachable_targets`.
        edges: The dep entry map from `swiftpm_reachable_targets`.
        files_by_target: Dict of reached target name to `struct(dir,
            srcs)` (plus `c_srcs`, `public_hdrs`, `private_hdrs`,
            `explicit_map` and `map_in_include` for C-family targets).

    Returns:
        `struct(ok, error, text)`.
    """
    mode = swiftpm_language_mode(model.tools_major, model.tools_minor, model.modes)
    by_name = {target.name: target for target in model.targets}
    loads = ["load(\"@rules_swift//swift:swift.bzl\", \"swift_library\", \"swift_library_group\")"]
    blocks = []
    for name in names:
        if name not in files_by_target:
            return struct(ok = False, error = "SwiftPM package {identity}: target {name} has no resolved sources.".format(identity = repr(identity), name = repr(name)), text = "")
        emitted = _swiftpm_emit_target_block(identity, model, by_name, name, edges, files_by_target[name], mode)
        if not emitted.ok:
            return struct(ok = False, error = emitted.error, text = "")
        rule_load = _swiftpm_clang_load_for(emitted.rule)
        if rule_load and rule_load not in loads:
            loads.append(rule_load)
        if emitted.needs_hint and not "swift_interop_hint" in loads[0]:
            loads[0] = "load(\"@rules_swift//swift:swift.bzl\", \"swift_interop_hint\", \"swift_library\", \"swift_library_group\")"
        blocks.append(emitted.text)
    for product in model.products:
        blocks.append(_swiftpm_emit_product_block(product))
    return struct(ok = True, error = "", text = "\n\n".join(loads + blocks) + "\n")

def translate_swiftpm_package(identity, hub_name, model, pin_identities, files_by_target):
    """Reach and emit a package in one call, for tests and the repo rule.

    Args:
        identity: The SwiftPM package identity.
        hub_name: The `flutter.pub` hub name, for dep labels.
        model: The parsed manifest model.
        pin_identities: The identities pinned in `Package.resolved`, or
            None when the caller has no hub-wide pin list (the repo rule).
        files_by_target: Dict of target name to `struct(dir, srcs)`.

    Returns:
        `struct(ok, error, text, names)`.
    """
    reached = swiftpm_reachable_targets(identity, model, pin_identities, hub_name)
    if not reached.ok:
        return struct(ok = False, error = reached.error, text = "", names = [])
    emitted = swiftpm_emit_build(identity, model, reached.names, reached.edges, files_by_target)
    if not emitted.ok:
        return struct(ok = False, error = emitted.error, text = "", names = [])
    return struct(ok = True, error = "", text = emitted.text, names = reached.names)
