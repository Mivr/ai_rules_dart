"""Settings translation and BUILD rendering for plugin-local SwiftPM targets.

The detection half of `flutter_pub_apple_local.bzl` walks a plugin manifest and
selects each reached target's files; this half turns one selected target into a
`flutter_apple_plugin_library` or `flutter_apple_plugin_objc_library` call. It
keeps the manifest's C-family settings target-local: a `cSettings` `.define`
lands in `copts`, a `cxxSettings` `.define` in `cxxopts`, and a `.headerSearchPath`
on a helper reached through `implementation_deps`. It also splices the rendered
local targets into the primary spoke BUILD file.
"""

load(":starlark_literal.bzl", "starlark_string_literal")
load(":swiftpm_settings.bzl", "swiftpm_render_list_attr", "swiftpm_target_setting_entries")
load(":swiftpm_translate.bzl", "swiftpm_c99name")

visibility(["//flutter/..."])

def local_missing_dir_error(plugin, target_name, target_dir):
    """The refusal naming a target whose directory does not exist.

    Args:
        plugin: The pub plugin name.
        target_name: The manifest target name.
        target_dir: The directory that is missing on disk.

    Returns:
        The failure string, naming all three verbatim.
    """
    msg = "Flutter plugin %r: local target %r directory %r does not exist."
    return msg % (plugin, target_name, target_dir)

def local_library_name(plugin, platform, target_name):
    """The emitted Bazel library target name of one plugin-local target.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target_name: The manifest target name.

    Returns:
        The target name, formatted as `<plugin>_apple_<platform>__<c99name>`.
    """
    return "%s_apple_%s__%s" % (plugin, platform, swiftpm_c99name(target_name))

def apple_local_normalize_path(target_dir, name):
    """Resolve one `.headerSearchPath` against the target directory.

    Args:
        target_dir: The package-relative target directory.
        name: The manifest's search path.

    Returns:
        `struct(ok, path)`: `path` is package-relative when `ok`.
    """
    out = []
    for s in (target_dir + "/" + name).split("/"):
        if s and s != ".":
            if s == "..":
                if not out:
                    return struct(ok = False, path = "")
                out.pop()
            else:
                out.append(s)
    return struct(ok = True, path = "/".join(out))

def apple_local_setting_entry(setting, target_dir):
    """Translate one C-family setting, folding a sibling search path.

    Args:
        setting: The parsed setting struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, error, text, private_include, platforms)`.
    """
    cond = getattr(setting, "condition", None)
    plat = getattr(cond, "platforms", None) if cond else None
    if getattr(setting, "kind", "") == "headerSearchPath":
        p = apple_local_normalize_path(target_dir, setting.name)
        if not p.ok:
            return struct(
                ok = False,
                error = "headerSearchPath(%r) escapes the repository" % setting.name,
                text = "",
                private_include = False,
                platforms = None,
            )
        return struct(
            ok = True,
            error = "",
            text = p.path,
            private_include = True,
            platforms = plat,
        )
    val = getattr(setting, "value", "")
    def_val = ("=" + val) if val else ""
    return struct(
        ok = True,
        error = "",
        text = "-D" + setting.name + def_val,
        private_include = False,
        platforms = plat,
    )

def apple_local_setting_entries(settings, target_dir):
    """Translate a C-family setting list, allowing a sibling search path.

    Args:
        settings: The parsed `cSettings` or `cxxSettings` list.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, error, flags, private_includes)`.
    """
    flags = []
    p_inc = []
    for s in settings:
        e = apple_local_setting_entry(s, target_dir)
        if not e.ok:
            return struct(ok = False, error = e.error, flags = [], private_includes = [])
        bucket = p_inc if e.private_include else flags
        bucket.append(struct(text = e.text, platforms = e.platforms))
    return struct(ok = True, error = "", flags = flags, private_includes = p_inc)

