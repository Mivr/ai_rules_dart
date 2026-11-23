"""BUILD file content generators for merged SCC spoke repositories.

Renders root spoke BUILD files, member BUILD files, and member android/BUILD.bazel
targets for strongly connected component (SCC) pub packages.
"""

load(
    "@rules_dart//dart/pub:pub_lock_scc.bzl",
    "make_dart_package_member_build_content",
)
load(
    "//flutter/private:flutter_pub_android_package.bzl",
    "android_package_repo_name",
    "android_spoke_alias_content",
    "make_android_subpackage_build_content",
)
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "desktop_plugin_target",
    "plugin_apple_libs_arg",
    "plugin_extra_loads",
    "plugin_privacy_files_arg",
)
load(
    "//flutter/private:flutter_pub_package_helpers.bzl",
    "format_pub_asset_attrs_with_shaders",
    "make_flutter_test_package_bzl_content",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

visibility(["//flutter/..."])

def scc_flutter_test_package_bzl_content(ctx = None):
    """Returns the `flutter_test_package.bzl` content for a `test` SCC member.

    Args:
        ctx: The repository or module context, forwarded to pick the runner providers' `.bzl`.

    Returns:
        The Starlark source string.
    """
    return make_flutter_test_package_bzl_content(forward_flutter_providers = True, ctx = ctx)

def _dedupe_labels(labels):
    """Deduplicates a label list while preserving order."""
    seen = {}
    out = []
    for label in labels:
        if label not in seen:
            seen[label] = True
            out.append(label)
    return out

def _split_loads_and_body(content):
    """Splits top-level `load(...)` blocks from the remaining BUILD body."""
    loads = []
    body = []
    depth = 0
    current = []
    for line in content.split("\n"):
        if not current and not line.strip().startswith("load("):
            body.append(line)
            continue
        current.append(line)
        depth += line.count("(") - line.count(")")
        if depth <= 0:
            loads.append("\n".join(current))
            current = []
            depth = 0
    return loads, "\n".join(body).strip()

def _merge_load_blocks(blocks):
    """Deduplicates `load(...)` blocks while preserving first-seen order."""
    seen = {}
    out = []
    for block in blocks:
        if block and block not in seen:
            seen[block] = True
            out.append(block)
    return "\n".join(out)

def make_scc_merged_spoke_build_content(repo_name, members, dep_labels, apple_aliases = []):
    """Generates the root BUILD.bazel content of a merged SCC spoke repository.

    Args:
        repo_name: The spoke repository name.
        members: Sorted list of member names in the SCC.
        dep_labels: Dependencies leaving the SCC.
        apple_aliases: Optional alias declarations for Apple/desktop targets.

    Returns:
        The content string for the root BUILD.bazel file.
    """
    unique_deps = _dedupe_labels(dep_labels)
    member_lines = [
        "        " + starlark_string_literal(
            "//test:test_library" if m == "test" else "//{m}:{m}".format(m = m),
        ) + ","
        for m in members
    ]
    members_block = "    members = [\n{}\n    ],\n".format("\n".join(member_lines))

    deps_block = ""
    if unique_deps:
        dep_lines = ["        " + starlark_string_literal(dep) + "," for dep in unique_deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    scc_member_info_lines = [
        "        " + starlark_string_literal("//{m}:_flutter_info".format(m = m)) + ","
        for m in members
    ]
    scc_members_block = "    scc_members = [\n{}\n    ],\n".format("\n".join(scc_member_info_lines))

    targets = []
    alias_lines = [
        """alias(
    name = "{repo_name}",
    actual = ":merged",
    visibility = ["//visibility:public"],
)""".format(repo_name = repo_name),
    ]
    for m in members:
        target_name = "_test_member" if m == "test" else m
        targets.append("""flutter_pub_scc_member_target(
    name = "{target_name}",
    package_name = "{m}",
    library = ":merged",
{scc_members}{deps}    visibility = ["//visibility:public"],
)""".format(
            target_name = target_name,
            m = m,
            scc_members = scc_members_block,
            deps = deps_block,
        ))
        if m == "test":
            alias_lines.append("""alias(
    name = "test",
    actual = "//test:test",
    visibility = ["//visibility:public"],
)""")

    for alias_target in apple_aliases:
        alias_lines.append(alias_target)

    return """load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_flutter//flutter:utils.bzl", "flutter_pub_scc_member_target")

dart_library(
    name = "merged",
{members}{deps})

{targets}

{aliases}
""".format(
        members = members_block,
        deps = deps_block,
        targets = "\n\n".join(targets),
        aliases = "\n\n".join(alias_lines),
    )

def _format_scc_pub_attrs(assets):
    """Formats pub asset attributes for `_flutter_info`."""
    if not assets:
        return ""
    platforms = (
        assets.pkg_asset_platforms if hasattr(assets, "pkg_asset_platforms") and assets.pkg_asset_platforms else {}
    )
    flavors = (
        assets.pkg_asset_flavors if hasattr(assets, "pkg_asset_flavors") and assets.pkg_asset_flavors else {}
    )
    return format_pub_asset_attrs_with_shaders(
        assets.fonts_json_str,
        assets.font_files,
        assets.pkg_assets,
        assets.pkg_shaders,
        platforms,
        flavors,
    )

def _apple_macos_privacy(apple):
    """Reads macOS privacy manifest paths from `apple`."""
    if not apple:
        return []
    if hasattr(apple, "macos_manifests") and apple.macos_manifests != None:
        return apple.macos_manifests
    if hasattr(apple, "macos_privacy") and apple.macos_privacy != None:
        return apple.macos_privacy
    return []

def _apple_ios_privacy(apple):
    """Reads iOS privacy manifest paths from `apple`."""
    if not apple:
        return []
    if hasattr(apple, "ios_manifests") and apple.ios_manifests != None:
        return apple.ios_manifests
    if hasattr(apple, "ios_privacy") and apple.ios_privacy != None:
        return apple.ios_privacy
    return []

def _render_dart_member_content(package_name, language_version, version, plugin):
    """Renders the `dart_package_member` block (and `test` runner when needed)."""
    code_assets = plugin.code_assets if plugin and hasattr(plugin, "code_assets") else []
    unreplaced_hook = plugin.has_unreplaced_hook if plugin and hasattr(plugin, "has_unreplaced_hook") else ""
    link_hook = plugin.link_hook if plugin and hasattr(plugin, "link_hook") else ""
    package_files = plugin.package_files if plugin and hasattr(plugin, "package_files") else None
    if package_files != None:
        content = make_dart_package_member_build_content(
            package_name,
            language_version,
            merged_label = "//:merged",
            version = version,
            code_assets = code_assets,
            has_unreplaced_hook = unreplaced_hook,
            link_hook = link_hook,
            package_files = package_files,
        )
    else:
        content = make_dart_package_member_build_content(
            package_name,
            language_version,
            merged_label = "//:merged",
            version = version,
            code_assets = code_assets,
            has_unreplaced_hook = unreplaced_hook,
            link_hook = link_hook,
        )
    if package_name != "test":
        return content
    patched = content.replace(
        '    "dart_test_package",\n',
        "",
    ).replace(
        'dart_test_package(\n    name = "test",\n    library = "//:merged",',
        'flutter_test_package(\n    name = "test",\n    library = "//:_test_member",',
    )
    return 'load(":flutter_test_package.bzl", "flutter_test_package")\n' + patched

def _member_extra_targets(package_name, apple, desktop, defines):
    """Renders Apple and desktop plugin library targets for one SCC member."""
    extra_targets = []
    if apple and apple.macos_srcs:
        extra_targets.append(
            apple_plugin_targets(package_name, apple.macos_srcs, apple.macos_includes, "macos", defines),
        )
    if apple and apple.ios_srcs:
        extra_targets.append(apple_plugin_targets(package_name, apple.ios_srcs, apple.ios_includes, "ios", defines))
    if desktop and desktop.linux:
        extra_targets.append(desktop_plugin_target(package_name, desktop.linux, "linux"))
    if desktop and desktop.windows:
        extra_targets.append(desktop_plugin_target(package_name, desktop.windows, "windows"))
    return ("\n" + "\n".join(extra_targets) + "\n") if extra_targets else ""

def make_scc_member_build_content(
        package_name,
        language_version,
        version = "",
        plugin = None,
        assets = None,
        apple = None,
        desktop = None):
    """Generates the BUILD.bazel content for one member of an SCC spoke.

    Args:
        package_name: The member package name.
        language_version: The Dart language version.
        version: Optional package version string.
        plugin: Optional plugin/hook metadata struct.
        assets: Optional asset inputs struct.
        apple: Optional Apple sources detection struct.
        desktop: Optional desktop plugin detection struct.

    Returns:
        The content string for the member BUILD.bazel file.
    """
    macos_srcs = apple.macos_srcs if apple else []
    ios_srcs = apple.ios_srcs if apple else []
    linux_src = desktop.linux if desktop else ""
    windows_src = desktop.windows if desktop else ""
    defines = plugin.defines if plugin and hasattr(plugin, "defines") else []
    platforms_json = plugin.platforms_json if plugin and hasattr(plugin, "platforms_json") else ""

    dart_content = _render_dart_member_content(package_name, language_version, version, plugin)
    dart_loads, dart_body = _split_loads_and_body(dart_content)
    extra_loads, _ = _split_loads_and_body(plugin_extra_loads(macos_srcs, ios_srcs, linux_src, windows_src))
    apple_libs_arg = plugin_apple_libs_arg(package_name, macos_srcs, ios_srcs)
    linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = package_name) if linux_src else ""
    windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = package_name) if windows_src else ""
    privacy_arg = plugin_privacy_files_arg(_apple_macos_privacy(apple), _apple_ios_privacy(apple))
    pub_attrs = _format_scc_pub_attrs(assets)
    is_plugin = bool(
        platforms_json or apple_libs_arg or linux_libs_arg or
        windows_libs_arg or privacy_arg,
    )
    info_rule = "flutter_plugin" if is_plugin else "flutter_library"
    info_load = 'load("@rules_flutter//flutter:defs.bzl", "{rule}")'.format(rule = info_rule)
    merged_loads = _merge_load_blocks(dart_loads + [info_load] + extra_loads)

    platforms_arg = ""
    if platforms_json:
        platforms_arg = "    plugin_platforms_json = %s,\n" % starlark_string_literal(platforms_json)
    elif is_plugin:
        platforms_arg = "    platforms = [],\n"

    info_attrs = (
        platforms_arg + apple_libs_arg + linux_libs_arg +
        windows_libs_arg + privacy_arg + pub_attrs
    )

    return """{loads}

{dart_body}

{info_rule}(
    name = "_flutter_info",
    srcs = [],
    package_name = "{name}",
{member_info_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
exports_files(glob(["**/*"], exclude = ["BUILD*", "WORKSPACE*"]))
""".format(
        loads = merged_loads,
        dart_body = dart_body,
        info_rule = info_rule,
        name = package_name,
        member_info_attrs = info_attrs,
        extra_targets = _member_extra_targets(package_name, apple, desktop, defines),
    )

