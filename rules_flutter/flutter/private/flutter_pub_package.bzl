"""flutter_pub_package — the `flutter pub get` analog for a single hosted
Flutter pub.dev package.

The rule is rules_dart's `pub_lock_package` plus what makes a package a
Flutter package. It takes `pub_lock_package`'s attributes (the package's
coordinates, the archive URL planning found, the dependency names planning
used and the labels of its own dependencies) and its checked fetch
(`fetch_pub_lock_archive`), then:
  1. Checks the fetched pubspec's dependency names against the planned ones.
  2. Reads the package's pubspec.yaml.
  3. Parses `flutter.plugin.platforms` via `parse_flutter_plugin_block`.
  4. Scans the extracted package tree for per-platform Apple source layouts
     (modern SwiftPM `<platform>/<pkg>/Sources/<pkg>/`, shared-darwin
     `darwin/Classes/`, legacy `<platform>/Classes/`).
  5. Branches on whether a `flutter.plugin` block is present:
       - Absent → emit a plain `dart_library` via rules_dart's
         `make_dart_library_build_content`. Pure-Dart pub packages reach
         consumers exactly as they do under `pub.pub()`.
       - Present → emit a `flutter_plugin` whose `plugin_platforms_json`
         carries the parsed metadata, plus per-platform sub-targets:
         `:<pkg>_apple_macos` / `:<pkg>_apple_ios` `flutter_apple_plugin_library`
         when Apple sources are detected for the corresponding
         `flutter.plugin.platforms.<plat>` entry.

Its dependencies are the `deps` the extension planned, each the hub's alias
(`@<hub>//:<dep>`), so a package joining or leaving a dependency cycle changes
no other package's attributes.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "PUB_HOOK_REPO_ATTRS", "PUB_LOCK_PACKAGE_ATTRS", "derive_language_version", "fetch_pub_lock_archive", "hook_attrs_block", "hook_settings_of_repo", "make_dart_library_build_content")
load("@rules_dart//dart/pub:pub_scc.bzl", "spoke_planned_deps_error")
load("@rules_dart//dart/pub:yaml.bzl", "pubspec_deps", "pubspec_environment_error", "pubspec_sdk_constraint", "yaml_to_json")
load("//flutter/private:flutter_pub_plugin_defines.bzl", "check_plugin_defines", "plugin_defines_attr")
load("//flutter/private:flutter_pub_plugin_deps.bzl", "check_plugin_native_deps")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block", "parse_flutter_plugin_block")
load(":asset_uri.bzl", "normalize_spoke_asset_block")
load(
    ":flutter_pub_apple.bzl",
    _detect_apple_plugin_sources = "detect_apple_plugin_sources",
    _has_files_under = "has_files_under",
    _plugin_apple_libs_arg = "plugin_apple_libs_arg",
    _plugin_extra_loads = "plugin_extra_loads",
    _plugin_extra_targets = "plugin_extra_targets",
    _plugin_privacy_files_arg = "plugin_privacy_files_arg",
)
load(":flutter_pub_apple_local.bzl", "apply_apple_native_deps")
load(":flutter_pub_git.bzl", "fetch_git_package")
load(
    ":flutter_pub_mirror.bzl",
    "link_scoped_file_entry",
    "link_spoke_contents",
    "make_link_scope",
    "mirror_tree_bounded",
)
load(
    ":flutter_pub_package_helpers.bzl",
    _check_pubspec_identity_mismatch = "check_pubspec_identity_mismatch",
    _make_flutter_test_package_bzl_content = "make_flutter_test_package_bzl_content",
    _malformed_pub_version_refusal = "malformed_pub_version_refusal",
    _missing_pubspec_refusal = "missing_pubspec_refusal",
    _parse_pubspec_identity = "parse_pubspec_identity",
    _pub_attrs = "format_spoke_data_attr",
    _pubspec_name_refusal = "pubspec_name_refusal",
    _pubspec_version_refusal = "pubspec_version_refusal",
    _spoke_data_patterns = "spoke_data_patterns",
)
load(":flutter_pub_path.bzl", "path_package_root")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "heredoc_blocks_bound_error")
load(":starlark_literal.bzl", "decode_starlark_escapes", "starlark_string_literal")
load(":swiftpm_resolved.bzl", "pub_spoke_swiftpm_rule_attrs")

visibility(["//flutter/..."])

malformed_pub_version_refusal = _malformed_pub_version_refusal
missing_pubspec_refusal = _missing_pubspec_refusal
parse_pubspec_identity = _parse_pubspec_identity
pubspec_name_refusal = _pubspec_name_refusal
pubspec_version_refusal = _pubspec_version_refusal

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

def _detect_desktop_source_dir(ctx, package_name, platform):
    """Return the Linux/Windows source dir if it contains C/C++ files.

    Pub plugins put Linux sources at `linux/` and Windows sources at
    `windows/`. We surface a single source dir per platform (the
    plugin's own conventions); subdirectories like `linux/include/` are
    swept by the resulting glob.

    Args:
        ctx: The spoke repository context.
        package_name: The pub package the sources belong to.
        platform: `linux` or `windows`.

    Returns:
        The platform directory when it holds C/C++ files, else `""`.
    """
    if _has_files_under(ctx, platform, _DESKTOP_SRC_EXTENSIONS, package_name):
        return platform
    return ""

# The non-Dart remainder of `lib/`, emitted verbatim by both spoke
# generators below — the same partition rules_dart's
# `make_dart_library_build_content` uses, so `srcs + resources = lib/**`
# holds for every spoke whichever generator ran. A published package's
# `lib/` is addressable as `package:<name>/<path>` whatever the extension;
# a spoke that keeps only `*.dart` is a package with pieces missing.
# `resources` is orthogonal to `data`, the files outside `lib/` an app's
# asset bundle reads; a shader under `lib/` is legitimately both.
_RESOURCES_GLOB_BLOCK = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
"""

def _format_version_attr(version):
    """The `version` attr line for a spoke, or nothing when it is unknown.

    Omitted rather than written empty, matching
    `make_dart_library_build_content`. The attribute's only use is agreement
    checking between two records for one package name, and an unstated version
    never conflicts — so a spoke with nothing to say says nothing.

    Args:
        version: The resolved package version, or "".

    Returns:
        A BUILD attribute line, or "".
    """

    # The lock's version string renders through the helper like the rest.
    return "    version = " + starlark_string_literal(version) + ",\n" if version else ""

def make_flutter_library_build_content(
        name,
        deps,
        language_version,
        data_patterns,
        version = "",
        hooks = ""):
    """Generate BUILD content for a non-plugin Flutter spoke shipping fonts/assets/shaders.

    Counterpart to `make_dart_library_build_content` — used when the spoke
    declares anything under `flutter:` other than `plugin:` (e.g.
    cupertino_icons declaring `flutter.fonts`). The same shape a user
    would write by hand: `flutter_library` with the new pub-asset attrs,
    plus the non-Dart `lib/` remainder as `resources`.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        data_patterns: Glob patterns of the package's own files an app's
            asset bundle reads (`spoke_data_patterns`).
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.
        hooks: The package's hook attributes (rules_dart's
            `hook_attrs_block`), or "".

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; every walked
    or declared path below renders through the escaping helper.
    """
    deps_block = _spoke_deps_block(deps)

    pub_attrs = _pub_attrs(data_patterns)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    language_version = "{language_version}",
{version}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        version = _format_version_attr(version),
        asset_attrs = hooks,
        pub_attrs = pub_attrs,
    )