def apple_local_linkopts(settings):
    """Translate one target's `linkerSettings` list.

    Args:
        settings: The parsed `linkerSettings` list.

    Returns:
        The `struct(text, platforms)` link option entries.
    """
    linkopts = []
    for s in settings:
        cond = getattr(s, "condition", None)
        plat = getattr(cond, "platforms", None) if cond else None
        pfx = "-framework" if getattr(s, "kind", "") == "linkedFramework" else "-l"
        for v in ([pfx, s.name] if pfx == "-framework" else [pfx + s.name]):
            linkopts.append(struct(text = v, platforms = plat))
    return linkopts

def apple_local_clang_settings(target, target_dir):
    """Translate a C-family local target whose search path leaves its dir.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, detail, c_only, cxx, copts, linkopts, private_includes)`.
    """
    c_fold = apple_local_setting_entries(getattr(target, "c_settings", []), target_dir)
    cxx_fold = apple_local_setting_entries(getattr(target, "cxx_settings", []), target_dir)
    if not c_fold.ok or not cxx_fold.ok:
        err = c_fold.error if not c_fold.ok else cxx_fold.error
        return struct(
            ok = False,
            detail = err,
            c_only = [],
            cxx = [],
            copts = [],
            linkopts = [],
            private_includes = [],
        )
    return struct(
        ok = True,
        detail = "",
        c_only = c_fold.flags,
        cxx = cxx_fold.flags,
        copts = [],
        linkopts = apple_local_linkopts(getattr(target, "linker_settings", [])),
        private_includes = c_fold.private_includes + cxx_fold.private_includes,
    )

def apple_local_target_settings(target, target_dir, kind):
    """Translate one local target's settings, reusing the shared translator.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.
        kind: `"swift"` or `"clang"`.

    Returns:
        The shared translator's settings struct.
    """
    translated = swiftpm_target_setting_entries(target, target_dir, kind)
    if translated.ok or kind == "swift" or "escapes the target directory" not in translated.detail:
        return translated
    return apple_local_clang_settings(target, target_dir)

def local_settings_bundle(target, target_dir):
    """Translate both views of one local target's settings.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(settings, clang_settings, swift_settings)`.
    """
    swift = apple_local_target_settings(target, target_dir, "swift")
    clang = apple_local_target_settings(target, target_dir, "clang")
    selected = clang
    c_settings = getattr(target, "c_settings", []) + getattr(target, "cxx_settings", [])
    if (not clang.ok and swift.ok) or (swift.ok and getattr(target, "swift_settings", []) and not c_settings):
        selected = swift
    return struct(settings = selected, clang_settings = clang, swift_settings = swift)

def _render_src_list(name, paths):
    """Render one `name = [...]` source attribute.

    Args:
        name: The rule attribute the rendered list is assigned to, such as `srcs` or `hdrs`.
        paths: The repo-relative file paths.

    Returns:
        The attribute text, empty when there is no path.
    """
    if not paths:
        return ""
    items = ["        %s," % starlark_string_literal(p) for p in paths]
    return "    %s = [\n%s\n    ]," % (name, "\n".join(items))

def _render_plugin_defines(plugin_defines):
    """Render the `plugin_defines = [...]` attribute, or "" when it is empty.

    Args:
        plugin_defines: The `NAME` / `NAME=VALUE` entries for the target.

    Returns:
        The one-line attribute text, or "" when there is no entry.
    """
    if not plugin_defines:
        return ""
    items = ", ".join([starlark_string_literal(entry) for entry in plugin_defines])
    return "    plugin_defines = [%s]," % items

