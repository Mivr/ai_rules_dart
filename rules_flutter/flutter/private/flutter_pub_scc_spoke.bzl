"""Repository rule for merged Flutter SCC spokes.

Materialises strongly connected components of pub packages into a single
repository with multi-package dart_library and per-member targets carrying
Flutter assets, fonts, shaders, and plugins.
"""

load("@rules_dart//dart/pub:pinned_sources.bzl", "pinned_source_error")
load(
    "@rules_dart//dart/pub:pub_lock_package.bzl",
    "derive_language_version",
    "trim_gzip_trailing_nulls",
)
load(
    "@rules_dart//dart/pub:pub_scan.bzl",
    "check_package_symlinks",
    "run_pub_archive_scan",
)
load(
    "@rules_dart//dart/pub:pub_scc.bzl",
    "scc_member_deps_error",
    "scc_members_connectivity_error",
    "scc_planned_deps_error",
)
load(
    "@rules_dart//dart/pub:yaml.bzl",
    "pubspec_deps",
    "pubspec_environment_error",
    "pubspec_sdk_constraint",
    "yaml_to_json",
)
load(
    "//flutter/private:asset_uri.bzl",
    "normalize_spoke_asset_block",
)
load("//flutter/private:download.bzl", "pinned_download")
load(
    "//flutter/private:flutter_pub_android_package.bzl",
    "fail_on_outside_package_path",
)
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "detect_apple_plugin_sources",
)
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "apply_apple_native_deps",
)
load(
    "//flutter/private:flutter_pub_mirror.bzl",
    "detect_case_insensitive_host",
    "link_scoped_file_entry",
    "link_spoke_contents",
    "make_link_scope",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "detect_desktop_plugin_sources",
    "path_spoke_platform_dirs",
    "resolve_overlay_roots",
    "spoke_asset_inputs",
)
load(
    "//flutter/private:flutter_pub_package_helpers.bzl",
    "check_pubspec_identity_mismatch",
)
load(
    "//flutter/private:flutter_pub_path.bzl",
    "is_absolute_lock_path",
    "normalize_realpath",
)
load(
    "//flutter/private:flutter_pub_plugin_defines.bzl",
    "check_plugin_defines",
)
load(
    "//flutter/private:flutter_pub_plugin_deps.bzl",
    "check_plugin_native_deps",
)
load(
    "//flutter/private:flutter_pub_scc_build.bzl",
    "adapt_scc_member_overlay_content",
    "make_scc_member_android_build_content",
    "make_scc_member_build_content",
    "make_scc_merged_spoke_build_content",
    "scc_flutter_test_package_bzl_content",
)
load(
    "//flutter/private:flutter_pubspec.bzl",
    "parse_flutter_assets_block",
    "parse_flutter_plugin_block",
)

visibility(["//flutter/..."])

_DART_BUILD_HOOKS = ("hook/build.dart", "hook/link.dart")

def _fetch_hosted_scc_member(ctx, member, name):
    """Downloads, scans, and extracts a hosted SCC member under `<name>/`."""
    err = pinned_source_error(
        "hosted",
        name,
        member.get("version", ""),
        sha256 = member.get("sha256", ""),
        rule = "flutter_pub_scc_package",
    )
    if err:
        fail(err)
    url = member["url"]
    archive = "_" + name + ".tar.gz"
    pinned_download(ctx, url = url, output = archive, sha256 = member["sha256"].strip())
    raw = ctx.read(archive, watch = "no")
    trimmed = trim_gzip_trailing_nulls(raw)
    if trimmed != raw:
        ctx.delete(archive)
        ctx.file(archive, trimmed, executable = False)
    run_pub_archive_scan(ctx, archive, name)
    ctx.extract(archive, output = name)
    ctx.delete(archive)
    check_package_symlinks(ctx, name, root = name)

