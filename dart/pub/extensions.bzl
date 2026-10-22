"""Module extension for declaring pub.dev package dependencies."""

load("//dart/ext:registry.bzl", "curated_code_assets")
load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package", "pub_lock_package_sha256_error", "trim_gzip_trailing_nulls")
load("//dart/pub:pub_lock_scc.bzl", "pub_lock_scc_package")
load("//dart/pub:yaml_parser.bzl", "lock_package_error", "parse_pubspec_lock")
load("//dart/pub/private:pub_repository.bzl", "pub_package", "pub_package_sha256_error")
load("//dart/pub/private:pub_symlink.bzl", "check_package_symlinks")
load("//dart/pub/private:scc.bzl", "compute_sccs", "pubspec_dep_graph", "rewrite_vanished_spoke", "scc_repo_name")
load("//dart/pub/private:version.bzl", "semver_gt")

_SPOKE_PREFIX = "dart_pub"

_package = tag_class(
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
    },
)

_from_lock = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages. The name is global to the " +
                  "extension, not scoped to the declaring module: every `from_lock` that " +
                  "states it — in any module in the build — contributes to one hub holding " +
                  "the union of those locks, and each package is aliased once. That is what " +
                  "makes two modules that both call their hub the obvious thing work when a " +
                  "third depends on both. It also means a module can reach a package only " +
                  "another module's lock names, which resolves today and breaks the day that " +
                  "module leaves the build, so state in your own lock everything you import. " +
                  "Package versions are reconciled across the union — see " +
                  "`on_version_conflict`.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly irrelevant to this " +
                  "build (its native code is never reached). Suppresses the unreplaced-hook " +
                  "error for them. This is a declaration you make deliberately; it is never a " +
                  "default.",
            default = [],
        ),
        "on_version_conflict": attr.string(
            doc = "What to do when another lock file provides a higher version of a package. " +
                  "'error' (default) fails the build. 'upgrade' accepts the higher version. " +
                  "Ignored for isolated hubs, which never join version resolution.",
            default = "error",
            values = ["error", "upgrade"],
        ),
        "isolated": attr.bool(
            doc = "When True, this hub is isolated: its spokes are namespaced by the hub " +
                  "name (`<hub>__<pkg>`), it does not join the global registry or " +
                  "`on_version_conflict` resolution, and it pins the versions in its own " +
                  "lock. Use for standalone tools that need a different version of a " +
                  "package than the rest of the build. Defaults to False.",
            default = False,
        ),
    },
)

