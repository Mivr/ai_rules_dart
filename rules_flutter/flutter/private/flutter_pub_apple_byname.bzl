"""By-name SwiftPM dependencies and package-declaration detection for plugin spokes.

A plugin target can write `dependencies: ["BigInt"]` (or `.byName(name:)`)
to name a product of another package, which SwiftPM resolves against the
manifest's `.package(...)` declarations. The spoke links such a dependency
like `.product(name:package:)` when exactly one declared package can own
it, and refuses the fetch otherwise. This file also decides, from the
lexer's tokens rather than a raw substring, whether a manifest the parser
cannot read declares a package dependency at all.
"""

load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest")
load(":swiftpm_translate.bzl", "swiftpm_url_identity")

visibility(["//flutter/..."])

def apple_swiftpm_declares_package(text):
    """Whether a manifest text spells a `.package` member anywhere in its code.

    Reads the lexer's tokens, so every legal spelling counts (`.package(`,
    `.package (`, a line break after the dot) while comments and string
    literals do not. A text the lexer rejects cannot be read token by
    token; it counts as declaring one when `.package` appears once the
    whitespace is removed.

    Args:
        text: The `Package.swift` text.

    Returns:
        True when the manifest may declare a package dependency.
    """
    lexed = lex_swiftpm_manifest(text, "")
    if not lexed.ok:
        squeezed = text.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
        return ".package" in squeezed
    previous = None
    for tok in lexed.tokens:
        if tok.kind == "nl":
            continue
        after_dot = previous != None and previous.kind == "punct" and previous.text == "."
        if after_dot and tok.kind == "word" and tok.text == "package":
            return True
        previous = tok
    return False

def apple_swiftpm_decl_reference(decl):
    """The `package:` spelling that names one `.package(...)` declaration.

    Args:
        decl: A parsed `.package(...)` declaration.

    Returns:
        Its `name:`, else its url's identity, else its path's last
        segment ("" when it has none of these).
    """
    if decl.name:
        return decl.name
    if decl.ref_kind == "url":
        return swiftpm_url_identity(decl.ref)
    if decl.ref_kind == "path":
        path = decl.ref.replace("\\", "/").rstrip("/")
        return path[path.rfind("/") + 1:]
    return ""

def apple_swiftpm_names_product(dep, local):
    """Whether a target dependency names a product rather than a local target.

    Args:
        dep: One dependency reference of a manifest target.
        local: Lowercased names of the targets of the plugin's own manifest.

    Returns:
        True for `.product(...)` and for by-name references to no local target.
    """
    if getattr(dep, "kind", "") == "product":
        return True
    return getattr(dep, "by_name", False) and getattr(dep, "name", "").lower() not in local

def _byname_candidates(pkg_deps):
    """The declared packages a by-name dependency could belong to.

    Args:
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        The `package:` spellings of the declarations, without the
        template's `FlutterFramework` (the rules link Flutter themselves).
    """
    refs = []
    for decl in pkg_deps:
        ref = apple_swiftpm_decl_reference(decl)
        if ref and ref.lower() != "flutterframework" and ref not in refs:
            refs.append(ref)
    return refs

def _byname_error(plugin_name, dep, detail, target = ""):
    """The fetch failure for a by-name dependency that cannot be linked.

    Args:
        plugin_name: The pub plugin name.
        dep: The parsed by-name dependency reference.
        detail: What is wrong with it.
        target: The non-primary target that carries it ("" for the primary).

    Returns:
        The failure text, naming the plugin, the dependency and the fix.
    """
    where = " of target " + json.encode(target) if target else ""
    fix = " on the primary target, or link it there," if target else ""
    return ("Flutter plugin {plugin}: target dependency {name}{where} {detail} " +
            "Write it as `.product(name: {name}, package: \"<package>\")`{fix} " +
            "so the package that owns the product is explicit.").format(
        plugin = repr(plugin_name),
        name = json.encode(dep.name),
        detail = detail,
        where = where,
        fix = fix,
    )

