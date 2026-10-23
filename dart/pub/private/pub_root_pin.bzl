"""Root-wins precedence for `pub.package()` declarations.

The root module pins a hosted package with its own `pub.package()` tag or
with a lock its `pub.from_lock()` reads. Isolated hubs never pin: their
spokes are namespaced by hub and keep the versions in their own lock, so
only non-isolated root locks count. A non-root module's `pub.package()` for
a pinned package is dropped. A dropped declaration at another version
resolves to the root's version with an informational NOTE naming the
package, the root's version and where it came from, and each overridden
version with the module that declared it. A dropped declaration at the same
version with a different sha256 is an integrity conflict and fails naming
both values. A dropped declaration that agrees is silent. With no root pin,
non-root declarations behave as before: one declaration applies, and
disagreeing ones fail.

`select_pub_package` is the precedence decision, factored pure so Starlark
unit tests can call it with module-shaped input (`is_root`, module name,
declaration fields). `resolve_pub_packages` in `//dart/pub:extensions.bzl`
calls it once per package name in sorted name order, so the outcome never
depends on module order.
"""

load("//dart/pub:yaml_parser.bzl", "is_valid_sha256")
load("//dart/pub/private:pub_repository.bzl", "pub_package_sha256_error")
load("//dart/pub/private:version.bzl", "semver_gt")

def explicit_conflict_error(existing, pkg, sha256):
    """Returns the conflict error for a repeated `pub.package()`, or None.

    Args:
      existing: The stored declaration struct with `(version, sha256, deps)`.
      pkg: The new declaration struct with `(name, version, deps)`.
      sha256: The new declaration's stripped sha256.

    Returns:
      The conflict error string, or None when the declarations agree.
    """
    if existing.version != pkg.version:
        return (
            "Package \"%s\" has conflicting versions across pub.package() declarations:\n" % pkg.name +
            "  - %s (sha256: %s)\n" % (existing.version, existing.sha256) +
            "  - %s (sha256: %s)" % (pkg.version, sha256)
        )
    if existing.sha256 != sha256:
        return (
            "Package \"%s\" (%s) has conflicting sha256 checksums across pub.package() declarations:\n" % (pkg.name, pkg.version) +
            "  - %s\n" % existing.sha256 +
            "  - %s" % sha256
        )
    if sorted(existing.deps) != sorted(pkg.deps):
        return (
            "Package \"%s\" (%s) has conflicting deps across pub.package() declarations:\n" % (pkg.name, pkg.version) +
            "  - %s\n" % existing.deps +
            "  - %s" % pkg.deps
        )
    return None

def hosted_sha_conflict(name, entries):
    """Returns the cross-lock sha256 conflict error, or None.

    Args:
      name: The package name the entries resolve.
      entries: The lock entry structs with `(version, sha256, hub_name,
        lock_label)`.

    Returns:
      The conflict error string, or None when no version carries two
      sha256 values.
    """

    # Conflicting sha256 values for the same package version across locks
    # are an error, even when that version is later superseded by a higher
    # version or by an explicit pub.package().
    by_version = {}
    for e in entries:
        if e.version not in by_version:
            by_version[e.version] = e
        elif by_version[e.version].sha256 != e.sha256:
            first = by_version[e.version]
            return (
                "Package \"%s\" (%s) has conflicting sha256 checksums across lock files:\n" % (name, e.version) +
                "  - %s (from \"%s\", %s)\n" % (first.sha256, first.hub_name, first.lock_label) +
                "  - %s (from \"%s\", %s)" % (e.sha256, e.hub_name, e.lock_label)
            )
    return None

def best_entry(entries):
    """Returns the highest-version entry.

    Args:
      entries: The non-empty lock entry structs with `version`.

    Returns:
      The entry with the highest version (the first on ties).
    """
    best = entries[0]
    for e in entries[1:]:
        if semver_gt(e.version, best.version):
            best = e
    return best

def hosted_version_error(name, entries, best):
    """Returns the version-conflict error for hosted packages."""
    return (
        "Package \"%s\" has conflicting versions across lock files:\n" % name +
        "".join([
            "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
            for entry in entries
        ]) +
        "\nThe pubspec.lock files pinned different versions of a shared transitive\n" +
        "package. `dart pub get` preserves existing locked versions, so it won't\n" +
        "bring them back into sync. To resolve:\n" +
        "\n" +
        "  1. (Preferred) Run `dart pub upgrade` in the workspace with the lower\n" +
        "     version. This re-resolves transitive packages within their constraints,\n" +
        "     pulling the shared dependency forward to match.\n" +
        "\n" +
        "  2. If constraints prevent the upgrade, set on_version_conflict = \"upgrade\"\n" +
        "     on the from_lock() call with the lower version, allowing it to accept\n" +
        "     the higher.\n" +
        "\n" +
        "  3. Or pin centrally with an explicit declaration:\n" +
        "       pub.package(name = \"%s\", version = \"%s\", sha256 = \"%s\", deps = [...])\n" % (name, best.version, best.sha256) +
        "       # You may need to manually add deps for this package.\n" +
        "\nrules_dart does not support multiple versions of a package, even across lock files."
    )

