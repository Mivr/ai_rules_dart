"""Static reader and spoke wiring for CocoaPods plugin .podspec files (POD-12)."""

load(":flutter_apple_plugin_defines.bzl", "dedupe_plugin_defines")
load(
    ":podspec_read_check.bzl",
    "checked_podspec_tokens",
    "podspec_syntax_error",
)
load(
    ":podspec_read_ruby.bzl",
    "format_rhs_raw",
    "lex_podspec_checked",
    "parse_resource_bundles_tokens",
    "parse_string_list_tokens",
)
load(
    ":podspec_read_stmt.bzl",
    "END_OPENERS",
    "read_statement_or_block_open",
    "skip_condition_header",
)
load(
    ":podspec_read_xcconfig.bzl",
    "splice_podspec_defines",
    "xcconfig_hash_defines",
    "xcconfig_merge_defines",
)
load(":starlark_literal.bzl", "starlark_string_literal")

visibility(["//flutter/..."])

_STMT_SKIP_RECVS = (
    "if",
    "unless",
    "elsif",
    "else",
    "case",
    "when",
    "begin",
    "end",
    "return",
)

def podspec_unsupported_field_error(plugin, podspec_path, line, field, raw_value):
    """Format Message 5 for an untranslated podspec field.

    Args:
        plugin: Plugin name string.
        podspec_path: Repository-relative podspec path string.
        line: 1-based line number integer.
        field: Field name as written in podspec.
        raw_value: Raw RHS expression string.

    Returns:
        Formatted error message string.
    """
    return (
        'Flutter plugin "%s": %s:%d declares %s (%s), which rules_flutter does not build for plugins. ' % (
            plugin,
            podspec_path,
            line,
            field,
            raw_value,
        ) + "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
    )

def _normalize_library_name(lib):
    """Normalize CocoaPods library name by stripping 'lib' prefix when len > 3."""
    if len(lib) > 3 and lib.startswith("lib"):
        return lib[3:]
    return lib

def _has_glob_wildcard(s):
    """Check if string contains glob wildcards (*, ?, {, [)."""
    for ch in ("*", "?", "{", "["):
        if ch in s:
            return True
    return False

def _is_valid_privacy_relpath(path_str):
    """True when `path_str` is a safe relative `.xcprivacy` path with no globs or `..`."""
    if not path_str.endswith(".xcprivacy") or _has_glob_wildcard(path_str):
        return False
    if path_str.startswith("/") or "\\" in path_str:
        return False
    segments = path_str.split("/")
    if ":" in segments[0]:
        return False
    kept = []
    for idx in range(len(segments)):
        seg = segments[idx]
        if seg == "" or seg == "..":
            return False
        if seg == "." and idx > 0:
            return False
        if seg != ".":
            kept.append(seg)
    return len(kept) > 0

def _accumulate_unique(target_list, new_items):
    """Append `new_items` to `target_list` preserving first-seen declaration order."""
    for item in new_items:
        if item not in target_list:
            target_list.append(item)

def _is_scope_active(scope, platform):
    """True when podspec platform scope (`""`, `"ios"`, `"osx"`, `"macos"`) matches `platform`."""
    if not scope:
        return True
    if scope == "ios":
        return platform == "ios"
    if scope in ("osx", "macos"):
        return platform == "macos"
    return False

def _is_skipping(block_stack):
    """True when any active enclosing block on `block_stack` skips statements."""
    for entry in block_stack:
        if entry.skip:
            return True
    return False

def _should_skip_opened_block(header, platform):
    """True when `header` opens a `test_spec`, `app_spec`, or inactive platform `subspec`."""
    for idx in range(len(header) - 1):
        if header[idx].kind == "op" and header[idx].text == "." and header[idx + 1].kind == "word":
            if header[idx + 1].text in ("test_spec", "app_spec"):
                return True
    if (
        len(header) >= 5 and
        header[0].kind == "word" and
        header[1].kind == "op" and header[1].text == "." and
        header[2].kind == "word" and
        header[3].kind == "op" and header[3].text == "." and
        header[4].kind == "word" and header[4].text == "subspec"
    ):
        return not _is_scope_active(header[2].text, platform)
    return False