def _spoke_deps_block(deps):
    """The `deps` attribute block for a spoke, or nothing when it has none."""
    if not deps:
        return ""

    # Labels are built from the hub name and lock package names, which hub
    # classification already refused when quotable; each still renders
    # through the escaping helper, so a hostile label lands inert.
    dep_lines = ["        " + starlark_string_literal(dep) + "," for dep in deps]
    return "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

def make_flutter_plugin_build_content(
        name,
        deps,
        language_version,
        plugin_platforms_json,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
        linux_src_dir,
        windows_src_dir,
        data_patterns = [],
        version = "",
        plugin_defines = [],
        hooks = ""):
    """Generate BUILD content for a Flutter plugin spoke.

    Emits a `flutter_plugin` plus optional per-platform
    `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    A plugin's Android sources are not built from this repository: an app's
    Android side comes from its pinned Gradle model, which names the plugin's
    own Gradle project.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        apple_macos_privacy_manifests: `PrivacyInfo.xcprivacy` paths (macOS).
        apple_ios_privacy_manifests: `PrivacyInfo.xcprivacy` paths (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        data_patterns: Glob patterns of the package's own files an app's
            asset bundle reads (`spoke_data_patterns`).
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.
        plugin_defines: Preprocessor defines for this plugin's Apple
            libraries, in the order given. Empty emits no attribute.
        hooks: The package's build and link hook attributes
            (`hook_attrs_block`), or "".

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; the plugin
    JSON and every walked or declared path render through the helper.
    """
    deps_block = _spoke_deps_block(deps)

    extra_loads = _plugin_extra_loads(apple_macos_srcs_dirs, apple_ios_srcs_dirs, linux_src_dir, windows_src_dir)
    extra_targets = _plugin_extra_targets(
        name,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        linux_src_dir,
        windows_src_dir,
        plugin_defines,
    )

    apple_libs_arg = _plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs)

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    linux_libs_arg = '    linux_libs = [":%s_linux"],\n' % name if linux_src_dir else ""
    windows_libs_arg = '    windows_libs = [":%s_windows"],\n' % name if windows_src_dir else ""

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/.
    apple_privacy_files_arg = _plugin_privacy_files_arg(
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
    )

    pub_attrs = _pub_attrs(data_patterns)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
{extra_loads}
flutter_plugin(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    plugin_platforms_json = {plugin_platforms_json_literal},
    language_version = "{language_version}",
{version}{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}\
{apple_privacy_files_arg}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        version = _format_version_attr(version),
        asset_attrs = hooks,
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        plugin_platforms_json_literal = starlark_string_literal(plugin_platforms_json),
        extra_loads = extra_loads,
        extra_targets = extra_targets,
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

def _hooks_block(ctx):
    """The spoke library's hook attributes: rules_dart runs the package's hooks.

    The package's own `hook/build.dart` runs through the Dart SDK's hook
    runner, with the user defines, extra files and network opt-in the
    extension gave this spoke; `hook/link.dart` runs where an app links.
    """
    return hook_attrs_block(
        build_hook = ctx.path("hook/build.dart").exists,
        link_hook = ctx.path("hook/link.dart").exists,
        settings = hook_settings_of_repo(ctx.attr),
        package_name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

_LANGUAGE_VERSION_PLACEHOLDER = "{LANGUAGE_VERSION}"
_DEPS_PLACEHOLDER = "{DEPS}"

# The prefix a spoke label takes in an overlay template before substitution.
# Finding one means the template names a sibling package by hand.
_HUB_DEP_PREFIX = "@{HUB_NAME}__"

def find_hardcoded_language_version(content):
    """Return the literal language version an overlay spells out, or `""`.

    A package's `environment.sdk` is the only place its language version is
    declared; the spoke derives from it and substitutes
    `{LANGUAGE_VERSION}`. A template that writes the version out instead is a
    second declaration of the same fact, and the one that wins — the overlay
    replaces generated content wholesale. The two then drift silently,
    because the overlay ladder is version-ranged: `ext/<pkg>/9/` serves
    every 9.x, so a release that raises the SDK floor keeps the old literal.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending literal (e.g. `"3.3"`), or `""` when the template
        either uses the placeholder or declares no language version.
    """
    marker = "language_version"
    idx = content.find(marker)
    for _ in range(len(content)):
        if idx == -1:
            return ""
        rest = content[idx + len(marker):].lstrip(" ")
        if rest.startswith("="):
            value = rest[1:].lstrip(" ")
            if value.startswith('"'):
                end = value.find('"', 1)
                if end > 0:
                    literal = value[1:end]
                    if literal != _LANGUAGE_VERSION_PLACEHOLDER:
                        return literal
        idx = content.find(marker, idx + len(marker))
    return ""

def find_hardcoded_hub_dep(content):
    """Return the first hand-written sibling-spoke label an overlay names, or `""`.

    A package's dependencies are declared once, by its own pubspec, and the
    spoke derives the Bazel labels from it — intersected with the lock, so a
    generated spoke can never name a repo the hub did not create. An overlay
    that spells the list out instead declares the same fact twice, and this
    copy wins, because an overlay replaces generated content wholesale.

    The two then drift on the package's next release, and the drift is not
    a stale-but-working list: `objective_c` 9.5.0 dropped `native_toolchain_c`
    from `dependencies` (its build hook stopped using it), so the lock stopped
    carrying that package, while the overlay `ext/objective_c/9/` — one
    directory for the whole major — kept asking for `@<hub>__native_toolchain_c`. The build died
    on an unknown repo naming neither `objective_c` nor the overlay.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending label (e.g. `"@{HUB_NAME}__ffi//:ffi"`), or `""`.
    """
    idx = content.find(_HUB_DEP_PREFIX)
    if idx == -1:
        return ""
    end = content.find('"', idx)
    return content[idx:end] if end > 0 else content[idx:]

def render_overlay_deps(dep_labels):
    """Render `dep_labels` as the body of an overlay's `deps = [...]`.

    Emits one quoted, comma-terminated label per line at the eight-space
    indent a template's `deps = [` block sits at, so the substituted BUILD
    file comes out buildifier-clean.

    Args:
        dep_labels: Fully-qualified labels, in the order they should appear.

    Returns:
        The list body, without the enclosing brackets.
    """

    # Labels derive from the package's own pubspec intersected with the
    # lock (names refused quotable at classification); each still renders
    # through the escaping helper before substitution into the template.
    return "\n        ".join([starlark_string_literal(label) + "," for label in dep_labels])

_WRITE_FILE_LOAD = 'load("@bazel_skylib//rules:write_file.bzl", "write_file")\n'
_CAT_HEREDOC_PREFIX = "    cmd = \"cat > $@ <<'EOF'\\n"
_CAT_HEREDOC_SUFFIX = "\\nEOF\\n\",\n)"

def _decode_heredoc_field(source, package_name, template, genrule_name, field):
    """Decode one source-encoded heredoc field, failing the fetch closed.

    Args:
        source: The still-encoded field text cut out of the template.
        package_name: The pub package the overlay belongs to, for the failure.
        template: The overlay template path, for the failure.
        genrule_name: The raw `name` line, naming the genrule in the failure.
        field: Which field failed to decode (`name`, `outs`, or the body).

    Returns:
        The decoded text; fails the fetch naming the package, the template
        and the genrule when the field holds an undecodable escape.
    """
    decoded = decode_starlark_escapes(source)
    if decoded.error != "":
        fail((
            "flutter.pub overlay for \"{pkg}\" ({tpl}): genrule {name} holds " +
            "{error} in its {field}; refusing it rather than emitting " +
            "bytes the heredoc `cat` never wrote."
        ).format(
            pkg = package_name,
            tpl = template,
            name = repr(genrule_name),
            error = decoded.error,
            field = field,
        ))
    return decoded.text

def _peek_heredoc_block(rest):
    """Classify the next `genrule(` block in `rest` without consuming it.

    Shared by the bounded rewrite and its bound check, so the check sees
    exactly what the rewrite would do next: a convertible block left over
    after the bound means the template would otherwise emit partially.

    Args:
        rest: The not-yet-rewritten template tail.

    Returns:
        A `struct(kind, idx, end, body, name_val, out_val)`: `kind` is
        `"none"` (no block, or no heredoc terminator, left), `"plain"`
        (the next block is not a convertible heredoc genrule and stays
        untouched), or `"convert"` (the next block is a heredoc `cat`
        genrule the rewrite replaces; `end` is just past its terminator).
    """
    no_block = struct(kind = "none", idx = -1, end = -1, body = "", name_val = "", out_val = "")
    idx = rest.find("genrule(\n")
    if idx < 0:
        return no_block
    end_idx = rest.find(_CAT_HEREDOC_SUFFIX, idx)
    if end_idx < 0:
        return no_block
    end = end_idx + len(_CAT_HEREDOC_SUFFIX)
    block = rest[idx:end]
    cmd_idx = block.find(_CAT_HEREDOC_PREFIX)
    if cmd_idx < 0:
        return struct(kind = "plain", idx = idx, end = -1, body = "", name_val = "", out_val = "")
    header = block[:cmd_idx]
    body = block[cmd_idx + len(_CAT_HEREDOC_PREFIX):len(block) - len(_CAT_HEREDOC_SUFFIX)]
    name_val = ""
    out_val = ""
    for hline in header.split("\n"):
        s = hline.strip()
        if s.startswith('name = "') and s.endswith('",'):
            name_val = s[len('name = "'):-2]
        elif s.startswith('outs = ["') and s.endswith('"],'):
            out_val = s[len('outs = ["'):-3]
    if not name_val or not out_val:
        return struct(kind = "plain", idx = idx, end = -1, body = "", name_val = "", out_val = "")
    return struct(kind = "convert", idx = idx, end = end, body = body, name_val = name_val, out_val = out_val)

def rewrite_cat_genrules_bounded(content, package_name, template, bound):
    """Rewrite at most `bound` heredoc blocks, reporting leftovers purely.

    Pure core of `_rewrite_cat_genrules`: unit tests drive it with a small
    bound and count blocks. An undecodable escape still fails the fetch
    (see `_decode_heredoc_field`); a bound reached with a convertible block
    left over is reported in `leftover`, and the caller fails the fetch.

    Args:
        content: The substituted overlay template text.
        package_name: The pub package the overlay belongs to, for failures.
        template: The overlay template path, for failures.
        bound: Maximum heredoc blocks to rewrite; tests drive this small.

    Returns:
        A `struct(text, leftover)`: `text` holds the template with each
        rewritten block replaced (plus the untouched tail); `leftover` is
        True when a convertible heredoc block remains.
    """
    out_chunks = []
    rest = content
    for _ in range(bound):
        scanned = _peek_heredoc_block(rest)
        if scanned.kind == "none":
            break
        if scanned.kind == "plain":
            out_chunks.append(rest[:scanned.idx + len("genrule(\n")])
            rest = rest[scanned.idx + len("genrule(\n"):]
            continue

        # The cut-out body (and the parsed `name`/`outs` lines) is Starlark
        # source text: its escapes are still encoded. Decode each to the
        # actual text first, or the escaping helper below escapes the
        # already-escaped text a second time.
        name = _decode_heredoc_field(scanned.name_val, package_name, template, scanned.name_val, "name")
        out = _decode_heredoc_field(scanned.out_val, package_name, template, scanned.name_val, "outs")
        body_text = _decode_heredoc_field(scanned.body, package_name, template, scanned.name_val, "heredoc body")
        body_lines = body_text.split("\n") + [""]

        # Decoded lines are plain values now; every line still renders
        # through the escaping helper on its way into `content`.
        content_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in body_lines])
        replacement = (
            "write_file(\n" +
            "    name = " + starlark_string_literal(name) + ",\n" +
            "    out = " + starlark_string_literal(out) + ",\n" +
            "    content = [\n" +
            content_entries + "\n" +
            "    ],\n" +
            '    newline = "unix",\n' +
            # Public so consumers can read the output through runfiles: the
            # e2e BuildConfig verifier holds a `data` dependency on it, and
            # `bazel build` of the label needs no visibility at all.
            '    visibility = ["//visibility:public"],\n' +
            ")"
        )
        out_chunks.append(rest[:scanned.idx])
        out_chunks.append(replacement)
        rest = rest[scanned.end:]
    out_chunks.append(rest)
    leftover = _peek_heredoc_block(rest).kind == "convert"
    return struct(text = "".join(out_chunks), leftover = leftover)