def _strip_overlay_info_srcs(tail):
    """Replaces `srcs = glob(...lib/...)` with `srcs = []` inside `_flutter_info`."""
    rule_end = tail.find("\n)\n")
    scope = tail[:rule_end] if rule_end >= 0 else tail
    rest = tail[rule_end:] if rule_end >= 0 else ""
    marker = "    srcs = glob("
    idx = scope.find(marker)
    if idx < 0:
        return tail
    close = scope.find("),\n", idx)
    if close < 0 or "lib/" not in scope[idx:close]:
        return tail
    return scope[:idx] + "    srcs = [],\n" + scope[close + len("),\n"):] + rest

def adapt_scc_member_overlay_content(package_name, language_version, version, plugin, overlay_content):
    """Adapts a package's top-level `BUILD.bazel.tpl` overlay for an SCC member.

    Args:
        package_name: The member package name.
        language_version: Derived Dart language version.
        version: Package version string.
        plugin: Optional hook metadata struct.
        overlay_content: Substituted top-level overlay BUILD content.

    Returns:
        Combined member BUILD.bazel content defining `<package_name>` as a
        `dart_package_member` and `_flutter_info` from the overlay's target.
    """
    dart_content = _render_dart_member_content(package_name, language_version, version, plugin)
    dart_loads, dart_body = _split_loads_and_body(dart_content)
    rewritten = overlay_content.replace(
        '"//android:__pkg__"',
        '"//' + package_name + '/android:__pkg__"',
    ).replace(
        '"//:',
        '"//' + package_name + ":",
    )
    name_attr = '    name = "' + package_name + '",\n'
    head, sep, tail = rewritten.partition(name_attr)
    if sep:
        rewritten = head + '    name = "_flutter_info",\n' + _strip_overlay_info_srcs(tail)
    ov_loads, ov_body = _split_loads_and_body(rewritten)
    merged_loads = _merge_load_blocks(dart_loads + ov_loads)
    return (
        merged_loads + "\n\n" +
        dart_body + "\n\n" +
        ov_body + "\n\n" +
        'exports_files(glob(["**/*"], exclude = ["BUILD*", "WORKSPACE*"]))\n'
    )