def _parse_attr_assignment(stmt_tokens):
    """Parse `<recv>[.<scope>].<attr> (=|+=) <rhs>` from `stmt_tokens`, or `None`."""
    m = len(stmt_tokens)
    if m < 4 or stmt_tokens[0].kind != "word" or stmt_tokens[0].text in _STMT_SKIP_RECVS:
        return None
    if stmt_tokens[1].kind != "op" or stmt_tokens[1].text != "." or stmt_tokens[2].kind != "word":
        return None
    if stmt_tokens[3].kind == "op" and stmt_tokens[3].text in ("=", "+="):
        return struct(
            scope = "",
            attr = stmt_tokens[2].text,
            line = stmt_tokens[0].line,
            rhs = stmt_tokens[4:],
        )
    if (
        m >= 6 and
        stmt_tokens[3].kind == "op" and stmt_tokens[3].text == "." and
        stmt_tokens[4].kind == "word" and
        stmt_tokens[5].kind == "op" and stmt_tokens[5].text in ("=", "+=")
    ):
        return struct(
            scope = stmt_tokens[2].text,
            attr = stmt_tokens[4].text,
            line = stmt_tokens[0].line,
            rhs = stmt_tokens[6:],
        )
    return None

def _handle_link_field(rhs_tokens, raw_rhs, meta, target_list, is_library):
    """Parse and accumulate `frameworks`, `weak_frameworks`, or `libraries`."""
    parsed = parse_string_list_tokens(rhs_tokens)
    if parsed == None:
        fail(podspec_unsupported_field_error(meta.plugin, meta.path, meta.line, meta.attr, raw_rhs))
    if is_library:
        parsed = [_normalize_library_name(x) for x in parsed]
    _accumulate_unique(target_list, parsed)

def _handle_resources(rhs_tokens, raw_rhs, meta, privacy_manifests):
    """Parse `resources` / `resource`, keeping `.xcprivacy`-only lists and refusing others."""
    parsed = parse_string_list_tokens(rhs_tokens)
    if parsed != None:
        all_privacy = True
        for item in parsed:
            if not _is_valid_privacy_relpath(item):
                all_privacy = False
                break
        if all_privacy:
            _accumulate_unique(privacy_manifests, parsed)
            return
    fail(podspec_unsupported_field_error(meta.plugin, meta.path, meta.line, meta.attr, raw_rhs))

def _handle_resource_bundles(rhs_tokens, raw_rhs, meta, privacy_manifests):
    """Parse `resource_bundles`, keeping `.xcprivacy`-only hashes and refusing others."""
    parsed = parse_resource_bundles_tokens(rhs_tokens)
    if parsed != None:
        all_privacy = True
        for item in parsed:
            if not _is_valid_privacy_relpath(item):
                all_privacy = False
                break
        if all_privacy:
            _accumulate_unique(privacy_manifests, parsed)
            return
    fail(podspec_unsupported_field_error(meta.plugin, meta.path, meta.line, meta.attr, raw_rhs))

def _dispatch_statement_attr(assign, content, plugin, podspec_path, collected):
    """Dispatch a recognized podspec attribute assignment to its POD-12 handler."""
    attr = assign.attr
    raw_rhs = format_rhs_raw(content, assign.rhs)
    meta = struct(plugin = plugin, path = podspec_path, line = assign.line, attr = attr)
    if attr in ("vendored_frameworks", "vendored_framework", "vendored_libraries", "vendored_library"):
        fail(podspec_unsupported_field_error(plugin, podspec_path, assign.line, attr, raw_rhs))
    elif attr in ("frameworks", "framework"):
        _handle_link_field(assign.rhs, raw_rhs, meta, collected.frameworks, False)
    elif attr in ("weak_frameworks", "weak_framework"):
        _handle_link_field(assign.rhs, raw_rhs, meta, collected.weak_frameworks, False)
    elif attr in ("libraries", "library"):
        _handle_link_field(assign.rhs, raw_rhs, meta, collected.libraries, True)
    elif attr in ("resources", "resource"):
        _handle_resources(assign.rhs, raw_rhs, meta, collected.privacy_manifests)
    elif attr == "resource_bundles":
        _handle_resource_bundles(assign.rhs, raw_rhs, meta, collected.privacy_manifests)
    elif attr in ("pod_target_xcconfig", "xcconfig"):
        collected.defines.extend(xcconfig_hash_defines(assign.rhs))