def _rewrite_cat_genrules(content, package_name = "", template = "", bound = PUB_WALK_BOUND):
    """Rewrite heredoc `cat` `genrule` targets in overlay templates to `write_file`.

    The cut-out heredoc body (and the parsed `name`/`outs` lines) is
    Starlark source text: its escapes are still encoded. Each decodes to
    the actual text before rendering, so the `write_file` output equals the
    bytes the original genrule's `cat` heredoc would have written. An
    undecodable escape fails the fetch, naming the package and the
    template. Every decoded line still renders through
    `starlark_string_literal`; the build-escape fix stays intact. At most
    `bound` blocks are rewritten; a template with more convertible blocks
    fails the fetch naming the package, the template, and the bound,
    instead of emitting part of the template.

    Args:
        content: The substituted overlay template text.
        package_name: The pub package the overlay belongs to, for failures.
        template: The overlay template path, for failures.
        bound: Maximum heredoc blocks to rewrite.

    Returns:
        The template with each heredoc `cat` genrule replaced by an
        equivalent `write_file`, plus the `write_file` load when missing.
    """
    if _CAT_HEREDOC_PREFIX not in content:
        return content
    rewritten = rewrite_cat_genrules_bounded(content, package_name, template, bound)
    if rewritten.leftover:
        fail(heredoc_blocks_bound_error(package_name, template, bound))
    text = rewritten.text
    if _WRITE_FILE_LOAD not in text:
        load_idx = text.find("load(")
        if load_idx >= 0:
            text = text[:load_idx] + _WRITE_FILE_LOAD + text[load_idx:]
        else:
            text = _WRITE_FILE_LOAD + text
    return text