def _render_swift_local(plugin, platform, target, selected, settings, plugin_defines):
    """Render one reached Swift target as a `flutter_apple_plugin_library`.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct from `plugin_local_targets`.
        selected: The selector's `struct(srcs, ...)` for the target.
        settings: The Swift setting entries.
        plugin_defines: The plugin's `ios_plugin_defines` entries.

    Returns:
        The text of the `swift_library` rule that is emitted for the local target.
    """
    lines = [
        "flutter_apple_plugin_library(",
        "    name = %s," % starlark_string_literal(local_library_name(plugin, platform, target.name)),
        _render_src_list("srcs", getattr(selected, "srcs", [])),
        "    module_name = %s," % starlark_string_literal(target.module_name),
        "    platform = %s," % starlark_string_literal(platform),
    ]
    spec = (
        ("deps", target.edges),
        ("copts", getattr(settings, "copts", [])),
        ("linkopts", getattr(settings, "linkopts", [])),
    )
    for attr, entries in spec:
        rendered = swiftpm_render_list_attr(attr, [], entries)
        if rendered:
            lines.append(rendered)
    defines = _render_plugin_defines(plugin_defines)
    if defines:
        lines.append(defines)
    lines.extend(['    visibility = ["//visibility:public"],', ")"])
    return "\n".join([line for line in lines if line])

def _render_settings_struct(public_includes, settings):
    """Render the nested settings struct of one ObjC-only local library.

    Args:
        public_includes: The target's public header search directories.
        settings: The clang setting entries.

    Returns:
        The `settings = flutter_apple_plugin_objc_settings(...)` attribute text.
    """
    lines = ["    settings = flutter_apple_plugin_objc_settings("]
    entries = [
        ("includes", [struct(text = p, platforms = None) for p in public_includes]),
        ("copts", getattr(settings, "c_only", [])),
        ("cxxopts", getattr(settings, "cxx", [])),
        ("linkopts", getattr(settings, "linkopts", [])),
        ("private_includes", getattr(settings, "private_includes", [])),
    ]
    for attr, values in entries:
        rendered = swiftpm_render_list_attr(attr, [], values)
        if rendered:
            lines.extend(["    " + line for line in rendered.split("\n")])
    lines.append("    ),")
    return "\n".join(lines)

def _local_public_includes(target, selected):
    """The public header search directory of one C-family local target.

    Args:
        target: The local target struct.
        selected: The selector's file struct.

    Returns:
        A one-element list when the target has public headers, else [].
    """
    if not getattr(selected, "public_hdrs", []):
        return []
    public_path = getattr(target.target, "public_headers_path", "")
    return [target.dir + "/" + (public_path if public_path else "include")]

def _render_objc_local(plugin, platform, target, selected, settings, plugin_defines):
    """Render one reached C-family target as an ObjC-only library.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct from `plugin_local_targets`.
        selected: The selector's file struct.
        settings: The clang setting entries.
        plugin_defines: The plugin's `ios_plugin_defines` entries.

    Returns:
        The macro-call text.
    """
    srcs = getattr(selected, "c_srcs", []) + getattr(selected, "private_hdrs", [])
    lines = [
        "flutter_apple_plugin_objc_library(",
        "    name = %s," % starlark_string_literal(local_library_name(plugin, platform, target.name)),
        _render_src_list("srcs", srcs) or "    srcs = [],",
        _render_src_list("hdrs", getattr(selected, "public_hdrs", [])) or "    hdrs = [],",
        "    module_name = %s," % starlark_string_literal(target.module_name),
        "    platform = %s," % starlark_string_literal(platform),
    ]
    deps = swiftpm_render_list_attr("deps", [], target.edges)
    if deps:
        lines.append(deps)
    defines = _render_plugin_defines(plugin_defines)
    if defines:
        lines.append(defines)
    lines.extend([
        _render_settings_struct(_local_public_includes(target, selected), settings),
        '    visibility = ["//visibility:public"],',
        ")",
    ])
    return "\n".join(lines)

def _selected_xtool_files(selected):
    """Collect the compilable files a local target contributes to xtool.

    Args:
        selected: The selector's file struct.

    Returns:
        The file path list.
    """
    return (
        getattr(selected, "srcs", []) +
        getattr(selected, "c_srcs", []) +
        getattr(selected, "public_hdrs", []) +
        getattr(selected, "private_hdrs", [])
    )