def _step_keyword_at_stmt_start(tokens, n, idx, block_stack):
    """Handle statement-leading block keywords (`end`, `}`, `else`, `elsif`, `if`, ...)."""
    tok = tokens[idx]
    if tok.kind == "nl" or (tok.kind == "op" and tok.text == ";"):
        return idx + 1
    if tok.kind == "op" and tok.text == "}":
        if block_stack and block_stack[-1].closer == "}":
            block_stack.pop()
        return idx + 1
    if tok.kind != "word":
        return -1
    kw = tok.text
    if kw == "end":
        if block_stack and block_stack[-1].closer == "end":
            block_stack.pop()
        return idx + 1
    if kw in ("else", "ensure"):
        return idx + 1
    if kw in ("elsif", "when", "rescue"):
        return skip_condition_header(tokens, n, idx, False)
    if kw == "begin":
        block_stack.append(struct(closer = "end", skip = _is_skipping(block_stack), line = tok.line))
        return idx + 1
    if kw in END_OPENERS:
        block_stack.append(struct(closer = "end", skip = _is_skipping(block_stack), line = tok.line))
        return skip_condition_header(tokens, n, idx, kw in ("while", "until", "for"))
    return -1

def read_plugin_podspec(text, podspec_path, plugin, platform):
    """Statically parse a plugin `.podspec` for SDK link settings and privacy manifests.

    Args:
        text: Full `.podspec` text string.
        podspec_path: Repository-relative path string of the `.podspec`.
        plugin: Pub plugin name string.
        platform: Target Apple platform (`"ios"` or `"macos"`).

    Returns:
        `struct(frameworks, weak_frameworks, libraries, privacy_manifests,
        defines, sdk_frameworks, weak_sdk_frameworks, sdk_dylibs)`; `defines`
        holds the static `GCC_PREPROCESSOR_DEFINITIONS` entries, last wins.
    """
    frameworks = []
    weak_frameworks = []
    libraries = []
    privacy_manifests = []
    defines = []
    collected = struct(
        frameworks = frameworks,
        weak_frameworks = weak_frameworks,
        libraries = libraries,
        privacy_manifests = privacy_manifests,
        defines = defines,
    )
    tokens = checked_podspec_tokens(lex_podspec_checked(text), plugin, podspec_path)
    n = len(tokens)
    block_stack = []
    idx = 0
    for _ in range(n + 1):
        if idx >= n:
            break
        kw_next = _step_keyword_at_stmt_start(tokens, n, idx, block_stack)
        if kw_next >= 0:
            idx = kw_next
            continue
        start_line = tokens[idx].line
        item = read_statement_or_block_open(tokens, n, idx)
        idx = item.next_idx
        if item.is_block:
            skip = _is_skipping(block_stack) or _should_skip_opened_block(item.header, platform)
            block_stack.append(struct(closer = item.closer, skip = skip, line = start_line))
            continue
        if item.open_line:
            fail(podspec_syntax_error(plugin, podspec_path, item.open_line, "an unclosed block"))
        if _is_skipping(block_stack) or not item.tokens:
            continue
        assign = _parse_attr_assignment(item.tokens)
        if assign == None:
            collected.defines.extend(xcconfig_merge_defines(item.tokens, platform))
        elif _is_scope_active(assign.scope, platform):
            _dispatch_statement_attr(assign, text, plugin, podspec_path, collected)
    if block_stack:
        open_line = block_stack[0].line
        fail(podspec_syntax_error(plugin, podspec_path, open_line, "an unclosed block (missing `end` or `}`)"))

    return struct(
        frameworks = frameworks,
        weak_frameworks = weak_frameworks,
        libraries = libraries,
        privacy_manifests = privacy_manifests,
        defines = dedupe_plugin_defines(defines),
        sdk_frameworks = frameworks,
        weak_sdk_frameworks = weak_frameworks,
        sdk_dylibs = libraries,
    )

def resolve_podspec_privacy_path(podspec_dir, rel_path, plugin, podspec_path):
    """Resolve a podspec `.xcprivacy` path relative to `podspec_dir`, rejecting traversal.

    Args:
        podspec_dir: Directory containing the `.podspec` (e.g. `"ios"` or `"darwin"`).
        rel_path: Relative path declared in the `.podspec`.
        plugin: Pub plugin name string.
        podspec_path: Repository-relative `.podspec` path string.

    Returns:
        Normalized repository-relative path string.
    """
    if not _is_valid_privacy_relpath(rel_path):
        fail(
            'Flutter plugin "%s": %s declares invalid privacy manifest path %r ' % (
                plugin,
                podspec_path,
                rel_path,
            ) + '(must be a relative path without ".." segments)',
        )
    segs = [s for s in rel_path.split("/") if s and s != "."]
    prefix = [s for s in podspec_dir.split("/") if s and s != "."]
    return "/".join(prefix + segs)