def adapt_scc_member_android_overlay_content(package_name, overlay_android_content):
    """Rewrites root-relative labels in an SCC member's `android/BUILD.bazel.tpl`.

    Args:
        package_name: Pub package name of the SCC member, used as the label prefix.
        overlay_android_content: Text of the member's `android/BUILD.bazel.tpl` overlay.

    Returns:
        The overlay text with root-relative labels rewritten under `//<package_name>`.
    """
    return overlay_android_content.replace(
        '"//android:__pkg__"',
        '"//' + package_name + '/android:__pkg__"',
    ).replace(
        '"//:',
        '"//' + package_name + ":",
    )

def make_scc_member_android_build_content(
        package_name,
        hub_name = "",
        android_plugin = False,
        overlay_content = ""):
    """Generates `<m>/android/BUILD.bazel` content for one member of an SCC spoke.

    Follows the lazy Android repository model: an Android plugin member aliases
    `@<hub>-android-<member>//android:lib`, an overlaid member adapts its
    `android/BUILD.bazel.tpl`, and every other member emits the empty
    `kt_android_library` stub.

    Args:
        package_name: The member package name.
        hub_name: The `flutter.pub` hub name, used for the Android repo alias.
        android_plugin: Whether `flutter.plugin.platforms.android` is declared.
        overlay_content: Optional substituted `android/BUILD.bazel.tpl` content.

    Returns:
        The content string for the member `android/BUILD.bazel` file.
    """
    if overlay_content:
        return adapt_scc_member_android_overlay_content(package_name, overlay_content)
    if android_plugin:
        return android_spoke_alias_content(android_package_repo_name(hub_name, package_name))
    return make_android_subpackage_build_content(
        android_src_dir = "",
        java_package = "",
        extra_maven_labels = [],
    )