def _scope_pubspec_contents(ctx, scope_dir, hosted, git_pkgs):
    """Downloads each in-scope package and returns its `pubspec.yaml` contents.

    The extension needs every package's `dependencies:` to find dependency
    cycles before any repository is generated, so it downloads the same
    tarballs the hosted spokes will (verified by the same sha256) and clones
    the same git revisions the git spokes will, reading the one file it needs
    from each. The padded-tarball workaround is the spokes'
    (`trim_gzip_trailing_nulls`): some pub.dev archives end past the gzip
    trailer, which Bazel's extractor rejects.

    Args:
      ctx: The module extension context.
      scope_dir: Scratch directory for this scope's downloads, unique per
        scope so shared and isolated scopes never collide.
      hosted: Dict of hosted package name to `struct(version, sha256, url)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path)`.

    Returns:
      Dict of package name to its `pubspec.yaml` contents ("" when the
      package ships none).
    """
    contents = {}
    ctx.file(scope_dir + "/.scc_scope", "pub dependency-cycle scope scratch")
    for name in sorted(hosted.keys()):
        pkg = hosted[name]
        err = pinned_source_error(
            "hosted",
            name,
            pkg.version,
            sha256 = pkg.sha256,
            rule = "pub.from_lock",
        )
        if err:
            fail(err)
        url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
            base = pkg.url,
            name = name,
            version = pkg.version,
        )
        archive = "{dir}/{name}.tar.gz".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        pinned_download(ctx, url = url, output = archive, sha256 = pkg.sha256)
        raw = ctx.read(archive)
        trimmed = trim_gzip_trailing_nulls(raw)
        if trimmed != raw:
            ctx.file(archive, trimmed, executable = False)
        ctx.extract(archive, output = out)
        check_package_symlinks(ctx, name, out)
        pubspec = out + "/pubspec.yaml"
        contents[name] = ctx.read(pubspec) if ctx.path(pubspec).exists else ""
    for name in sorted(git_pkgs.keys()):
        pkg = git_pkgs[name]
        err = pinned_source_error(
            "git",
            name,
            pkg.version,
            resolved_ref = pkg.resolved_ref,
            rule = "pub.from_lock",
        )
        if err:
            fail(err)

        # Absolute paths: `--git-dir` and `-o` take absolute paths, so no
        # command depends on the working directory.
        bare_rel = "{dir}/{name}_bare".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        git_transport_fetch(ctx, pkg.url, bare_rel, pkg.resolved_ref, 'pub.from_lock "%s"' % name)
        archive = str(ctx.path("{dir}/{name}.tar".format(dir = scope_dir, name = name)))
        spec = pkg.resolved_ref if pkg.path == "." else pkg.resolved_ref + ":" + pkg.path
        git_materialize(ctx, bare_rel, pkg.resolved_ref, archive, spec, 'pub.from_lock "%s"' % name)
        ctx.extract(archive, output = out)
        check_package_symlinks(ctx, name, out)
        pubspec = out + "/pubspec.yaml"
        contents[name] = ctx.read(pubspec) if ctx.path(pubspec).exists else ""
    return contents

def plan_scope_sccs(scope_names, explicit_deps, hub_names, spoke_prefix, pubspec_contents):
    """Plans the merges of one lock scope from its dependency graph.

    Args:
      scope_names: Every package name in scope (hosted plus explicit).
      explicit_deps: Dict of explicit package name to user-declared deps.
      hub_names: All hub repository names in scope.
      spoke_prefix: The scope's spoke repo name prefix.
      pubspec_contents: Dict of hosted package name to `pubspec.yaml`
        contents.

    Returns:
      `struct(members, merged)`: `members` maps every merged package name to
      its merged repository name; `merged` maps each merged repository name
      to its sorted member names. Cycles touching an explicit
      `pub.package()` are left alone — that repository is user-managed, so
      nothing can be merged into it, and the target cycle fails as it does
      today.
    """
    graph = pubspec_dep_graph(
        pubspec_contents,
        explicit_deps,
        scope_names,
        hub_names,
        [spoke_prefix],
    )
    members = {}
    merged = {}
    for component in compute_sccs(graph):
        if len(component) < 2:
            continue
        if any([m in explicit_deps for m in component]):
            continue
        repo = scc_repo_name(spoke_prefix, component)
        merged[repo] = component
        for member in component:
            members[member] = repo
    return struct(members = members, merged = merged)

def scc_member_entries(members, hosted, git_pkgs):
    """Builds the merged repository's member entries for `members_json`.

    Pure given the resolved packages: hosted members carry their tarball
    coordinates, git members their remote, resolved ref and in-repo path, so
    the merged repository fetches each member the way its spoke would.

    Args:
      members: Sorted member package names.
      hosted: Dict of hosted package name to
        `struct(version, sha256, url)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path)`.

    Returns:
      List of structs, each with `source` (`"hosted"` or `"git"`) plus the
      coordinates the merged repository rule reads.
    """
    entries = []
    for member in members:
        if member in hosted:
            pkg = hosted[member]
            entries.append(struct(
                source = "hosted",
                name = member,
                version = pkg.version,
                sha256 = pkg.sha256,
                url = pkg.url,
                code_assets = curated_code_assets(member, pkg.version),
            ))
        else:
            pkg = git_pkgs[member]
            entries.append(struct(
                source = "git",
                name = member,
                version = pkg.version,
                url = pkg.url,
                resolved_ref = pkg.resolved_ref,
                path = pkg.path,
                code_assets = curated_code_assets(member, pkg.version),
            ))
    return entries