def _splice_apple_target(content, marker, insert_text, defines):
    """Splice link-setting lines and defines into the target block that follows `marker`.

    Args:
        content: Spoke BUILD content string.
        marker: The `    name = "...",` line that opens the target.
        insert_text: Link-setting attribute lines to insert before `visibility`.
        defines: Podspec defines to splice as `plugin_defines`; empty for none.

    Returns:
        Patched BUILD content string, unchanged when the target is absent.
    """
    head, sep, tail = content.partition(marker)
    if not sep:
        return content
    block, vis_sep, vis_tail = tail.partition("\n    visibility = ")
    if not vis_sep:
        return content
    block = splice_podspec_defines(block, defines)
    return head + sep + block + "\n" + insert_text + "    visibility = " + vis_tail

def splice_apple_podspec_link_settings(content, plugin, apple):
    """Splice non-empty SDK link attributes into a rendered spoke BUILD file.

    Args:
        content: Spoke BUILD content string.
        plugin: Pub plugin name string.
        apple: Struct carrying `ios_podspec` and `macos_podspec`.

    Returns:
        Patched BUILD content string.
    """
    for platform in ("ios", "macos"):
        attr_name = platform + "_podspec"
        podspec = getattr(apple, attr_name) if hasattr(apple, attr_name) else None
        if not podspec:
            continue
        lines = []
        if podspec.frameworks:
            lines.append("    sdk_frameworks = %s," % starlark_string_literal(podspec.frameworks))
        if podspec.weak_frameworks:
            lines.append("    weak_sdk_frameworks = %s," % starlark_string_literal(podspec.weak_frameworks))
        if podspec.libraries:
            lines.append("    sdk_dylibs = %s," % starlark_string_literal(podspec.libraries))
        defines = getattr(podspec, "defines", [])
        if not lines and not defines:
            continue
        insert_text = "\n".join(lines) + "\n" if lines else ""
        for suffix in ("", "_xtool"):
            # The xtool backend compiles in one swiftc call with no define flags, so a
            # podspec's defines reach the rules_apple target only.
            content = _splice_apple_target(
                content,
                '    name = "%s_apple_%s%s",\n' % (plugin, platform, suffix),
                insert_text,
                [] if suffix else defines,
            )
    return content

def _has_darwin_srcs(srcs):
    """True when `srcs` includes a shared `darwin/` source directory."""
    for src in srcs:
        if src == "darwin" or src.startswith("darwin/"):
            return True
    return False

def apply_apple_podspec_link_settings(ctx, content, plugin, apple):
    """Ensure podspecs are validated before dep resolution and splice SDK link settings.

    Args:
        ctx: The spoke's repository context.
        content: Rendered spoke BUILD content string.
        plugin: Pub plugin name string.
        apple: Struct from `detect_apple_plugin_sources` (or minimal `macos_srcs`/`ios_srcs` test struct).

    Returns:
        Patched BUILD content string.
    """
    resolved_apple = apple
    if not hasattr(apple, "ios_podspec") and not hasattr(apple, "macos_podspec"):
        macos_srcs = apple.macos_srcs if hasattr(apple, "macos_srcs") else []
        ios_srcs = apple.ios_srcs if hasattr(apple, "ios_srcs") else []
        resolved_apple = detect_apple_podspecs(
            ctx,
            plugin,
            macos_srcs,
            ios_srcs,
            _has_darwin_srcs(macos_srcs),
            _has_darwin_srcs(ios_srcs),
        )
    return splice_apple_podspec_link_settings(content, plugin, resolved_apple)

def _scan_directory_podspecs(ctx, plugin, dir_path):
    """Scan `dir_path` for `*.podspec` files, failing naming sorted filenames on multiples."""
    dir_node = ctx.path(dir_path)
    podspecs = []
    if dir_node.exists and hasattr(dir_node, "readdir"):
        podspecs = sorted([
            c.basename
            for c in dir_node.readdir()
            if not (hasattr(c, "is_dir") and c.is_dir) and c.basename.endswith(".podspec")
        ])
    if not podspecs:
        single = dir_path + "/" + plugin + ".podspec"
        if ctx.path(single).exists:
            podspecs = [plugin + ".podspec"]
    if len(podspecs) > 1:
        fail('Flutter plugin "%s": multiple podspecs found in %s: %s' % (
            plugin,
            dir_path,
            ", ".join(podspecs),
        ))
    if len(podspecs) == 1:
        return dir_path + "/" + podspecs[0]
    return None