def apply_overlay_substitutions(content, hub_name, package_name, version, language_version, deps, template = ""):
    """Fill an overlay template's placeholders.

    Args:
        content: Raw template text.
        hub_name: Value for `{HUB_NAME}`.
        package_name: Value for `{PKG}`.
        version: Value for `{VERSION}`.
        language_version: Value for `{LANGUAGE_VERSION}`, derived from the
            package's own pubspec.
        deps: Rendered list body for `{DEPS}` (see `render_overlay_deps`),
            derived from the same pubspec-and-lock intersection a generated
            spoke uses.
        template: The overlay template path, naming it in heredoc decode
            failures (see `_rewrite_cat_genrules`).

    Returns:
        The substituted content.
    """
    substituted = content.replace(
        "{HUB_NAME}",
        hub_name,
    ).replace(
        "{PKG}",
        package_name,
    ).replace(
        "{VERSION}",
        version,
    ).replace(
        _LANGUAGE_VERSION_PLACEHOLDER,
        language_version,
    ).replace(
        _DEPS_PLACEHOLDER,
        deps,
    )
    return _rewrite_cat_genrules(substituted, package_name, template)

def _overlay_template(ctx, root_label, package_name, version, lang_version, labels, relpath, guard_hub_deps = False):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with `{HUB_NAME}`,
    `{PKG}`, `{VERSION}`, `{LANGUAGE_VERSION}` and `{DEPS}` substitutions
    applied) on first match. Returns empty string when no template is found.

    `labels` are the spoke labels the package's own pubspec resolves to,
    which `{DEPS}` expands into. `guard_hub_deps` rejects a template that
    hand-writes those labels instead — see `find_hardcoded_hub_dep`. Only the
    top-level BUILD sets it: `{DEPS}` is a Dart dependency list, so it is not
    the right substitute for a label elsewhere.

    Called for `BUILD.bazel.tpl`, the spoke's top-level BUILD that fully
    replaces the auto-generated content.
    """
    anchor = ctx.path(root_label)
    ctx.watch(anchor)
    root = anchor.dirname
    ctx.watch(root)
    pkg_dir = root.get_child(package_name)
    ctx.watch(pkg_dir)

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1 and parts[0]:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        cand_dir = pkg_dir.get_child(candidate) if candidate else pkg_dir
        if candidate:
            ctx.watch(cand_dir)
        tpl = cand_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
            ctx.watch(tpl)
        if tpl.exists:
            content = ctx.read(tpl)
            hardcoded_dep = find_hardcoded_hub_dep(content) if guard_hub_deps else ""
            if hardcoded_dep:
                fail((
                    "overlay template {tpl} hand-writes the dependency " +
                    "`{dep}`.\n" +
                    "A package's dependencies are declared once, by its own " +
                    "pubspec; the spoke derives the labels from it — " +
                    "intersected with the lock, so it can never name a repo " +
                    "the hub did not create. Listing them here declares the " +
                    "same fact twice, and this copy wins, because an overlay " +
                    "replaces generated content wholesale. Because the " +
                    "overlay ladder is version-ranged, a release that changes " +
                    "the package's dependencies then fails on an unknown " +
                    "repo that names neither the package nor this file.\n" +
                    "Write `deps = [\n        {placeholder}\n    ],` instead."
                ).format(
                    tpl = str(tpl),
                    dep = hardcoded_dep,
                    placeholder = _DEPS_PLACEHOLDER,
                ))
            hardcoded = find_hardcoded_language_version(content)
            if hardcoded:
                fail((
                    "overlay template {tpl} sets language_version = \"{value}\".\n" +
                    "A package's language version is declared once, by its own " +
                    "pubspec `environment.sdk`; the spoke derives it and fills in " +
                    "{placeholder}. Spelling it out here declares the same fact " +
                    "twice, and this copy wins — an overlay replaces generated " +
                    "content wholesale. Because the overlay ladder is " +
                    "version-ranged, the two then drift without a build error.\n" +
                    "Write `language_version = \"{placeholder}\"` instead."
                ).format(
                    tpl = str(tpl),
                    value = hardcoded,
                    placeholder = _LANGUAGE_VERSION_PLACEHOLDER,
                ))
            return apply_overlay_substitutions(
                content = content,
                hub_name = ctx.attr.hub_name,
                package_name = package_name,
                version = version,
                language_version = lang_version,
                deps = render_overlay_deps(labels),
                template = str(tpl),
            )
    return ""

resolve_overlay_template = _overlay_template

def _resolve_overlay(ctx, overlay_root_label, package_name, version, language_version, dep_labels):
    """Resolve the top-level BUILD.bazel.tpl overlay.

    Equivalent to `_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the
    common call shape.
    """
    return _overlay_template(
        ctx,
        overlay_root_label,
        package_name,
        version,
        language_version,
        dep_labels,
        "BUILD.bazel.tpl",
        guard_hub_deps = True,
    )

resolve_overlay = _resolve_overlay

def resolve_overlay_roots(ctx, overlay_roots, package_name, version, language_version, dep_labels):
    """Resolve the overlay BUILD content of a package across `overlay_roots`.

    Walks `overlay_roots` in order and stops on the first root that supplies a
    top-level `BUILD.bazel.tpl` for `package_name` at `version`.

    Args:
        ctx: The repository rule context (`repository_ctx`).
        overlay_roots: Anchor labels for candidate overlay trees, ordered by precedence.
        package_name: The pub package name to look up.
        version: The resolved package version string.
        language_version: The Dart language version derived from the package's pubspec.
        dep_labels: Sibling spoke label strings for `{DEPS}` substitution.

    Returns:
        The substituted BUILD content, or `""` when no template was found.
    """
    for overlay_label in overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            package_name,
            version,
            language_version,
            dep_labels,
        )
        if overlay_content:
            return overlay_content
    return ""

def read_spoke_pubspec_data(ctx, path = "pubspec.yaml", label = None):
    """Reads a pubspec the spoke fetched or linked, as decoded data.

    Args:
        ctx: The repository context.
        path: The pubspec, relative to the repository or absolute.
        label: The name for diagnostics; defaults to
            `<package_name>/pubspec.yaml`.

    Returns:
        The pubspec's top-level mapping, `{}` when the file does not exist.
        Fails naming the file on anything `yaml_to_json` refuses.
    """
    if not ctx.path(path).exists:
        return {}
    shown = label if label != None else ctx.attr.package_name + "/pubspec.yaml"
    return yaml_to_json(ctx, [path], [shown])[0]

def _read_spoke_pubspec(ctx, data = None):
    """Projects the extracted `pubspec.yaml` into spoke inputs.

    Returns `struct(raw_deps, language_version, plugin_block, asset_block)`:
    the unfiltered dependency names, the derived language version, and the
    parsed `flutter.plugin` / `flutter` asset blocks (absent-pubspec defaults
    when no pubspec was extracted).

    Args:
        ctx: The spoke's repository context.
        data: The decoded pubspec when the caller already read it (a path
            spoke reads it to plan its links); read here when None.
    """
    raw_deps, language_version = [], ""
    plugin_block = struct(present = False, platforms = {}, implements = "", ffi_plugin = False)
    asset_block = struct(
        fonts = [],
        assets = [],
        shaders = [],
        uses_material_design = False,
        asset_errors = [],
    )
    if data == None:
        data = read_spoke_pubspec_data(ctx) if ctx.path("pubspec.yaml").exists else None
    if data != None:
        sdk_err = pubspec_environment_error(data, ctx.attr.package_name + "/pubspec.yaml")
        if sdk_err:
            fail(sdk_err)
        raw_deps = sorted(pubspec_deps(data))
        language_version = derive_language_version(pubspec_sdk_constraint(data))
        plugin_block = parse_flutter_plugin_block(data)
        asset_block = parse_flutter_assets_block(data)
    return struct(
        raw_deps = raw_deps,
        language_version = language_version,
        plugin_block = plugin_block,
        asset_block = asset_block,
    )

def _spoke_asset_inputs(ctx, package_name, asset_block):
    """What the spoke lists for the files its pubspec names.

    Every entry is normalized through `asset_uri.bzl` first, so the patterns
    name the decoded files. Whether a named file exists, and how it is
    bundled, is the Flutter tool's to say when an app bundles the package.

    Returns `struct(data_patterns, has_contributions)`.
    """
    _ = ctx  # @unused
    normalized = normalize_spoke_asset_block(package_name, asset_block)
    return struct(
        data_patterns = _spoke_data_patterns(normalized, package_name),
        has_contributions = bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders),
    )

def _detect_desktop_plugin_sources(ctx, package_name, plugin_block):
    """Detects Linux/Windows sources when pluginClass is set on that platform.

    The plugin's own `linux/`/`windows/` directory is the canonical
    location. Returns `struct(linux, windows)`.
    """
    linux_info = plugin_block.platforms.get("linux", {})
    windows_info = plugin_block.platforms.get("windows", {})
    linux_src_dir, windows_src_dir = "", ""
    if linux_info and linux_info.get("pluginClass", ""):
        linux_src_dir = _detect_desktop_source_dir(ctx, package_name, "linux")
    if windows_info and windows_info.get("pluginClass", ""):
        windows_src_dir = _detect_desktop_source_dir(ctx, package_name, "windows")
    return struct(linux = linux_src_dir, windows = windows_src_dir)

def _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets):
    """Builds a `flutter_plugin` spoke."""
    package_name = ctx.attr.package_name
    apple = _detect_apple_plugin_sources(ctx, package_name, pubspec.plugin_block)
    desktop = _detect_desktop_plugin_sources(ctx, package_name, pubspec.plugin_block)
    platforms_payload = dict(pubspec.plugin_block.platforms)
    if pubspec.plugin_block.implements:
        platforms_payload["__implements__"] = pubspec.plugin_block.implements
    plugin_platforms_json = json.encode(platforms_payload)
    build_content = make_flutter_plugin_build_content(
        name = package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        hooks = _hooks_block(ctx),
        plugin_platforms_json = plugin_platforms_json,
        apple_macos_srcs_dirs = apple.macos_srcs,
        apple_ios_srcs_dirs = apple.ios_srcs,
        apple_macos_include_dirs = apple.macos_includes,
        apple_ios_include_dirs = apple.ios_includes,
        apple_macos_privacy_manifests = apple.macos_manifests,
        apple_ios_privacy_manifests = apple.ios_manifests,
        linux_src_dir = desktop.linux,
        windows_src_dir = desktop.windows,
        data_patterns = assets.data_patterns,
        plugin_defines = ctx.attr.plugin_defines,
    )
    build_content = apply_apple_native_deps(ctx, package_name, apple, build_content)
    return struct(build_content = build_content)

def _build_library_spoke_content(ctx, pubspec, dep_labels, assets):
    """Builds a `flutter_library` spoke for asset/font/shader contributions.

    No plugin block, but the pubspec has flutter.fonts/assets/shaders:
    a `flutter_library` (rather than `dart_library`) so the metadata
    propagates via FlutterInfo.pub_fonts/pub_assets/pub_shaders to the
    consuming app's bundle aggregator.
    """
    build_content = make_flutter_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        hooks = _hooks_block(ctx),
        data_patterns = assets.data_patterns,
    )
    return struct(build_content = build_content)

def _build_dart_spoke_content(ctx, pubspec, dep_labels):
    """Builds a plain `dart_library` spoke via rules_dart's generator."""
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        hooks = _hooks_block(ctx),
        version = ctx.attr.version,
    )
    if ctx.attr.package_name == "test":
        ctx.file("flutter_test_package.bzl", _make_flutter_test_package_bzl_content(ctx = ctx))
        build_content = build_content.replace(
            '    "dart_test_package",\n',
            "",
        ).replace(
            "dart_test_package(",
            'load(":flutter_test_package.bzl", "flutter_test_package")\n\nflutter_test_package(',
        )
    return struct(build_content = build_content)

def _build_spoke_content(ctx, pubspec, dep_labels, assets):
    """Builds the spoke BUILD content for whichever branch the pubspec selects.

    Returns `struct(build_content)`.
    """
    if pubspec.plugin_block.present:
        return _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets)
    if assets.has_contributions:
        return _build_library_spoke_content(ctx, pubspec, dep_labels, assets)
    return _build_dart_spoke_content(ctx, pubspec, dep_labels)

def _flutter_pub_package_impl(ctx):
    # rules_dart's fetch of a hosted package: a sha256-verified download,
    # the gzip trailer trim, the header scan over the trimmed bytes before
    # `ctx.extract`, and the symlink walk over the extracted tree before
    # anything reads it. A refused archive fails the fetch with rules_dart's
    # diagnostic naming the package and the entry.
    fetch_pub_lock_archive(ctx)
    _generate_spoke(ctx)
    return ctx.repo_metadata(reproducible = True)

def _flutter_pub_git_package_impl(ctx):
    fetch_git_package(
        ctx,
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.url,
        ctx.attr.resolved_ref,
        ctx.attr.git_path,
        "flutter_pub_git_package",
    )
    _generate_spoke(ctx)
    return ctx.repo_metadata(reproducible = True)

def link_scoped_tree_bounded(ctx, node, repo_rel, package_name, package_realpath, workspace_realpath, linked, bound):
    """Mirror one real source directory into the spoke, reporting leftovers.

    Traversal core of the path-package link walk (the `ctx.symlink` /
    `ctx.watch` calls are the only effects): unit tests drive it with a
    small bound and a fake directory listing. Returns True when
    directories are left unvisited, and the caller fails the fetch.

    This is the case-sensitive entry point the walk tests pin; the fetch
    itself builds a link scope (see `make_link_scope`) and runs
    `mirror_tree_bounded` directly.

    Args:
        ctx: The path-package spoke's repository context.
        node: The workspace-side source directory node.
        repo_rel: The spoke-relative path the directory mirrors to.
        package_name: The pub package linked, for refusals.
        package_realpath: The resolved package directory, for cycle checks.
        workspace_realpath: The resolved workspace root, for confinement.
        linked: Dict of already-linked spoke paths, updated in place.
        bound: Maximum directory pops; tests drive this small.

    Returns:
        True when directories are left unvisited at the bound.
    """
    scope = make_link_scope(package_name, package_realpath, workspace_realpath, False, linked)
    seed = (str(node.realpath),)
    result = mirror_tree_bounded(ctx, [(node, repo_rel, seed, repo_rel)], scope, bound)
    if result.error:
        fail(result.error)
    return result.leftover

def path_spoke_platform_dirs(plugin_block):
    """The platform directories the spoke generator reads for a plugin.

    Pure testable core of the link plan: a declared platform's directory
    is where the generator probes for manifests and native
    sources, so only declared platforms get linked.

    Args:
        plugin_block: The parsed plugin block (or `_EMPTY_PLUGIN`).

    Returns:
        The sorted platform directory names to link, possibly empty.
    """
    platforms = plugin_block.platforms
    dirs = []
    if "android" in platforms:
        dirs.append("android")
    if "ios" in platforms or "macos" in platforms:
        dirs.extend(["darwin", "ios", "macos"])
    if "linux" in platforms:
        dirs.append("linux")
    if "windows" in platforms:
        dirs.append("windows")
    return sorted(dirs)

def link_path_package(ctx, read_pubspec = None):
    """Symlinks a workspace-local `path:` package into the spoke, hermetically.

    The link plan parses the package's own `pubspec.yaml` from the spoke:
    `lib/`, the pubspec, hook scripts, declared assets/fonts/shaders (plus
    each shader's own directory), and the plugin's platform directories are
    mirrored one file at a time into real repository directories — never
    whole-directory symlinks, not even for a directory that arrives as a
    symlink (linked directories resolve, confine, cycle-check, and mirror
    file by file with watched entries) — so the generator's `ctx.file`
    writes land in the spoke, never in the user tree. `example/`, `build/`,
    `.dart_tool/`, dot-directories, undeclared files, and user BUILD files
    stay unlinked (skipped top-level subtrees are not even watched, while
    every declared path is watched before testing whether it exists, so
    creating it later refetches the spoke). Refused, naming the package
    and the offending node, because each would break the hermetic fetch:
    source links resolving to the package or an ancestor (fetch-time walk
    cycles), a symlink cycle anywhere in the mirrored tree, and the package
    directory itself, any of its parent components, or any replicated
    symlink resolving outside the workspace's real root (host bytes in the
    bundle). Path comparisons fold case exactly when the fetch host proves
    case-insensitive. The pubspec's own `name` and `version` must match the
    lock entry, since overlays and code assets are selected by lock name
    and version (a pubspec with no `version:` field reads as `0.0.0`, the
    way `pub get` locks it, and the two versions compare as parsed semantic
    versions). Fails closed: an absolute path, a `..` escape, or a missing
    directory fails the fetch rather than emitting an empty spoke or
    reaching outside the workspace.

    Args:
        ctx: The path-package spoke's repository context. Reads `path`,
            `package_name`, `version`, and `hub_name` from its attrs.
        read_pubspec: Reads the linked `pubspec.yaml` as decoded data from
            `ctx`; defaults to `read_spoke_pubspec_data`, which runs `yaml2json`.

    Returns:
        The decoded pubspec when the package has one (else None), for the
        spoke generator to reuse.
    """
    root = path_package_root(ctx)
    src = root.src
    package_name = ctx.attr.package_name
    scope = make_link_scope(
        package_name,
        root.package_realpath,
        root.workspace_realpath,
        root.case_insensitive,
        {},
    )

    # The pubspec leads: link it first, then parse the spoke-side copy for
    # the link plan, so the spoke links only what the generator reads or
    # exposes. A missing pubspec parses as empty rather than failing: the
    # spoke pipeline reports the real problem.
    link_scoped_file_entry(ctx, src, "pubspec.yaml", scope)
    read = read_pubspec if read_pubspec != None else read_spoke_pubspec_data
    pubspec = read(ctx) if ctx.path("pubspec.yaml").exists else None
    _check_pubspec_identity_mismatch(ctx.attr.hub_name, package_name, ctx.attr.version, pubspec or {})
    link_spoke_contents(
        ctx,
        src,
        normalize_spoke_asset_block(package_name, parse_flutter_assets_block(pubspec or {})),
        path_spoke_platform_dirs(parse_flutter_plugin_block(pubspec or {})),
        scope,
    )
    ctx.watch(src)
    return pubspec

def _flutter_pub_path_package_impl(ctx):
    pubspec = link_path_package(ctx)
    _generate_spoke(ctx, pubspec)

def _verify_spoke_deps(ctx, pubspec):
    """Checks the fetched pubspec's names against `planned_deps`; returns the planned labels.

    The labels are the extension's, from the planned names: the hub alias of
    every planned dependency the lock pins, less the edges `cycle_breaks`
    drops. They are right only when the planned names are the real ones,
    so a difference fails the fetch here.
    """
    if hasattr(ctx.attr, "resolved_ref"):
        rule_name = "flutter_pub_git_package"
    elif hasattr(ctx.attr, "sha256"):
        rule_name = "flutter_pub_package"
    else:
        rule_name = "flutter_pub_path_package"
    planned_err = spoke_planned_deps_error(
        rule_name,
        ctx.name,
        ctx.attr.package_name,
        ctx.attr.planned_deps,
        pubspec.raw_deps,
    )
    if planned_err:
        fail(planned_err)
    return list(ctx.attr.deps)

def spoke_dep_labels(deps, asset_block):
    """The spoke's dependency labels: its planned ones.

    The Material icons a pubspec asks for with `uses-material-design` are
    bundled by the app's asset tool from the Flutter root, not reached
    through a dependency.

    Args:
        deps: The planned dependency labels.
        asset_block: The parsed `flutter` asset block (unused).

    Returns:
        The labels.
    """
    _ = asset_block  # @unused
    return deps

def _generate_spoke(ctx, pubspec_data = None):
    """Runs the shared spoke pipeline: pubspec in, BUILD content out.

    The package's Android directory is never read here: an app's Android
    side is built from its pinned Gradle model.
    """
    pubspec = _read_spoke_pubspec(ctx, pubspec_data)
    dep_labels = spoke_dep_labels(_verify_spoke_deps(ctx, pubspec), pubspec.asset_block)

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    assets = _spoke_asset_inputs(ctx, ctx.attr.package_name, pubspec.asset_block)

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content = resolve_overlay_roots(
        ctx,
        ctx.attr.overlay_roots,
        ctx.attr.package_name,
        ctx.attr.version,
        pubspec.language_version,
        dep_labels,
    )

    has_deps = bool(ctx.attr.plugin_native_deps) and not overlay_content
    apple = _detect_apple_plugin_sources(ctx, ctx.attr.package_name, pubspec.plugin_block) if has_deps else None
    check_plugin_defines(ctx, ctx.attr.package_name, pubspec.plugin_block, bool(overlay_content))
    check_plugin_native_deps(ctx, ctx.attr.package_name, apple, bool(overlay_content))

    if overlay_content:
        # An overlay replaces auto-generation entirely.
        ctx.file("BUILD.bazel", overlay_content)
        return

    spoke = _build_spoke_content(ctx, pubspec, dep_labels, assets)
    ctx.file("BUILD.bazel", spoke.build_content)

spoke_asset_inputs = _spoke_asset_inputs
detect_desktop_plugin_sources = _detect_desktop_plugin_sources

# What every Flutter package repository adds to the planned shape, hosted or
# path: the hub it belongs to, the plugin's native configuration and the
# overlays that can replace its BUILD file.
_FLUTTER_SPOKE_ATTRS = {
    "hub_name": attr.string(
        doc = "Name of the hub repo (for the hub's files).",
        mandatory = True,
    ),
    "cycle_deps": attr.string_dict(
        doc = "The package's own planned dependencies that are members of a dependency " +
              "cycle, each to its merged repository: the slice of the plan an Apple plugin " +
              "needs to name a sibling plugin's library without reading `hub_packages`.",
        default = {},
    ),
    "hub_packages": attr.label(
        doc = "The hub's `pub_packages.json`, read only by an Apple plugin that names a " +
              "sibling plugin outside its own dependencies (`planned_deps`), so no other " +
              "spoke depends on the hub's package list.",
        allow_single_file = True,
        default = None,
    ),
    "plugin_defines": plugin_defines_attr,
    "overlay_roots": attr.label_list(
        doc = "BUILD.bazel anchors for overlay trees. Each label points at " +
              "an `ext/BUILD.bazel` (or equivalent) that anchors a directory " +
              "tree of `<package>/<version>/BUILD.bazel.tpl` overrides. The " +
              "rule walks the roots in order and uses the first match. " +
              "User-supplied roots come before the bundled " +
              "`@rules_flutter//ext:BUILD.bazel`.",
        allow_files = True,
        default = [],
    ),
    "pubspec_lock": attr.label(doc = "Hub `pubspec.lock` label.", allow_single_file = True, default = None),
}