def _link_path_scc_pubspec(ctx, member, name):
    """Confines a workspace-local path SCC member and links its pubspec under `<name>/`.

    Returns:
        `struct(src, scope)` for `_link_path_scc_contents`, once the
        member's pubspec has been read.
    """
    rel = member.get("path", "")
    if is_absolute_lock_path(rel) or rel in ("", "."):
        fail('flutter.pub SCC member "%s": invalid path %r' % (name, rel))
    segments = rel.replace("\\", "/").split("/")
    if ".." in segments or "." in segments or "" in segments:
        fail('flutter.pub SCC member "%s": path %r escapes workspace' % (name, rel))
    src = ctx.workspace_root.get_child(*segments)
    if not src.exists:
        fail('flutter.pub SCC member "%s": path %r does not exist' % (name, rel))
    ws_real = normalize_realpath(ctx.workspace_root.realpath)
    src_real = normalize_realpath(src.realpath)
    is_win = hasattr(ctx, "os") and "win" in ctx.os.name.lower()
    case_insensitive = is_win or detect_case_insensitive_host(ctx, segments)
    fail_on_outside_package_path(ctx, name, segments, ws_real, case_insensitive)
    scope = make_link_scope(name, src_real, ws_real, case_insensitive, {}, dest_prefix = name)
    link_scoped_file_entry(ctx, src, "pubspec.yaml", scope)
    return struct(src = src, scope = scope)

def _link_path_scc_contents(ctx, member, name, linked, pubspec):
    """Checks a path SCC member's pubspec identity and mirrors what it declares."""
    check_pubspec_identity_mismatch(ctx.attr.hub_name, name, member.get("version", ""), pubspec)
    link_spoke_contents(
        ctx,
        linked.src,
        normalize_spoke_asset_block(name, parse_flutter_assets_block(pubspec)),
        path_spoke_platform_dirs(parse_flutter_plugin_block(pubspec)),
        linked.scope,
    )
    ctx.watch(linked.src)

def _member_spoke_ctx(ctx, name):
    """Adapts the repository `ctx` so single-package helpers read `<name>/...`."""

    def member_path(p):
        """Resolves paths relative to `<name>/`."""
        if type(p) == "string":
            return ctx.path(name if p in ("", ".") else name + "/" + p)
        return ctx.path(p)

    def member_read(p, watch = "auto"):
        """Reads files relative to `<name>/`."""
        if type(p) == "string":
            p = name if p in ("", ".") else name + "/" + p
        return ctx.read(p, watch = watch)

    def member_watch(p):
        """Watches paths relative to `<name>/`."""
        if type(p) == "string":
            p = name if p in ("", ".") else name + "/" + p
        return ctx.watch(p)

    # `os` and `execute` let `yaml_to_json` run its pinned `yaml2json` through
    # this facade (a member reading the hub's `Podfile.lock`, say).
    return struct(
        path = member_path,
        read = member_read,
        watch = member_watch,
        os = ctx.os,
        execute = ctx.execute,
        attr = struct(
            package_name = name,
            hub_name = ctx.attr.hub_name,
            hub_packages = ctx.attr.hub_packages,
            plugin_defines = ctx.attr.ios_plugin_defines.get(name, []),
            plugin_native_deps = ctx.attr.ios_plugin_deps.get(name, None),
            overlay_roots = ctx.attr.overlay_roots,
            package_resolved = ctx.attr.package_resolved,
            package_sha256 = ctx.attr.package_sha256,
            ios_native_deps = ctx.attr.ios_native_deps,
            podfile_lock = ctx.attr.podfile_lock,
            pubspec_lock = ctx.attr.pubspec_lock,
        ),
    )

def _detect_member_hooks(ctx, name, code_assets):
    """Detects `has_unreplaced_hook` and `link_hook` under `<name>/`."""
    unreplaced_hook = ""
    if not code_assets and name not in ctx.attr.ignore_hooks:
        for candidate in _DART_BUILD_HOOKS:
            if ctx.path(name + "/" + candidate).exists:
                unreplaced_hook = candidate
                break
    link_hook = "hook/link.dart" if ctx.path(name + "/hook/link.dart").exists else ""
    return struct(
        code_assets = code_assets,
        has_unreplaced_hook = unreplaced_hook,
        link_hook = link_hook,
    )

def _stage_scc_members(ctx, members):
    """Stages all hosted and path members into their `<name>/` subdirectories.

    Every member's pubspec is read in one `yaml2json` run once it is in place; a
    path member's other files are linked after that, as its pubspec
    declares them.

    Returns:
        Dict of member name to its decoded pubspec (`{}` when it has none).
    """
    linked = {}
    for m in members:
        if m.get("source", "hosted") == "path":
            linked[m["name"]] = _link_path_scc_pubspec(ctx, m, m["name"])
        else:
            _fetch_hosted_scc_member(ctx, m, m["name"])
    present = [m["name"] for m in members if ctx.path(m["name"] + "/pubspec.yaml").exists]
    data = yaml_to_json(ctx, [name + "/pubspec.yaml" for name in present], [name + "/pubspec.yaml" for name in present])
    pubspecs = {m["name"]: {} for m in members}
    for name, pubspec in zip(present, data):
        pubspecs[name] = pubspec
    for m in members:
        if m["name"] in linked:
            _link_path_scc_contents(ctx, m, m["name"], linked[m["name"]], pubspecs[m["name"]])
    return pubspecs