def _discover_platform_podspec_paths(ctx, plugin, platform, shared_darwin):
    """Find active `.podspec` path(s) for `platform` (`<platform>/`, plus `darwin/` when applicable)."""
    plat_spec = _scan_directory_podspecs(ctx, plugin, platform)
    paths = [plat_spec] if plat_spec else []
    if shared_darwin or not plat_spec:
        darwin_spec = _scan_directory_podspecs(ctx, plugin, "darwin")
        if darwin_spec:
            paths.append(darwin_spec)
    return paths

def detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; App Store submission walks the bundle for
    `*.xcprivacy` files and aggregates them into the app's privacy
    report. CocoaPods/SwiftPM bundle them automatically as framework
    resources; we mirror by collecting them here and threading them
    through to `flutter_plugin`'s `apple_privacy_files` select.

    Two source-tree layouts occur in plugins before podspec lookup:

    * **Pattern A** (e.g. `package_info_plus`, `share_plus`):
      `<source_dir>/PrivacyInfo.xcprivacy`.
    * **Pattern B** (e.g. `path_provider_foundation`, `record_ios`,
      `webview_flutter_wkwebview`):
      `<source_dir>/Resources/PrivacyInfo.xcprivacy`.

    Args:
        ctx: The repository context of the repository rule implementation that calls this helper.
        source_dirs: List of source directory relative paths.

    Returns:
        Sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def _read_platform_podspecs(ctx, plugin, platform, srcs, shared_darwin):
    """Read and merge podspec(s) and existing privacy manifests for one Apple platform."""
    manifests = {m: True for m in detect_apple_privacy_manifests(ctx, srcs)}
    if not srcs:
        return None, sorted(manifests.keys())
    spec_paths = _discover_platform_podspec_paths(ctx, plugin, platform, shared_darwin)
    if not spec_paths:
        return None, sorted(manifests.keys())
    frameworks = []
    weak_frameworks = []
    libraries = []
    raw_manifests = []
    defines = []
    for spec_path in spec_paths:
        spec_dir = spec_path[:spec_path.rfind("/")]
        parsed = read_plugin_podspec(ctx.read(spec_path), spec_path, plugin, platform)
        _accumulate_unique(frameworks, parsed.frameworks)
        _accumulate_unique(weak_frameworks, parsed.weak_frameworks)
        _accumulate_unique(libraries, parsed.libraries)
        _accumulate_unique(raw_manifests, parsed.privacy_manifests)
        defines.extend(parsed.defines)
        for rel_m in parsed.privacy_manifests:
            full_p = resolve_podspec_privacy_path(spec_dir, rel_m, plugin, spec_path)
            if ctx.path(full_p).exists:
                manifests[full_p] = True
    merged_podspec = struct(
        frameworks = frameworks,
        weak_frameworks = weak_frameworks,
        libraries = libraries,
        privacy_manifests = raw_manifests,
        defines = dedupe_plugin_defines(defines),
        sdk_frameworks = frameworks,
        weak_sdk_frameworks = weak_frameworks,
        sdk_dylibs = libraries,
    )
    return merged_podspec, sorted(manifests.keys())

def detect_apple_podspecs(
        ctx,
        plugin,
        macos_srcs,
        ios_srcs,
        macos_shared_darwin,
        ios_shared_darwin):
    """Detect and parse platform podspecs, merging existing `.xcprivacy` manifests.

    Args:
        ctx: The repository context of the repository rule implementation that calls this helper.
        plugin: Pub plugin name string.
        macos_srcs: List of macOS source dirs.
        ios_srcs: List of iOS source dirs.
        macos_shared_darwin: Bool for macOS `sharedDarwinSource`.
        ios_shared_darwin: Bool for iOS `sharedDarwinSource`.

    Returns:
        `struct(macos_podspec, ios_podspec, macos_manifests, ios_manifests)`.
    """
    macos_podspec, macos_manifests = _read_platform_podspecs(
        ctx,
        plugin,
        "macos",
        macos_srcs,
        macos_shared_darwin,
    )
    ios_podspec, ios_manifests = _read_platform_podspecs(
        ctx,
        plugin,
        "ios",
        ios_srcs,
        ios_shared_darwin,
    )
    return struct(
        macos_podspec = macos_podspec,
        ios_podspec = ios_podspec,
        macos_manifests = macos_manifests,
        ios_manifests = ios_manifests,
    )