def resolve_pub_packages(package_tags, lock_tags):
    """Validates and resolves `pub.package` and `pub.from_lock` declarations.

    Every `pub.package` and hosted `pub.from_lock` entry must carry a
    64-lowercase-hex-digit `sha256` after trimming, even when later superseded
    by version resolution or an explicit `pub.package()`. Conflicting `sha256`
    values for the same package version across lock files or between
    `pub.package()` and a lock file are rejected. A package listed as both a
    hosted package and a git package resolves to its git checkout: the hosted
    entries are ignored with a warning, so the package materialises exactly
    once however the dependency cycles fall.

    Args:
        package_tags: List of structs with `(name, version, sha256, deps)`.
        lock_tags: List of structs with `(name, lock, packages, on_version_conflict, isolated)`.

    Returns:
        `struct(error, explicit, resolved, resolved_git, hub_packages, isolated_packages, isolated_git_packages, warnings)`
        where `error` is an error string when any declaration is unpinned,
        malformed, or conflicting, or `None` when resolution succeeds.
        `isolated_packages` maps each isolated hub name to
        `{pkg_name: struct(version, sha256, url)}` and `isolated_git_packages`
        maps each isolated hub name to
        `{pkg_name: struct(version, url, resolved_ref, path)}`.
    """
    explicit = {}
    for pkg in package_tags:
        err = pub_package_sha256_error(pkg.name, pkg.version, pkg.sha256)
        if err:
            return struct(error = err, explicit = {}, resolved = {}, resolved_git = {}, hub_packages = {}, warnings = [])
        sha256 = pkg.sha256.strip()
        if pkg.name in explicit:
            existing = explicit[pkg.name]
            if existing.version != pkg.version:
                return struct(
                    error = (
                        "Package \"%s\" has conflicting versions across pub.package() declarations:\n" % pkg.name +
                        "  - %s (sha256: %s)\n" % (existing.version, existing.sha256) +
                        "  - %s (sha256: %s)" % (pkg.version, sha256)
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )
            if existing.sha256 != sha256:
                return struct(
                    error = (
                        "Package \"%s\" (%s) has conflicting sha256 checksums across pub.package() declarations:\n" % (pkg.name, pkg.version) +
                        "  - %s\n" % existing.sha256 +
                        "  - %s" % sha256
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )
            if sorted(existing.deps) != sorted(pkg.deps):
                return struct(
                    error = (
                        "Package \"%s\" (%s) has conflicting deps across pub.package() declarations:\n" % (pkg.name, pkg.version) +
                        "  - %s\n" % existing.deps +
                        "  - %s" % pkg.deps
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )
        else:
            explicit[pkg.name] = struct(
                name = pkg.name,
                version = pkg.version,
                sha256 = sha256,
                deps = pkg.deps,
            )

    # Collect all packages from all lock files into a unified registry.
    # registry[pkg_name] = {url, entries: [{version, sha256, hub_name, lock_label, on_version_conflict}]}
    registry = {}

    # Same shape for git-sourced packages, which are pinned by commit SHA rather
    # than by sha256.
    git_registry = {}

    # Which packages belong to each hub, as a set per hub (for per-hub alias
    # creation). A set, not a list, because a hub name is shared by every
    # `from_lock` that states it — including ones in *different modules*, which
    # cannot coordinate their naming and routinely land on the same obvious
    # name. Such a hub holds the union of those locks, and a package both locks
    # name must still be aliased once: two `alias` rules of one name make the
    # generated BUILD file fail to load, which Bazel reports as the *next*
    # package being undeclared, naming neither the duplicate nor the two locks.
    hub_packages = {}
    warnings = []

    isolated_hub_packages = {}
    isolated_hubs = {}

    # Same shape for git-sourced packages in isolated hubs, which pin their
    # own versions like isolated hosted packages and never join the global
    # git registry or version resolution.
    isolated_git_packages = {}

    for lock_tag in lock_tags:
        hub_name = lock_tag.name
        lock_pkgs = lock_tag.packages
        isolated = getattr(lock_tag, "isolated", False)

        if hub_name in isolated_hubs and isolated_hubs[hub_name] != isolated:
            return struct(
                error = "Hub \"%s\" is declared both isolated and non-isolated." % hub_name,
                explicit = {},
                resolved = {},
                hub_packages = {},
                isolated_packages = {},
                warnings = [],
            )
        isolated_hubs[hub_name] = isolated

        hub_packages.setdefault(hub_name, {})
        if isolated:
            isolated_hub_packages.setdefault(hub_name, {})

        # Only hosted packages can be fetched from a pub registry. Collect
        # every non-hosted package and report once per lock file.
        skipped_by_source = {}

        for name, info in lock_pkgs.items():
            err = lock_package_error(name, info, lock_tag.lock)
            if err:
                if info.get("source") == "hosted":
                    sha_err = pub_lock_package_sha256_error(
                        name,
                        info.get("version", ""),
                        info.get("description", {}).get("sha256", ""),
                    )
                    return struct(
                        error = "%s (%s)" % (err, sha_err),
                        explicit = {},
                        resolved = {},
                        resolved_git = {},
                        hub_packages = {},
                        isolated_packages = {},
                        warnings = [],
                    )
                return struct(
                    error = err,
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )

            source = info.get("source", "unknown")
            if source == "git":
                # Git packages are fetched at their resolved-ref commit, like
                # hosted packages, and exposed in the hub the same way.
                hub_packages[hub_name][name] = True

                desc = info.get("description", {})
                url = desc.get("url", "")
                version = info.get("version", "")
                resolved_ref = desc.get("resolved-ref", "").strip()
                path = desc.get("path", ".")
                if path == None or str(path).strip() == "":
                    path = "."

                if not url:
                    return struct(
                        error = 'pub package "%s" %s in %s has no url for its git source.' % (name, version, lock_tag.lock),
                        explicit = {},
                        resolved = {},
                        resolved_git = {},
                        hub_packages = {},
                        isolated_packages = {},
                        isolated_git_packages = {},
                        warnings = [],
                    )

                if isolated:
                    # Isolated hubs pin their own versions: the spoke is
                    # namespaced by the hub and never joins the global
                    # registry or `on_version_conflict` resolution.
                    isolated_git_packages.setdefault(hub_name, {})[name] = struct(
                        version = version,
                        url = url,
                        resolved_ref = resolved_ref,
                        path = path,
                    )
                    continue

                entry = struct(
                    version = version,
                    resolved_ref = resolved_ref,
                    path = path,
                    hub_name = hub_name,
                    lock_label = str(lock_tag.lock),
                    on_version_conflict = lock_tag.on_version_conflict,
                )

                if name not in git_registry:
                    git_registry[name] = struct(url = url, entries = [entry])
                else:
                    existing = git_registry[name]
                    if existing.url != url:
                        return struct(
                            error = (
                                "Package \"%s\" has conflicting git URLs:\n" % name +
                                "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
                                "  - %s (from \"%s\")" % (url, hub_name)
                            ),
                            explicit = {},
                            resolved = {},
                            resolved_git = {},
                            hub_packages = {},
                            isolated_packages = {},
                            isolated_git_packages = {},
                            warnings = [],
                        )
                    git_registry[name] = struct(url = existing.url, entries = existing.entries + [entry])
                continue

            if source != "hosted":
                skipped_by_source.setdefault(source, []).append(name)
                continue

            hub_packages[hub_name][name] = True

            desc = info.get("description", {})
            url = desc.get("url", "https://pub.dev")
            version = info.get("version", "")
            sha256 = desc["sha256"].strip()

            if isolated:
                isolated_hub_packages[hub_name][name] = struct(
                    version = version,
                    sha256 = sha256,
                    url = url,
                )
                continue

            if name in explicit:
                exp = explicit[name]
                if exp.version == version and exp.sha256 != sha256:
                    return struct(
                        error = (
                            "Package \"%s\" (%s) has conflicting sha256 checksums between pub.package() and %s:\n" % (name, version, lock_tag.lock) +
                            "  - %s (from pub.package)\n" % exp.sha256 +
                            "  - %s (from \"%s\", %s)" % (sha256, hub_name, lock_tag.lock)
                        ),
                        explicit = {},
                        resolved = {},
                        resolved_git = {},
                        hub_packages = {},
                        isolated_packages = {},
                        warnings = [],
                    )

            entry = struct(
                version = version,
                sha256 = sha256,
                hub_name = hub_name,
                lock_label = str(lock_tag.lock),
                on_version_conflict = lock_tag.on_version_conflict,
            )

            if name not in registry:
                registry[name] = struct(url = url, entries = [entry])
            else:
                existing = registry[name]
                if existing.url != url:
                    return struct(
                        error = (
                            "Package \"%s\" has conflicting registry URLs:\n" % name +
                            "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
                            "  - %s (from \"%s\")\n" % (url, hub_name)
                        ),
                        explicit = {},
                        resolved = {},
                        resolved_git = {},
                        hub_packages = {},
                        isolated_packages = {},
                        warnings = [],
                    )
                registry[name] = struct(url = existing.url, entries = existing.entries + [entry])

        if skipped_by_source:
            details = []
            for source in sorted(skipped_by_source.keys()):
                if source == "sdk":
                    remedy = "provided by the Dart/Flutter SDK, not fetched by pub"
                else:
                    remedy = "declare via pub.package() or a local dart_library"
                details.append("  - %s (%s): %s" % (
                    source,
                    remedy,
                    ", ".join(sorted(skipped_by_source[source])),
                ))

            warnings.append(
                ("pub.from_lock(%s): %s lists non-hosted packages; no repository " +
                 "is created for them, so `package:` imports of these packages " +
                 "will fail to resolve unless they are provided another way:\n%s") % (
                    hub_name,
                    lock_tag.lock,
                    "\n".join(details),
                ),
            )

    # Resolve each package to a single version
    resolved = {}  # pkg_name -> {version, sha256, url}
    resolved_git = {}  # pkg_name -> {version, url, resolved_ref, path}
    for name, pkg in registry.items():
        # Conflicting sha256 values for the same package version across locks
        # are an error, even when that version is later superseded by a higher
        # version or by an explicit pub.package().
        by_version = {}
        for e in pkg.entries:
            if e.version not in by_version:
                by_version[e.version] = e
            elif by_version[e.version].sha256 != e.sha256:
                first = by_version[e.version]
                return struct(
                    error = (
                        "Package \"%s\" (%s) has conflicting sha256 checksums across lock files:\n" % (name, e.version) +
                        "  - %s (from \"%s\", %s)\n" % (first.sha256, first.hub_name, first.lock_label) +
                        "  - %s (from \"%s\", %s)" % (e.sha256, e.hub_name, e.lock_label)
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )

        if name in explicit:
            continue  # pub.package() wins: no version to reconcile, no spoke

        if name in git_registry:
            # A package listed as both hosted and git materialises once, from
            # its git checkout: generating both a hosted spoke and a git spoke
            # would name two repositories dart_pub__<name>, and a merged cycle
            # would otherwise fetch the hosted tarball and drop the git
            # checkout silently. A single pubspec.lock cannot list both (its
            # package names are unique), so this only fires across the union
            # of several locks.
            git_pkg = git_registry[name]
            lines = ["Package \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entries:" % name]
            for e in pkg.entries:
                lines.append("  - %s (hosted, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
            for e in git_pkg.entries:
                lines.append("  - %s (git, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
            warnings.append("\n".join(lines))
            continue

        if len(pkg.entries) == 1:
            e = pkg.entries[0]
            resolved[name] = struct(version = e.version, sha256 = e.sha256, url = pkg.url)
            continue

        # Find the highest version
        best = pkg.entries[0]
        for e in pkg.entries[1:]:
            if semver_gt(e.version, best.version):
                best = e

        # Check that all lower-version entries allow upgrading
        for e in pkg.entries:
            if e.version != best.version and e.on_version_conflict == "error":
                return struct(
                    error = (
                        "Package \"%s\" has conflicting versions across lock files:\n" % name +
                        "".join([
                            "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
                            for entry in pkg.entries
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
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    warnings = [],
                )

        resolved[name] = struct(version = best.version, sha256 = best.sha256, url = pkg.url)

    # Resolve git packages to a single version, mirroring hosted resolution.
    for name, pkg in git_registry.items():
        by_version = {}
        for e in pkg.entries:
            if e.version not in by_version:
                by_version[e.version] = e
            elif by_version[e.version].resolved_ref != e.resolved_ref:
                first = by_version[e.version]
                return struct(
                    error = (
                        "Package \"%s\" (%s) has conflicting resolved-ref values across lock files:\n" % (name, e.version) +
                        "  - %s (from \"%s\", %s)\n" % (first.resolved_ref, first.hub_name, first.lock_label) +
                        "  - %s (from \"%s\", %s)" % (e.resolved_ref, e.hub_name, e.lock_label)
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    isolated_git_packages = {},
                    warnings = [],
                )

        if len(pkg.entries) == 1:
            e = pkg.entries[0]
            resolved_git[name] = struct(version = e.version, url = pkg.url, resolved_ref = e.resolved_ref, path = e.path)
            continue

        best = pkg.entries[0]
        for e in pkg.entries[1:]:
            if semver_gt(e.version, best.version):
                best = e

        for e in pkg.entries:
            if e.version != best.version and e.on_version_conflict == "error":
                return struct(
                    error = (
                        "Package \"%s\" has conflicting versions across lock files:\n" % name +
                        "".join([
                            "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
                            for entry in pkg.entries
                        ])
                    ),
                    explicit = {},
                    resolved = {},
                    resolved_git = {},
                    hub_packages = {},
                    isolated_packages = {},
                    isolated_git_packages = {},
                    warnings = [],
                )

        resolved_git[name] = struct(version = best.version, url = pkg.url, resolved_ref = best.resolved_ref, path = best.path)

    # A package listed as both hosted and git in one isolated hub
    # materialises once, from its git checkout, like the shared scope above.
    for hub_name, git_pkgs in isolated_git_packages.items():
        hosted = isolated_hub_packages.get(hub_name, {})
        for name in sorted(git_pkgs.keys()):
            if name in hosted:
                warnings.append(
                    "\n".join([
                        "Package \"%s\" in isolated hub \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entry:" % (name, hub_name),
                        "  - %s (hosted)" % hosted[name].version,
                        "  - %s (git)" % git_pkgs[name].version,
                    ]),
                )
                hosted.pop(name)

    return struct(
        error = None,
        explicit = explicit,
        resolved = resolved,
        resolved_git = resolved_git,
        hub_packages = hub_packages,
        isolated_packages = isolated_hub_packages,
        isolated_git_packages = isolated_git_packages,
        warnings = warnings,
    )

def _pub_impl(ctx):
    # Packages the user has declared hook-irrelevant, unioned across every
    # from_lock call — a package is one repo regardless of how many locks
    # mention it, so the flag cannot be per-lock.
    ignore_hooks = {}

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}

    package_tags = []
    lock_tags = []
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            package_tags.append(struct(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
            ))
            if mod.is_root:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

        for lock_tag in mod.tags.from_lock:
            for pkg_name in lock_tag.ignore_hooks:
                ignore_hooks[pkg_name] = True
            if mod.is_root:
                root_repos[lock_tag.name] = root_repos.get(lock_tag.name, True) and ctx.is_dev_dependency(lock_tag)
            lock_content = ctx.read(lock_tag.lock)
            lock_tags.append(struct(
                name = lock_tag.name,
                lock = lock_tag.lock,
                packages = parse_pubspec_lock(lock_content),
                on_version_conflict = lock_tag.on_version_conflict,
                isolated = lock_tag.isolated,
            ))

    resolution = resolve_pub_packages(package_tags, lock_tags)
    if resolution.error:
        fail(resolution.error)

    for warning in resolution.warnings:
        # buildifier: disable=print
        print(warning)

    explicit = resolution.explicit
    resolved = resolution.resolved
    resolved_git = resolution.resolved_git
    hub_packages = resolution.hub_packages
    isolated_packages = getattr(resolution, "isolated_packages", {})
    isolated_git_packages = getattr(resolution, "isolated_git_packages", {})

    # Dependency cycles in the pubspec graph become one merged repository per
    # cycle. The graph needs every hosted package's pubspec, so the extension
    # downloads each package once here; the spokes download the same tarballs
    # again (through the shared download cache) when they materialise.
    explicit_deps = {name: pkg.deps for name, pkg in explicit.items()}
    explicit_package_names = sorted(explicit.keys())

    shared_hubs = sorted([
        hub_name
        for hub_name in hub_packages.keys()
        if hub_name not in isolated_packages and hub_name not in isolated_git_packages
    ])
    shared_names = sorted(set(resolved.keys()) | set(resolved_git.keys())) + explicit_package_names
    shared_contents = {}
    if len(shared_names) > len(explicit_package_names) + 1 or (shared_names != explicit_package_names and any([explicit_deps[name] for name in explicit_deps])):
        shared_contents = _scope_pubspec_contents(ctx, "_scc_shared", resolved, resolved_git)
    shared_sccs = plan_scope_sccs(
        shared_names,
        explicit_deps,
        shared_hubs,
        _SPOKE_PREFIX,
        shared_contents,
    )

    # Merged-away spokes vanish, so an explicit `pub.package()` naming one
    # must name its merged repository instead (a hub alias would keep
    # working, but a spoke label would not resolve).
    vanished_spokes = {}
    for member, repo in shared_sccs.members.items():
        vanished_spokes[_SPOKE_PREFIX + "__" + member] = repo

    isolated_hub_names = sorted(set(isolated_packages.keys()) | set(isolated_git_packages.keys()))
    isolated_sccs = {}
    for hub_name in isolated_hub_names:
        hosted = isolated_packages.get(hub_name, {})
        git_pkgs = isolated_git_packages.get(hub_name, {})
        hub_names = [hub_name]
        scope_names = sorted(set(hosted.keys()) | set(git_pkgs.keys())) + explicit_package_names
        contents = {}
        if len(scope_names) > len(explicit_package_names) + 1 or (scope_names != explicit_package_names and any([explicit_deps[name] for name in explicit_deps])):
            contents = _scope_pubspec_contents(ctx, "_scc_" + hub_name, hosted, git_pkgs)
        isolated_sccs[hub_name] = plan_scope_sccs(
            scope_names,
            explicit_deps,
            hub_names,
            hub_name,
            contents,
        )
        for member, repo in isolated_sccs[hub_name].members.items():
            vanished_spokes[hub_name + "__" + member] = repo

    # Labels spokes and hubs point at for merged members, per scope.
    shared_scc_targets = {
        member: "@{repo}//:{member}".format(repo = repo, member = member)
        for member, repo in shared_sccs.members.items()
    }

    for name, pkg in explicit.items():
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = [rewrite_vanished_spoke(dep, vanished_spokes) for dep in pkg.deps],
        )

    # Create shared spoke repos. Cycle members get no spoke of their own: the
    # merged repository below holds the whole cycle, and every edge into it
    # (mapped through `scc_targets`) names the merged target instead.
    all_package_names = sorted(resolved.keys() + [n for n in resolved_git.keys() if n not in resolved])
    for name, pkg in resolved.items():
        if name in shared_sccs.members:
            continue
        err = pub_lock_package_sha256_error(name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        pub_lock_package(
            name = _SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            # A spoke whose pubspec depends on an explicit package depends on
            # that package's repo, which is what every hub aliases it to.
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
        )

    # Create one merged repository per shared dependency cycle.
    for repo, members in shared_sccs.merged.items():
        entries = scc_member_entries(members, resolved, resolved_git)
        pub_lock_scc_package(
            name = repo,
            repo_name = repo,
            members_json = json.encode(entries),
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            explicit_packages = explicit_package_names,
            scc_targets = shared_scc_targets,
            ignore_hooks = sorted(ignore_hooks.keys()),
        )

    for name, pkg in resolved_git.items():
        if name in shared_sccs.members:
            continue
        pub_lock_git_package(
            name = _SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
        )

    # Create isolated spoke repos (namespaced by hub, outside the global
    # registry). Hosted and git packages in one hub share its package set so
    # cross-source deps within the hub resolve to sibling spokes.
    isolated_hub_names = sorted(set(isolated_packages.keys()) | set(isolated_git_packages.keys()))
    for hub_name in isolated_hub_names:
        hosted = isolated_packages.get(hub_name, {})
        git_pkgs = isolated_git_packages.get(hub_name, {})
        package_names = sorted(set(hosted.keys()) | set(git_pkgs.keys()))
        hub_explicit = [n for n in explicit_package_names if n not in hosted and n not in git_pkgs]
        hub_scc_targets = {
            member: "@{repo}//:{member}".format(repo = repo, member = member)
            for member, repo in isolated_sccs[hub_name].members.items()
        }
        for pkg_name, pkg in hosted.items():
            if pkg_name in isolated_sccs[hub_name].members:
                continue
            err = pub_lock_package_sha256_error(pkg_name, pkg.version, pkg.sha256)
            if err:
                fail(err)
            pub_lock_package(
                name = hub_name + "__" + pkg_name,
                package_name = pkg_name,
                version = pkg.version,
                sha256 = pkg.sha256,
                base_url = pkg.url,
                hub_name = hub_name,
                lock_packages = package_names,
                explicit_packages = hub_explicit,
                code_assets = curated_code_assets(pkg_name, pkg.version),
                ignore_hook = pkg_name in ignore_hooks,
                scc_targets = hub_scc_targets,
            )

        # One merged repository per isolated dependency cycle.
        for repo, members in isolated_sccs[hub_name].merged.items():
            entries = scc_member_entries(members, hosted, git_pkgs)
            pub_lock_scc_package(
                name = repo,
                repo_name = repo,
                members_json = json.encode(entries),
                hub_name = hub_name,
                lock_packages = package_names,
                explicit_packages = hub_explicit,
                scc_targets = hub_scc_targets,
                ignore_hooks = sorted(ignore_hooks.keys()),
            )
        for pkg_name, pkg in git_pkgs.items():
            if pkg_name in isolated_sccs[hub_name].members:
                continue
            pub_lock_git_package(
                name = hub_name + "__" + pkg_name,
                package_name = pkg_name,
                version = pkg.version,
                url = pkg.url,
                resolved_ref = pkg.resolved_ref,
                path = pkg.path,
                hub_name = hub_name,
                lock_packages = package_names,
                explicit_packages = hub_explicit,
                code_assets = curated_code_assets(pkg_name, pkg.version),
                ignore_hook = pkg_name in ignore_hooks,
                scc_targets = hub_scc_targets,
            )

    # Create per-from_lock hub repos
    for hub_name, packages in hub_packages.items():
        package_names = sorted(packages)
        isolated = hub_name in isolated_hub_names
        if isolated:
            spoke_prefix = hub_name
            hub_explicit = []
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in isolated_sccs[hub_name].members.items()
                if member in packages
            }
        else:
            spoke_prefix = _SPOKE_PREFIX
            hub_explicit = [n for n in package_names if n in explicit]
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in shared_sccs.members.items()
                if member in packages
            }
        pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            spoke_prefix = spoke_prefix,
            packages = package_names,
            explicit_packages = hub_explicit,
            scc_targets = hub_scc_targets,
        )

    return ctx.extension_metadata(
        root_module_direct_deps = [name for name, dev in root_repos.items() if not dev],
        root_module_direct_dev_deps = [name for name, dev in root_repos.items() if dev],
    )

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets.",
)