def _product_key(plugin_name, dep, pkg_deps):
    """The `(name, package)` a product or by-name dependency links, lowercased.

    Args:
        plugin_name: The pub plugin name.
        dep: A dependency that names a product.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        A `(name, package)` tuple; the package is "" for a by-name
        reference that no single declared package owns.
    """
    if getattr(dep, "kind", "") == "product":
        return (dep.name.lower(), dep.package.lower())
    resolved = apple_swiftpm_resolve_byname(plugin_name, dep, pkg_deps, lambda _package, _product: False)
    return (dep.name.lower(), resolved.dep.package.lower() if resolved.ok else "")

def _product_linked_on(dep, platform):
    """Whether a product-naming dependency is linked on a platform.

    Args:
        dep: A dependency that names a product.
        platform: `"ios"` or `"macos"`.

    Returns:
        False for a conditioned-out dependency and for `FlutterFramework`.
    """
    condition = getattr(dep, "condition", None)
    if condition != None and platform not in getattr(condition, "platforms", [platform]):
        return False
    return "flutterframework" not in (dep.name.lower(), getattr(dep, "package", "").lower())

def apple_swiftpm_nonprimary_product_error(plugin_name, model, primary, current, platform):
    """Refuse a product that a non-primary local target needs and the primary lacks.

    Only the primary target's products are linked on the spoke, so a
    sibling target that names a product the primary does not link
    would fail inside Swift with "no such module".

    Args:
        plugin_name: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        primary: The primary target struct.
        current: The reached target whose dependencies are checked.
        platform: `"ios"` or `"macos"`.

    Returns:
        "" or the refusal text.
    """
    if current == primary:
        return ""
    targets = getattr(model, "targets", [])
    local = [getattr(other, "name", "").lower() for other in targets if getattr(other, "name", "")]
    pkgs = getattr(model, "pkg_deps", [])
    linked = [
        _product_key(plugin_name, dep, pkgs)
        for dep in getattr(primary, "deps", [])
        if apple_swiftpm_names_product(dep, local) and _product_linked_on(dep, platform)
    ]
    for dep in getattr(current, "deps", []):
        if not apple_swiftpm_names_product(dep, local) or not _product_linked_on(dep, platform):
            continue
        name, package = _product_key(plugin_name, dep, pkgs)
        if [1 for other in linked if other[0] == name and (other[1] == package or "" in (other[1], package))]:
            continue
        detail = "is a product the primary target %s does not link." % json.encode(getattr(primary, "name", ""))
        return _byname_error(plugin_name, dep, detail, getattr(current, "name", ""))
    return ""

def apple_swiftpm_resolve_byname(plugin_name, dep, pkg_deps, is_mapped):
    """Turn a by-name dependency into the product dependency it names.

    A by-name dependency that is not a target of the plugin's manifest
    names a product of another package. It resolves to the declared
    package that the hub's `swift_package_product_deps` maps it from,
    else to the only declared package; with none or several it fails.

    Args:
        plugin_name: The pub plugin name, for messages.
        dep: The parsed `kind == "same"` dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        is_mapped: A callable `(package, product) -> bool` telling whether
            the hub maps the product of that package.

    Returns:
        `struct(ok, error, dep)`: `dep` is the product dependency.
    """
    candidates = _byname_candidates(pkg_deps)
    owners = [ref for ref in candidates if is_mapped(ref, dep.name)]
    if not owners:
        owners = candidates
    if not owners:
        detail = "names neither a target of its Package.swift nor a product of a declared `.package(...)`."
        return struct(ok = False, error = _byname_error(plugin_name, dep, detail), dep = None)
    if len(owners) > 1:
        names = ", ".join([json.encode(ref) for ref in owners])
        detail = "could be a product of any of the declared packages " + names + "."
        return struct(ok = False, error = _byname_error(plugin_name, dep, detail), dep = None)
    linked = struct(kind = "product", name = dep.name, package = owners[0], condition = dep.condition)
    return struct(ok = True, error = "", dep = linked)