flutter_pub_package = repository_rule(
    implementation = _flutter_pub_package_impl,
    attrs = pub_spoke_swiftpm_rule_attrs(dict(PUB_LOCK_PACKAGE_ATTRS, **_FLUTTER_SPOKE_ATTRS)),
    doc = "Fetches a single hosted Flutter pub package the way rules_dart's `pub_lock_package` does and emits a `flutter_plugin` (when `flutter.plugin` is present), a `flutter_library` (when it declares assets, fonts or shaders) or a plain `dart_library`. When Apple sources are detected, also emits per-platform `flutter_apple_plugin_library` sub-targets. Honors per-package overlay BUILD.bazel.tpl overrides under `overlay_roots`. The `flutter pub get` analog of `pub_lock_package`.",
)

flutter_pub_path_package = repository_rule(
    implementation = _flutter_pub_path_package_impl,
    attrs = pub_spoke_swiftpm_rule_attrs(dict(_FLUTTER_SPOKE_ATTRS, **({
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Workspace-relative directory of the package (the lock's `path:` value, relative to the lock file). Symlinked in; absolute paths and `..` escapes fail the fetch, as does anything — the package directory, its parent components, or a replicated symlink — resolving outside the workspace's real root.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version, when the lock states one. Empty stays " +
                  "unstated and never conflicts, matching the hosted rule.",
            default = "",
        ),
        "planned_deps": PUB_LOCK_PACKAGE_ATTRS["planned_deps"],
        "deps": PUB_LOCK_PACKAGE_ATTRS["deps"],
    } | PUB_HOOK_REPO_ATTRS))),
    doc = "Symlinks a workspace-local `path:` pub package into a spoke and emits the same `flutter_plugin` / `flutter_library` / `dart_library` the hosted rule would. The `flutter pub get` analog for path dependencies: hermetic (workspace-relative only, watched for changes) and fail-closed on anything resolving outside the workspace's real root; the package's pubspec `name` and `version` must match the lock entry, since overlays are selected by lock name and version.",
)