def _settings_for(target, selected):
    """Pick the translated settings matching a target's source language.

    Args:
        target: The local target struct.
        selected: The selector's file struct.

    Returns:
        `struct(ok, detail, ...)`: the Swift or clang setting translation.
    """
    if getattr(selected, "srcs", []):
        s = getattr(target, "swift_settings", None)
        return s if s != None else apple_local_target_settings(target.target, target.dir, "swift")
    s = getattr(target, "clang_settings", None)
    return s if s != None else apple_local_target_settings(target.target, target.dir, "clang")

def _render_target_library(plugin, platform, target, selected, plugin_defines):
    """Render one reached target by its selected source language.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct.
        selected: The selector's file struct.
        plugin_defines: The plugin's `ios_plugin_defines` entries.

    Returns:
        `struct(ok, error, text)`.
    """
    settings = _settings_for(target, selected)
    if not getattr(settings, "ok", False):
        return struct(
            ok = False,
            error = "Flutter plugin %r: %s." % (plugin, getattr(settings, "detail", "unknown setting")),
            text = "",
        )
    if getattr(selected, "srcs", []):
        rendered_swift = _render_swift_local(plugin, platform, target, selected, settings, plugin_defines)
        return struct(ok = True, error = "", text = rendered_swift)
    rendered_objc = _render_objc_local(plugin, platform, target, selected, settings, plugin_defines)
    return struct(ok = True, error = "", text = rendered_objc)

def render_local_target_blocks(plugin, platform, targets, files_by_target, plugin_defines = []):
    """Render one library per reached plugin-local target.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        targets: The `plugin_local_targets(...).targets` list.
        files_by_target: Dict of target name to the selector's result.
        plugin_defines: The plugin's `ios_plugin_defines` entries, forwarded to
            every rendered target so a reached sibling compiles like the
            primary target.

    Returns:
        `struct(ok, error, text, labels, xtool_files)`.
    """
    blocks = []
    labels = []
    xtool_files = []
    for target in targets:
        selected = files_by_target.get(target.name, files_by_target.get(target.name.lower()))
        if selected == None:
            err = local_missing_dir_error(plugin, target.name, target.dir)
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        if not getattr(selected, "ok", True):
            err = getattr(selected, "error", "unknown selector failure")
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        if getattr(selected, "srcs", []) and getattr(selected, "c_srcs", []):
            err = "Flutter plugin %r: local target %r mixes Swift and C-family sources." % (plugin, target.name)
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        rendered = _render_target_library(plugin, platform, target, selected, plugin_defines)
        if not rendered.ok:
            return rendered
        blocks.append(rendered.text)
        labels.append(":" + local_library_name(plugin, platform, target.name))
        xtool_files.extend(_selected_xtool_files(selected))
    return struct(
        ok = True,
        error = "",
        text = "\n\n".join(blocks),
        labels = labels,
        xtool_files = sorted(xtool_files),
    )

_LOCAL_OBJC_MACRO_LOAD = (
    'load("@rules_flutter//flutter:macos.bzl", ' +
    '"flutter_apple_plugin_objc_library", "flutter_apple_plugin_objc_settings")'
)

def _local_deps_block(labels):
    """Render one `deps = [...]` block for the primary library.

    Args:
        labels: The local library labels.

    Returns:
        The attribute text, ending in a newline.
    """
    items = ["        %s," % starlark_string_literal(label) for label in labels]
    return "    deps = [\n%s\n    ],\n" % "\n".join(items)

def _local_target_block(content, plugin, platform, suffix):
    """Split the rendered BUILD around one primary library target.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        suffix: `""` for the rules_apple library, `"_xtool"` for xtool.

    Returns:
        `struct(found, head, block, tail)`.
    """
    marker = '    name = "%s_apple_%s%s",\n' % (plugin, platform, suffix)
    head, sep, tail = content.partition(marker)
    block, vis_sep, vis_tail = tail.partition("\n    visibility = ")
    if not sep or not vis_sep:
        return struct(found = False, head = "", block = "", tail = "")
    return struct(found = True, head = head + sep, block = block, tail = vis_sep + vis_tail)

