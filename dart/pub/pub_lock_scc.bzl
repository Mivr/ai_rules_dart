"""Repository rule materialising one merged pub dependency cycle.

Pub allows packages to depend on each other, but the hub's one-`dart_library`
-per-package layout turns a mutual dependency into a cycle in the Bazel
target graph. For every strongly connected component of the lock's pubspec
dependency graph with more than one package, the extension creates one of
these repositories instead of the members' spokes. It fetches every member —
hosted tarballs and git checkouts alike — extracts each into its own
subdirectory (so each keeps its own `lib/` root), and generates one merged
`dart_library` carrying all member packages, plus an alias per member so
`@hub//:<member>` keeps working. Edges inside the cycle disappear; edges
leaving it become the merged target's `deps`.
"""

load("//dart/pub:pub_lock_package.bzl", "pub_lock_spoke_dep_labels", "trim_gzip_trailing_nulls")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _make_dart_package_member_build_content = "make_dart_package_member_build_content", _make_scc_merged_build_content = "make_scc_merged_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")
load("//dart/pub/private:pub_symlink.bzl", _check_package_symlinks = "check_package_symlinks")

# Re-exported for rule sets outside //dart/pub that reuse the merged shape.
# Loading the private bzl directly would trip buildifier's bzl-visibility
# check, so this public file exposes it the same way `pub_lock_package.bzl`
# exposes `make_dart_library_build_content`.
make_dart_package_member_build_content = _make_dart_package_member_build_content
make_scc_merged_build_content = _make_scc_merged_build_content

def _fetch_hosted_member(ctx, member, name):
    """Downloads one hosted member tarball and extracts it into `name/`."""
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = member["url"],
        name = name,
        version = member["version"],
    )
    archive = "_" + name + ".tar.gz"

    # Same padded-tarball workaround as `pub_lock_package`: pub.dev serves
    # some archives padded with trailing NUL bytes past the gzip trailer.
    ctx.download(
        url = url,
        output = archive,
        sha256 = member["sha256"].strip(),
    )
    raw_archive = ctx.read(archive, watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete(archive)
        ctx.file(archive, trimmed_archive, executable = False)
    ctx.extract(archive, output = name)
    ctx.delete(archive)
    _check_package_symlinks(ctx, name, name)

def _fetch_git_member(ctx, member, name):
    """Clones one git member at its resolved ref and extracts it into `name/`."""
    clone_dir = ctx.path("_" + name + "_clone")
    res = ctx.execute(["git", "clone", "--no-checkout", member["url"], str(clone_dir)])
    if res.return_code != 0:
        fail("pub_lock_scc_package %s: git clone failed for %s: %s" % (name, member["url"], res.stderr))
    res = ctx.execute(["git", "-C", str(clone_dir), "checkout", "--quiet", member["resolved_ref"]])
    if res.return_code != 0:
        ctx.execute(["git", "-C", str(clone_dir), "fetch", "origin", member["resolved_ref"]])
        res = ctx.execute(["git", "-C", str(clone_dir), "checkout", "--quiet", member["resolved_ref"]])
        if res.return_code != 0:
            fail("pub_lock_scc_package %s: git checkout failed at %s: %s" % (name, member["resolved_ref"], res.stderr))
    archive_path = ctx.path("_" + name + ".tar")
    spec = member["resolved_ref"] if member["path"] == "." else member["resolved_ref"] + ":" + member["path"]
    res = ctx.execute(["git", "-C", str(clone_dir), "archive", "--format=tar", "-o", str(archive_path), spec])
    if res.return_code != 0:
        fail("pub_lock_scc_package %s: git archive failed at %s: %s" % (name, spec, res.stderr))
    ctx.extract(archive_path, output = name)
    ctx.delete(archive_path)
    ctx.delete(clone_dir)
    _check_package_symlinks(ctx, name, name)

def _pub_lock_scc_package_impl(ctx):
    members = json.decode(ctx.attr.members_json)
    own_names = {member["name"]: True for member in members}
    available = {p: True for p in ctx.attr.lock_packages + ctx.attr.explicit_packages}

    merged_deps = {}
    for member in members:
        name = member["name"]
        if member.get("source", "hosted") == "git":
            _fetch_git_member(ctx, member, name)
        else:
            _fetch_hosted_member(ctx, member, name)

        # The member's pubspec.yaml states its deps and SDK constraint, the
        # latter so the merged library mirrors pub's per-package
        # languageVersion behaviour.
        pubspec = ctx.read(name + "/pubspec.yaml") if ctx.path(name + "/pubspec.yaml").exists else ""
        all_deps = parse_pubspec_deps(pubspec)
        bazel_deps = sorted([
            d
            for d in all_deps
            if d in available and d not in own_names and d != name
        ])
        dep_labels = pub_lock_spoke_dep_labels(
            bazel_deps,
            ctx.attr.hub_name,
            ctx.attr.explicit_packages,
            ctx.attr.scc_targets,
        )
        for label in dep_labels:
            merged_deps[label] = True

        hooks = _classify_pub_hooks(
            has_build_hook = ctx.path(name + "/hook/build.dart").exists,
            has_link_hook = ctx.path(name + "/hook/link.dart").exists,
            build_hook_handled = bool(member.get("code_assets", [])) or name in ctx.attr.ignore_hooks,
        )

        ctx.file(name + "/BUILD.bazel", _make_dart_package_member_build_content(
            name = name,
            language_version = _derive_language_version(
                parse_pubspec_sdk_constraint(pubspec),
            ),
            code_assets = member.get("code_assets", []),
            has_unreplaced_hook = hooks.unreplaced_hook,
            version = member["version"],
            link_hook = "hook/link.dart" if hooks.link_hook else "",
            merged_label = "//:merged",
        ))

    ctx.file("BUILD.bazel", _make_scc_merged_build_content(
        members = sorted(own_names.keys()),
        dep_labels = sorted(merged_deps.keys()),
        repo_name = ctx.attr.repo_name,
    ))

pub_lock_scc_package = repository_rule(
    implementation = _pub_lock_scc_package_impl,
    attrs = {
        "repo_name": attr.string(
            doc = "The merged repository's apparent name, for its default-target alias. " +
                  "Explicit `pub.package()` deps name the vanished spokes' repositories " +
                  "by apparent name, so the alias must match it.",
            mandatory = True,
        ),
        "members_json": attr.string(
            doc = "JSON list of member packages. Hosted members carry `{source: \"hosted\", name, version, " +
                  "sha256, url, code_assets}`; git members carry `{source: \"git\", name, version, url, " +
                  "resolved_ref, path, code_assets}`. Encoded by the `pub` extension; decoded here.",
            mandatory = True,
        ),
        "hub_name": attr.string(
            doc = "Prefix for sibling spoke repo names (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock scope (for dep filtering).",
            default = [],
        ),
        "explicit_packages": attr.string_list(
            doc = "Every name declared with `pub.package()`. A dependency on one of these " +
                  "points at that explicit repository, not a spoke.",
            default = [],
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for dependencies on members of " +
                  "other merged cycles in the same scope.",
            default = {},
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly irrelevant to this " +
                  "build. Suppresses the unreplaced-hook error for them.",
            default = [],
        ),
    },
    doc = "Downloads every package of one merged dependency cycle into subdirectories and generates one multi-package `dart_library`.",
)