def _parse_and_verify_scc_members(ctx, members, pubspecs):
    """Projects staged member pubspecs and verifies planned deps and SCC connectivity."""
    parsed = {}
    real_deps = {}
    for m in members:
        name = m["name"]
        pubspec = pubspecs[name]
        sdk_err = pubspec_environment_error(pubspec, name + "/pubspec.yaml")
        if sdk_err:
            fail(sdk_err)
        planned = m.get("planned_deps", None)
        err = scc_planned_deps_error(ctx.attr.repo_name, name, planned)
        if err:
            fail(err)
        real_deps[name] = sorted(pubspec_deps(pubspec))
        err = scc_member_deps_error(ctx.attr.repo_name, name, planned, real_deps[name])
        if err:
            fail(err)
        parsed[name] = struct(
            pubspec = pubspec,
            language_version = derive_language_version(pubspec_sdk_constraint(pubspec)),
            version = m.get("version", ""),
            code_assets = m.get("code_assets", []),
            package_files = m.get("package_files", None),
        )

    err = scc_members_connectivity_error(ctx.attr.repo_name, real_deps)
    if err:
        fail(err)
    return parsed, real_deps

def _member_target_aliases(name, member_build):
    """Emits root `alias(...)` entries for platform targets present in `member_build`."""
    aliases = []
    suffixes = (
        "_apple_macos",
        "_apple_macos_xtool",
        "_apple_ios",
        "_apple_ios_xtool",
        "_linux",
        "_windows",
    )
    for suffix in suffixes:
        target = name + suffix
        if ('name = "%s"' % target) in member_build:
            aliases.append(
                ('alias(name = "%s", actual = "//%s:%s", visibility = ["//visibility:public"])') % (
                    target,
                    name,
                    target,
                ),
            )
    return aliases

def _emit_single_member_build(ctx, name, p, plugin_block, asset_block):
    """Writes `<name>/BUILD.bazel` and `<name>/android/BUILD.bazel` for one member."""
    mctx = _member_spoke_ctx(ctx, name)
    hooks = _detect_member_hooks(ctx, name, p.code_assets)
    assets = spoke_asset_inputs(mctx, name, asset_block)
    overlay_content, overlay_android_content = resolve_overlay_roots(
        mctx,
        ctx.attr.overlay_roots,
        name,
        p.version,
        p.language_version,
        [],
    )
    has_deps = bool(mctx.attr.plugin_native_deps) and not overlay_content
    apple_for_check = detect_apple_plugin_sources(mctx, name, plugin_block) if has_deps else None
    check_plugin_defines(mctx, name, plugin_block, bool(overlay_content))
    check_plugin_native_deps(mctx, name, apple_for_check, bool(overlay_content))

    if name == "test":
        ctx.file("test/flutter_test_package.bzl", scc_flutter_test_package_bzl_content(ctx))

    if overlay_content:
        overlay_meta = struct(
            code_assets = hooks.code_assets,
            has_unreplaced_hook = "",
            link_hook = hooks.link_hook,
            package_files = p.package_files,
        )
        member_build = adapt_scc_member_overlay_content(
            name,
            p.language_version,
            p.version,
            overlay_meta,
            overlay_content,
        )
        ctx.file(name + "/BUILD.bazel", member_build)
        ctx.file(
            name + "/android/BUILD.bazel",
            make_scc_member_android_build_content(
                package_name = name,
                overlay_content = overlay_android_content,
            ),
        )
        return _member_target_aliases(name, member_build)

    apple = None
    desktop = None
    platforms_json = ""
    if plugin_block.present:
        apple = detect_apple_plugin_sources(mctx, name, plugin_block)
        desktop = detect_desktop_plugin_sources(mctx, name, plugin_block)
        platforms_json = json.encode(plugin_block.platforms)

    plugin = struct(
        platforms_json = platforms_json,
        defines = ctx.attr.ios_plugin_defines.get(name, []),
        code_assets = hooks.code_assets,
        has_unreplaced_hook = hooks.has_unreplaced_hook,
        link_hook = hooks.link_hook,
        package_files = p.package_files,
    )
    member_build = make_scc_member_build_content(
        package_name = name,
        language_version = p.language_version,
        version = p.version,
        plugin = plugin,
        assets = assets,
        apple = apple,
        desktop = desktop,
    )
    if apple != None:
        member_build = apply_apple_native_deps(mctx, name, apple, member_build)
    ctx.file(name + "/BUILD.bazel", member_build)

    android_build = make_scc_member_android_build_content(
        package_name = name,
        hub_name = ctx.attr.hub_name,
        android_plugin = bool(plugin_block.platforms.get("android", {})),
    )
    ctx.file(name + "/android/BUILD.bazel", android_build)
    return _member_target_aliases(name, member_build)