def _local_insert_into_list(block, attr, labels):
    """Add labels to an existing Bazel list attribute in one target block.

    Args:
        block: The target's attribute text.
        attr: The attribute name (`deps`, `srcs`).
        labels: The item strings to add.

    Returns:
        `struct(found, block)`: `found` says whether the attribute existed, and `block` is the
        target text with the labels added.
    """
    marker = "    %s = " % attr
    start = block.find(marker)
    if start < 0:
        return struct(found = False, block = block)
    value_start = start + len(marker)
    rest = block[value_start:]
    additions = "\n".join(["        %s," % item for item in labels])
    if rest.startswith("[]"):
        return struct(found = True, block = block[:value_start] + "[\n" + additions + "\n    ]" + rest[2:])
    if rest.startswith("["):
        close = rest.find("\n    ]")
        if close < 0:
            return struct(found = False, block = block)
        patched_rest = rest[:close] + "\n" + additions + rest[close:]
        return struct(found = True, block = block[:value_start] + patched_rest)
    if rest.startswith("select("):
        return struct(found = True, block = block[:value_start] + "[\n" + additions + "\n    ] + " + rest)
    return struct(found = False, block = block)

def _patch_device_deps(content, plugin, platform, labels):
    """Add the local labels to the primary rules_apple library's deps.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        labels: The local library labels.

    Returns:
        The patched BUILD content.
    """
    parts = _local_target_block(content, plugin, platform, "")
    if not parts.found:
        fail("Flutter plugin %r: expected a `%s_apple_%s` library target for its local targets." % (plugin, plugin, platform))
    items = [starlark_string_literal(label) for label in labels]
    patched = _local_insert_into_list(parts.block, "deps", items)
    block = patched.block if patched.found else parts.block + "\n" + _local_deps_block(labels)
    return parts.head + block + parts.tail

def _patch_xtool_srcs(content, plugin, platform, files):
    """Append the local targets' files to the primary xtool library's srcs.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        files: The local target file paths.

    Returns:
        The patched BUILD content.
    """
    parts = _local_target_block(content, plugin, platform, "_xtool")
    if not parts.found:
        fail("Flutter plugin %r: expected a `%s_apple_%s_xtool` library target for its local targets." % (plugin, plugin, platform))
    items = [starlark_string_literal(path) for path in files]
    marker = "    srcs = "
    start = parts.block.find(marker)
    if start < 0:
        fail("Flutter plugin %r: expected `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    value_start = start + len(marker)
    rest = parts.block[value_start:]
    additions = "\n".join(["        %s," % item for item in items])
    is_glob = rest.startswith("glob(")
    close_marker = "\n    )," if is_glob else "\n    ]"
    close = rest.find(close_marker)
    if close < 0:
        fail("Flutter plugin %r: malformed `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    if is_glob:
        split_pos = close + len("\n    )")
        patched_rest = rest[:split_pos] + " + [\n" + additions + "\n    ]" + rest[split_pos:]
    elif rest.startswith("["):
        patched_rest = rest[:close] + "\n" + additions + rest[close:]
    else:
        fail("Flutter plugin %r: unsupported `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    return parts.head + parts.block[:value_start] + patched_rest + parts.tail

def with_apple_local_targets(content, plugin, platform, rendered):
    """Splice one platform's local libraries into the rendered spoke BUILD.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        rendered: The platform's `render_local_target_blocks` result.

    Returns:
        The patched BUILD content.
    """
    if not rendered.text:
        return content
    content = content + "\n" + rendered.text
    content = _patch_device_deps(content, plugin, platform, rendered.labels)
    if rendered.xtool_files:
        content = _patch_xtool_srcs(content, plugin, platform, rendered.xtool_files)
    if "flutter_apple_plugin_objc_library(" in rendered.text and _LOCAL_OBJC_MACRO_LOAD not in content:
        content = _LOCAL_OBJC_MACRO_LOAD + "\n" + content
    return content