def decls_by_name(package_tags):
    """Groups `pub.package()` tags by package name, preserving tag order.

    Args:
      package_tags: The `package` tags, each with `(name, version, sha256,
        deps)` and optionally `(is_root, module)`.

    Returns:
      Dict of package name to that package's declaration structs in tag
      order.
    """
    by_name = {}
    for tag in package_tags:
        by_name.setdefault(tag.name, []).append(struct(
            is_root = getattr(tag, "is_root", True),
            module = getattr(tag, "module", ""),
            name = tag.name,
            version = tag.version,
            sha256 = tag.sha256,
            deps = tag.deps,
        ))
    return by_name

def root_hosted_lock_entries(lock_tags):
    """Maps package name to the root's non-isolated hosted lock entries.

    Only well-formed entries (with a valid sha256) pin: a malformed root
    lock entry is left for lock collection to report, so its error keeps
    today's wording instead of surfacing as a pin conflict.

    Args:
      lock_tags: The `from_lock` tags, each with `(name, lock, packages,
        on_version_conflict, isolated)` and optionally `(is_root, module)`.
        Tags without `is_root` count as root, matching `pub.package()`
        tags from before module tracking.

    Returns:
      Dict of package name to the root's hosted entry structs `(version,
      sha256, hub_name, lock_label, on_version_conflict)`, sorted by lock
      label and hub name so ties never depend on module order.
    """
    by_name = {}
    for tag in lock_tags:
        if not getattr(tag, "is_root", True):
            continue
        if getattr(tag, "isolated", False):
            continue
        for name in sorted(tag.packages.keys()):
            info = tag.packages[name]
            if info.get("source", "unknown") != "hosted":
                continue
            sha256 = info.get("description", {}).get("sha256", "")
            if not is_valid_sha256(sha256):
                continue
            by_name.setdefault(name, []).append(struct(
                version = info.get("version", ""),
                sha256 = sha256.strip(),
                hub_name = tag.name,
                lock_label = str(tag.lock),
                on_version_conflict = tag.on_version_conflict,
            ))
    for name in by_name.keys():
        keyed = [(e.lock_label + "\n" + e.hub_name + "\n" + e.version, i, e) for i, e in enumerate(by_name[name])]
        by_name[name] = [e for (_, _, e) in sorted(keyed)]
    return by_name

def _fold_same_level(decls):
    """Folds same-precedence declarations to one winner. Returns (winner, error)."""
    winner = None
    for decl in decls:
        if winner == None:
            winner = decl
            continue
        err = explicit_conflict_error(winner, decl, decl.sha256)
        if err:
            return None, err
    return winner, None

def _lock_pin(name, entries):
    """Settles the root's lock pin with today's cross-lock rules.

    Returns (pin, error): `pin` is `struct(version, sha256, source)` with
    the winning entry's lock label as source, or None when `entries` is
    empty; `error` is today's cross-lock message when the root's own locks
    disagree.
    """
    if not entries:
        return None, None
    err = hosted_sha_conflict(name, entries)
    if err:
        return None, err
    best = best_entry(entries)
    for e in entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None, hosted_version_error(name, entries, best)
    return struct(version = best.version, sha256 = best.sha256, source = best.lock_label), None

def _root_decl_lock_error(name, root_decl, entries):
    """Returns today's explicit-vs-lock sha error for the root pin, or None."""
    for e in entries:
        if e.version == root_decl.version and e.sha256 != root_decl.sha256:
            return (
                "Package \"%s\" (%s) has conflicting sha256 checksums between pub.package() and %s:\n" % (name, e.version, e.lock_label) +
                "  - %s (from pub.package)\n" % root_decl.sha256 +
                "  - %s (from \"%s\", %s)" % (e.sha256, e.hub_name, e.lock_label)
            )
    return None

def _overridden_note(name, pin_version, pin_source, overridden):
    """Formats the NOTE naming the pin and each overridden declaration."""
    frags = sorted([(decl.module, decl.version) for decl in overridden])
    return (
        "Pub package \"%s\" uses %s from %s, not %s." % (
            name,
            pin_version,
            pin_source,
            "; ".join(["%s declared by module \"%s\"" % (version, module) for (module, version) in frags]),
        )
    )