def _emit_scc_member_builds(ctx, member_names, parsed):
    """Emits per-member BUILD files and collects root aliases."""
    uses_material = False
    apple_aliases = []

    for name in member_names:
        p = parsed[name]
        asset_block = parse_flutter_assets_block(p.pubspec)
        if asset_block and hasattr(asset_block, "uses_material_design") and asset_block.uses_material_design:
            uses_material = True
        plugin_block = parse_flutter_plugin_block(p.pubspec)
        apple_aliases.extend(_emit_single_member_build(ctx, name, p, plugin_block, asset_block))

    return apple_aliases, uses_material

def _emit_scc_root_build(ctx, member_names, apple_aliases, uses_material):
    """Writes the root `BUILD.bazel` file for the merged SCC spoke repository.

    Its dependencies are the extension's: every member's planned dependency
    outside the cycle, as the hub's alias, plus `flutter` when the lock pins it.
    """
    outside_list = list(ctx.attr.deps)
    if uses_material:
        outside_list.append("@rules_flutter//flutter:material_icons")

    ctx.file("BUILD.bazel", make_scc_merged_spoke_build_content(
        repo_name = ctx.attr.repo_name,
        members = member_names,
        dep_labels = sorted(outside_list),
        apple_aliases = sorted(apple_aliases),
    ))

def _flutter_pub_scc_package_impl(ctx):
    """Repository rule implementation for a merged multi-package SCC spoke."""
    members = json.decode(ctx.attr.members_json)
    pubspecs = _stage_scc_members(ctx, members)
    parsed, _ = _parse_and_verify_scc_members(ctx, members, pubspecs)
    member_names = sorted(parsed.keys())
    apple_aliases, uses_material = _emit_scc_member_builds(ctx, member_names, parsed)
    _emit_scc_root_build(ctx, member_names, apple_aliases, uses_material)

flutter_pub_scc_package = repository_rule(
    implementation = _flutter_pub_scc_package_impl,
    attrs = {
        "repo_name": attr.string(
            mandatory = True,
            doc = "The merged repository name.",
        ),
        "hub_name": attr.string(
            mandatory = True,
            doc = "The flutter.pub hub name.",
        ),
        "members_json": attr.string(
            mandatory = True,
            doc = "JSON-encoded member specs: a hosted member's `name`, `version`, `sha256`, " +
                  "`url` (the archive URL planning found) and `code_assets`, a path member's " +
                  "`name`, `path`, `version` and `code_assets`, and for each its `planned_deps`.",
        ),
        "deps": attr.string_list(
            default = [],
            doc = "Labels of the cycle's dependencies outside it, from the members' planned " +
                  "names, each the hub's alias.",
        ),
        "hub_packages": attr.label(
            allow_single_file = True,
            default = None,
            doc = "The hub's `pub_packages.json`, read only by an Apple member that names a sibling plugin.",
        ),
        "ios_plugin_defines": attr.string_list_dict(
            default = {},
            doc = "Preprocessor defines for Apple plugins.",
        ),
        "ios_plugin_deps": attr.string_dict(
            default = {},
            doc = "Canonical labels for per-plugin Apple native dependencies.",
        ),
        "overlay_roots": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Plugin overlay roots.",
        ),
        "ignore_hooks": attr.string_list(
            default = [],
            doc = "Packages whose build hooks are ignored.",
        ),
        "package_resolved": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM Package.resolved label.",
        ),
        "package_sha256": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM Package.resolved sha256 label.",
        ),
        "ios_native_deps": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM and CocoaPods native deps mapping label.",
        ),
        "podfile_lock": attr.label(
            allow_single_file = True,
            default = None,
            doc = "CocoaPods Podfile.lock label.",
        ),
        "pubspec_lock": attr.label(
            allow_single_file = True,
            default = None,
            doc = "Label of the `pubspec.lock` file that the strongly connected component was locked from.",
        ),
    },
    doc = "Merged spoke repository rule for multi-package strongly connected components.",
)