# A git package's coordinates in the lock, as `flutter_pub_git_package` takes them.
GIT_PACKAGE_ATTRS = {
    "url": attr.string(
        doc = "The git remote (the lock entry's `description.url`).",
        mandatory = True,
    ),
    "resolved_ref": attr.string(
        doc = "The locked commit (`description.resolved-ref`), a full 40-hex SHA.",
        mandatory = True,
    ),
    "git_path": attr.string(
        doc = "The package's directory inside the git repository (`description.path`); `.` is its root.",
        default = ".",
    ),
}

flutter_pub_git_package = repository_rule(
    implementation = _flutter_pub_git_package_impl,
    attrs = pub_spoke_swiftpm_rule_attrs(dict(_FLUTTER_SPOKE_ATTRS, **dict(GIT_PACKAGE_ATTRS, **({
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The locked version.",
            default = "",
        ),
        "planned_deps": PUB_LOCK_PACKAGE_ATTRS["planned_deps"],
        "deps": PUB_LOCK_PACKAGE_ATTRS["deps"],
    } | PUB_HOOK_REPO_ATTRS)))),
    doc = "Fetches a git-sourced Flutter pub package at its locked commit, the way rules_dart's `pub_lock_git_package` does, and emits the same `flutter_plugin` / `flutter_library` / `dart_library` the hosted rule would.",
)