def _drop_dep_decls(name, pin, pin_source, dep_decls):
    """Drops non-root declarations against the root pin. Returns (note, error)."""
    overridden = []
    for decl in dep_decls:
        if decl.version != pin.version:
            overridden.append(decl)
        elif decl.sha256 != pin.sha256:
            return None, (
                "Package \"%s\" (%s) has conflicting sha256 checksums between the root module's pin from %s and pub.package() from module \"%s\":\n" % (name, decl.version, pin_source, decl.module) +
                "  - %s (from %s)\n" % (pin.sha256, pin_source) +
                "  - %s (from module \"%s\")" % (decl.sha256, decl.module)
            )
    if not overridden:
        return None, None
    return _overridden_note(name, pin.version, pin_source, overridden), None

def select_all_explicit(package_tags, lock_tags):
    """Resolves every `pub.package()` name with root-wins precedence.

    Args:
      package_tags: The `package` tags, each with `(name, version, sha256,
        deps)` and optionally `(is_root, module)`. Tags without `is_root`
        count as root.
      lock_tags: The `from_lock` tags (see `root_hosted_lock_entries`).

    Returns:
      `(explicit, aliases, notes, error, error_shape)`: `explicit` maps
      package name to the winning `(name, version, sha256, deps)` struct, a
      repository the extension generates under the package name;
      `aliases` maps package name to `(version, sha256, source)` for names
      a root lock pin resolves while declarations exist: the extension
      generates the package-named repository as an alias to the lock
      spoke, so modules importing the name keep loading at the root's
      version; `notes` holds one NOTE per package whose root pin
      overrode a different version; `error` with `error_shape` (`"sha"`
      or `"conflict"`) reports the first failure in sorted package name
      order.
    """
    grouped = decls_by_name(package_tags)
    pins = root_hosted_lock_entries(lock_tags)
    explicit = {}
    aliases = {}
    notes = []
    for name in sorted(grouped.keys()):
        sel = select_pub_package(name, grouped[name], pins.get(name, []))
        if sel.error:
            return {}, {}, [], sel.error, sel.error_shape
        if sel.note:
            notes.append(sel.note)
        if sel.selected != None:
            explicit[name] = struct(
                name = name,
                version = sel.selected.version,
                sha256 = sel.selected.sha256,
                deps = sel.selected.deps,
            )
        elif sel.alias != None:
            aliases[name] = sel.alias
    return explicit, aliases, notes, None, ""

def select_pub_package(name, decls, root_entries):
    """Resolves the winning `pub.package()` declaration for one package.

    Args:
      name: The package name.
      decls: Every `pub.package()` tag for the package, each with
        `(is_root, module, name, version, sha256, deps)`, in any order.
      root_entries: The root's non-isolated hosted lock entries for the
        package (see `root_hosted_lock_entries`), in any order.

    Returns:
      `struct(selected, alias, note, error, error_shape)`: `selected` is the
      winning declaration `(version, sha256, deps, source)` or None when no
      `pub.package()` applies (the locks resolve the package); `alias` is
      `(version, sha256, source)` when declarations exist but a root lock
      pin resolves the package, telling the caller to generate the
      package-named repository as an alias to the lock spoke at the root's
      version, or None otherwise; `note` is the informational NOTE when a
      root pin overrides a different version; `error` with `error_shape`
      (`"sha"` or `"conflict"`) reports the failure.
    """
    for decl in decls:
        err = pub_package_sha256_error(decl.name, decl.version, decl.sha256)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "sha")
    clean = [struct(
        is_root = decl.is_root,
        module = decl.module,
        name = decl.name,
        version = decl.version,
        sha256 = decl.sha256.strip(),
        deps = decl.deps,
    ) for decl in decls]
    root_decls = [decl for decl in clean if decl.is_root]
    dep_decls = [decl for decl in clean if not decl.is_root]
    root_decl, err = _fold_same_level(root_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if root_decl:
        pin = struct(version = root_decl.version, sha256 = root_decl.sha256, source = "the root module's pub.package()")
        err = _root_decl_lock_error(name, pin, root_entries)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    else:
        pin, err = _lock_pin(name, root_entries)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if pin == None:
        winner, err = _fold_same_level(dep_decls)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
        if winner == None:
            return struct(selected = None, alias = None, note = None, error = None, error_shape = "")
        return struct(
            selected = struct(version = winner.version, sha256 = winner.sha256, deps = winner.deps, source = "pub.package() from module \"%s\"" % winner.module),
            alias = None,
            note = None,
            error = None,
            error_shape = "",
        )
    note, err = _drop_dep_decls(name, pin, pin.source, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if root_decl:
        selected = struct(version = root_decl.version, sha256 = root_decl.sha256, deps = root_decl.deps, source = pin.source)
        alias = None
    elif dep_decls:
        selected = None
        alias = struct(version = pin.version, sha256 = pin.sha256, source = pin.source)
    else:
        selected = None
        alias = None
    return struct(selected = selected, alias = alias, note = note, error = None, error_shape = "")
