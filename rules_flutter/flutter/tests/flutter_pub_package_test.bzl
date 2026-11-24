"""Unit tests for the BUILD content `flutter_pub_package.bzl` generates and for plugin overlays."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:yaml.bzl", "pubspec_environment_error")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "apply_overlay_substitutions",
    "find_hardcoded_hub_dep",
    "find_hardcoded_language_version",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
    "render_overlay_deps",
    "resolve_overlay",
    "resolve_overlay_roots",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

# The non-Dart remainder of `lib/` — the same partition rules_dart's
# `make_dart_library_build_content` emits. `srcs + resources = lib/**`
# for every spoke, whichever generator ran; a published package's `lib/`
# is addressable as `package:<name>/<path>` whatever the extension, so a
# spoke that keeps only `*.dart` is a package with pieces missing.
_RESOURCES_GLOB = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),"""

def _spokes_state_their_resolved_version_test_impl(ctx):
    """Every Flutter spoke shape emits the version pub resolved it at.

    The attribute has one use: when a single package name arrives from two
    hubs, two records stating different versions fail the build instead of the
    first silently standing in for the second. A spoke that omits it is
    invisible to that check, because an unstated version never conflicts — so
    "the value reached the generated BUILD file" is the whole contract, and
    it has to hold for the plugin and library shapes as well as the plain
    `dart_library` one rules_dart emits.

    `e2e/dual_hub` is the other half of this: it pins that two spokes stating
    *different* versions actually fail a build that collects both.
    """
    env = unittest.begin(ctx)

    plugin = make_flutter_plugin_build_content(
        name = "sqlite3_web",
        deps = [],
        language_version = "3.4",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        version = "2.2.0",
    )
    asserts.true(env, '\n    version = "2.2.0",' in plugin, plugin)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        data_patterns = [],
        version = "1.0.8",
    )
    asserts.true(env, '\n    version = "1.0.8",' in library, library)

    return unittest.end(env)

spokes_state_their_resolved_version_test = unittest.make(
    _spokes_state_their_resolved_version_test_impl,
)

def _spoke_without_a_version_states_none_test_impl(ctx):
    """An unknown version emits no attribute rather than an empty one.

    `version = ""` and no `version` at all mean the same thing to the
    agreement check — neither conflicts with anything — so the line is omitted
    rather than written blank, matching what rules_dart's own spoke generator
    does. A spoke that wrote `version = ""` would read as a package asserting
    it has no version, which is not what "we could not resolve one" means.
    """
    env = unittest.begin(ctx)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        data_patterns = [],
    )

    # The newline and indent matter: a bare `"version = "` also matches
    # `language_version = `, which every spoke states and which this is not
    # about.
    asserts.false(env, "\n    version = " in library, library)

    return unittest.end(env)

spoke_without_a_version_states_none_test = unittest.make(
    _spoke_without_a_version_states_none_test_impl,
)

def _plugin_spoke_carries_resources_test_impl(ctx):
    """A plugin spoke's BUILD partitions lib/ into srcs + resources."""
    env = unittest.begin(ctx)

    content = make_flutter_plugin_build_content(
        name = "sqlite3_web",
        deps = [],
        language_version = "3.4",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)

    return unittest.end(env)

plugin_spoke_carries_resources_test = unittest.make(_plugin_spoke_carries_resources_test_impl)

def _plugin_defines_reach_the_generated_build_test_impl(ctx):
    """A plugin spoke carries its defines into both generated Apple calls."""
    env = unittest.begin(ctx)

    base = make_flutter_plugin_build_content(
        name = "permission_handler_apple",
        deps = [],
        language_version = "3.4",
        plugin_platforms_json = '{"ios":{"pluginClass":"PermissionHandlerPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = ["ios/Classes"],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
    )
    defines = ["PERMISSION_CAMERA=1", "PERMISSION_MICROPHONE"]
    content = make_flutter_plugin_build_content(
        name = "permission_handler_apple",
        deps = [],
        language_version = "3.4",
        plugin_platforms_json = '{"ios":{"pluginClass":"PermissionHandlerPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = ["ios/Classes"],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        plugin_defines = defines,
    )
    defines_block = "    plugin_defines = {},\n".format(starlark_string_literal(defines))
    asserts.equals(env, 2, content.count(defines_block))
    asserts.equals(
        env,
        base.replace("    includes = [],\n", "    includes = [],\n" + defines_block),
        content,
    )
    asserts.equals(env, base, make_flutter_plugin_build_content(
        name = "permission_handler_apple",
        deps = [],
        language_version = "3.4",
        plugin_platforms_json = '{"ios":{"pluginClass":"PermissionHandlerPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = ["ios/Classes"],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
    ))
    return unittest.end(env)

plugin_defines_reach_the_generated_build_test = unittest.make(
    _plugin_defines_reach_the_generated_build_test_impl,
)

def _library_spoke_carries_resources_test_impl(ctx):
    """A flutter_library spoke keeps lib/'s non-Dart remainder alongside its declared assets.

    The two channels coexist by design: `resources` says the file is part
    of the package's `lib/` tree (staged wherever the whole package is),
    while `data` lists the files the pubspec names for the asset bundle.
    A shader under `lib/` is legitimately both.
    """
    env = unittest.begin(ctx)

    content = make_flutter_library_build_content(
        name = "shader_pkg",
        deps = [],
        language_version = "3.4",
        data_patterns = ["lib/glow.frag"],
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)
    asserts.true(env, '"lib/glow.frag"' in content, content)

    return unittest.end(env)

library_spoke_carries_resources_test = unittest.make(_library_spoke_carries_resources_test_impl)

def _overlay_substitutes_the_language_version_test_impl(ctx):
    """An overlay declares the language version by placeholder, never by value.

    The package's own `environment.sdk` is the single source of truth; the
    spoke derives from it and substitutes here. A template that spelled the
    version out would be a second declaration of the same fact, and the
    version ladder makes the two drift silently: `ext/objective_c/9/` matches
    every 9.x, so a release that raises the SDK floor keeps the stale literal.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", v = "{VERSION}", h = "{HUB_NAME}")',
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.3.0",
        language_version = "3.10",
        deps = "",
    )

    asserts.equals(
        env,
        'flutter_plugin(name = "objective_c", language_version = "3.10", v = "9.3.0", h = "hub")',
        rendered,
    )

    return unittest.end(env)

def _overlay_without_a_language_version_is_left_alone_test_impl(ctx):
    """Not every overlay declares one; substitution must not invent the attribute."""
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'cc_library(name = "{PKG}")',
        hub_name = "hub",
        package_name = "jni",
        version = "1.0.0",
        language_version = "3.3",
        deps = "",
    )

    asserts.equals(env, 'cc_library(name = "jni")', rendered)

    return unittest.end(env)

def _hardcoded_language_version_is_rejected_test_impl(ctx):
    """A literal version in an overlay is caught, not silently obeyed.

    Substitution alone only *permits* a single declaration; this is what
    makes a second one impossible. Without it an overlay could keep spelling
    the version out and quietly win over the derived value, which is the
    state this check was written to end.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "3.3",
        find_hardcoded_language_version('flutter_plugin(\n    language_version = "3.3",\n)'),
    )

    # Whitespace around `=` is a style choice buildifier can change; the
    # check must not be evadable by reformatting.
    asserts.equals(
        env,
        "3.10",
        find_hardcoded_language_version('    language_version="3.10",'),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(
        env,
        "",
        find_hardcoded_language_version('    language_version = "{LANGUAGE_VERSION}",'),
    )

    # An overlay that declares none is fine.
    asserts.equals(env, "", find_hardcoded_language_version('cc_library(name = "x")'))

    return unittest.end(env)

hardcoded_language_version_is_rejected_test = unittest.make(
    _hardcoded_language_version_is_rejected_test_impl,
)

overlay_substitutes_the_language_version_test = unittest.make(
    _overlay_substitutes_the_language_version_test_impl,
)
overlay_without_a_language_version_is_left_alone_test = unittest.make(
    _overlay_without_a_language_version_is_left_alone_test_impl,
)

def _overlay_substitutes_the_dependencies_test_impl(ctx):
    """An overlay names its dependencies by placeholder, never by hand.

    The package's own pubspec is the single source of truth; the spoke
    intersects it with the lock and substitutes the labels here. The rendered
    body carries the eight-space indent a `deps = [` block sits at, so the
    substituted BUILD file is buildifier-clean.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = "flutter_plugin(\n    deps = [\n        {DEPS}\n    ],\n)",
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.6.0",
        language_version = "3.10",
        deps = render_overlay_deps([
            "@hub__ffi//:ffi",
            "@hub__meta//:meta",
        ]),
    )

    asserts.equals(
        env,
        'flutter_plugin(\n    deps = [\n        "@hub__ffi//:ffi",\n        "@hub__meta//:meta",\n    ],\n)',
        rendered,
    )

    # A package with no in-lock dependencies renders an empty list, not a
    # dangling comma or a missing attribute.
    asserts.equals(env, "", render_overlay_deps([]))

    return unittest.end(env)

def _hardcoded_overlay_dependency_is_rejected_test_impl(ctx):
    """A hand-written sibling label in an overlay is caught, not obeyed.

    This is the check that would have caught the `objective_c` break:
    9.5.0 dropped `native_toolchain_c` from its `dependencies`, so the lock
    stopped carrying it and the hub stopped creating the spoke, while
    `ext/objective_c/9/` — one directory for the whole major — kept asking
    for `@<hub>__native_toolchain_c`. The build died on an unknown repo
    naming neither `objective_c` nor the overlay that referenced it.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",
        find_hardcoded_hub_dep(
            '    deps = [\n        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",\n    ],',
        ),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(env, "", find_hardcoded_hub_dep("    deps = [\n        {DEPS}\n    ],"))

    # Naming {HUB_NAME} outside a spoke label — a doc comment, say — is not
    # the thing being prohibited.
    asserts.equals(env, "", find_hardcoded_hub_dep("# {HUB_NAME} is substituted here."))

    # A label pointing at another repo entirely stays allowed: only sibling
    # spokes are derivable from the pubspec.
    asserts.equals(
        env,
        "",
        find_hardcoded_hub_dep('    deps = ["@rules_flutter//flutter:material_icons"],'),
    )

    return unittest.end(env)

overlay_substitutes_the_dependencies_test = unittest.make(
    _overlay_substitutes_the_dependencies_test_impl,
)
hardcoded_overlay_dependency_is_rejected_test = unittest.make(
    _hardcoded_overlay_dependency_is_rejected_test_impl,
)

def _make_mock_overlay_ctx(files, root_anchors = None, hub_name = "deps"):
    """Construct a fake repository_ctx recording ctx.watch and ctx.read calls.

    Args:
        files: Dict mapping absolute path string -> file content string.
        root_anchors: Optional dict mapping anchor label string -> absolute
            anchor file path. Defaults to `{"//plugin_overlays:BUILD.bazel":
            "/workspace/plugin_overlays/BUILD.bazel"}`.
        hub_name: Value for `ctx.attr.hub_name`.

    Returns:
        A struct with `.ctx`, `.watched` (list of watched path strings), and
        `.probed` (list of all path strings constructed via `get_child`).
    """
    anchors = root_anchors if root_anchors != None else {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
    }
    existing_paths = {}
    for anchor_path in anchors.values():
        existing_paths[anchor_path] = True
        parent = anchor_path.rsplit("/", 1)[0] if "/" in anchor_path else ""
        if parent:
            existing_paths[parent] = True
    for file_path in files.keys():
        existing_paths[file_path] = True
        parts = file_path.split("/")
        for i in range(1, len(parts)):
            prefix = "/".join(parts[:i])
            if prefix:
                existing_paths[prefix] = True

    watched = []
    probed = []

    def _make_path(path_str):
        parent_str = path_str.rsplit("/", 1)[0] if "/" in path_str else ""

        def _get_child(segment):
            child_str = path_str + "/" + segment
            probed.append(child_str)
            return _make_path(child_str)

        return struct(
            path = path_str,
            exists = path_str in existing_paths,
            dirname = struct(
                path = parent_str,
                exists = parent_str in existing_paths,
                get_child = lambda seg: _get_child_from(parent_str, seg),
            ) if parent_str else None,
            get_child = _get_child,
        )

    def _get_child_from(base_str, segment):
        child_str = base_str + "/" + segment
        probed.append(child_str)
        return _make_path(child_str)

    def _path(label_or_str):
        key = str(label_or_str)
        resolved = anchors.get(key, key)
        return _make_path(resolved)

    def _watch(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        watched.append(p)

    def _read(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        if p not in files:
            fail("mock ctx.read on missing file: " + p)
        return files[p]

    return struct(
        ctx = struct(
            attr = struct(hub_name = hub_name),
            path = _path,
            watch = _watch,
            read = _read,
        ),
        watched = watched,
        probed = probed,
    )

def _overlay_watches_missing_package_and_candidates_test_impl(ctx):
    """Probing an overlay root with no matching package watches the package dir and all version candidates.

    Without `ctx.watch` on the probed paths, adding `<root>/<pkg>/<ver>/BUILD.bazel.tpl`
    after `@<hub>__<pkg>` has been fetched once leaves the spoke repository stale
    on incremental builds.
    """
    env = unittest.begin(ctx)

    mock = _make_mock_overlay_ctx(files = {})
    rendered = resolve_overlay(
        mock.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )

    asserts.equals(env, "", rendered)
    asserts.equals(
        env,
        [
            "/workspace/plugin_overlays/BUILD.bazel",
            "/workspace/plugin_overlays",
            "/workspace/plugin_overlays/audio_session",
            "/workspace/plugin_overlays/audio_session/0.1.21",
            "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0.1",
            "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0",
            "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/BUILD.bazel.tpl",
        ],
        mock.watched,
    )
    for p in mock.probed:
        asserts.true(
            env,
            p in mock.watched,
            "probed path %s must be watched by ctx.watch, got watched=%s" % (p, mock.watched),
        )

    return unittest.end(env)

overlay_watches_missing_package_and_candidates_test = unittest.make(
    _overlay_watches_missing_package_and_candidates_test_impl,
)

def _overlay_watches_more_specific_version_candidates_test_impl(ctx):
    """Matching `<major>/BUILD.bazel.tpl` still watches `<major>.<minor>.<patch>` and `<major>.<minor>`.

    When a user drops a more specific `<major>.<minor>.<patch>/BUILD.bazel.tpl`
    override alongside an existing `<major>/BUILD.bazel.tpl`, Bazel only
    invalidates the spoke if the higher-precedence candidate paths were watched
    during the initial lookup.
    """
    env = unittest.begin(ctx)

    files = {
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # major'
        ),
    }
    mock1 = _make_mock_overlay_ctx(files = files)
    rendered1 = resolve_overlay(
        mock1.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# major" in rendered1, rendered1)
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl" in mock1.watched,
        "patch candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl" in mock1.watched,
        "minor candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl" in mock1.watched,
        "matched major candidate must be watched: %s" % mock1.watched,
    )

    # Simulate adding the patch-specific override on an incremental build: the
    # newly added path must have been in mock1.watched, and re-running resolves
    # the patch-specific template.
    patch_tpl = "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl"
    asserts.true(env, patch_tpl in mock1.watched)
    files_after = dict(files)
    files_after[patch_tpl] = (
        'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # patch'
    )
    mock2 = _make_mock_overlay_ctx(files = files_after)
    rendered2 = resolve_overlay(
        mock2.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# patch" in rendered2, rendered2)

    return unittest.end(env)

overlay_watches_more_specific_version_candidates_test = unittest.make(
    _overlay_watches_more_specific_version_candidates_test_impl,
)

def _overlay_multi_root_watches_higher_priority_root_test_impl(ctx):
    """When a lower-priority root matches, higher-priority roots that missed are still watched.

    `flutter.plugin_overlays` prepends user roots ahead of `@rules_flutter//ext:BUILD.bazel`.
    When a package initially resolves from `@rules_flutter//ext`, the user root's
    probed candidate paths must all be watched so dropping a local override into
    the user root invalidates the spoke on the next incremental build.
    """
    env = unittest.begin(ctx)

    anchors = {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
        "@rules_flutter//ext:BUILD.bazel": "/ext_repo/ext/BUILD.bazel",
    }
    files = {
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # bundled'
        ),
    }
    mock = _make_mock_overlay_ctx(files = files, root_anchors = anchors)

    overlay_content = resolve_overlay_roots(
        mock.ctx,
        ["//plugin_overlays:BUILD.bazel", "@rules_flutter//ext:BUILD.bazel"],
        "objective_c",
        "9.3.0",
        "3.10",
        ["@deps__ffi//:ffi"],
    )

    asserts.true(env, "# bundled" in overlay_content, overlay_content)
    for expected_watched in [
        "/workspace/plugin_overlays/objective_c",
        "/workspace/plugin_overlays/objective_c/9.3.0/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9.3/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3.0/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl",
    ]:
        asserts.true(
            env,
            expected_watched in mock.watched,
            "expected %s in watched: %s" % (expected_watched, mock.watched),
        )

    return unittest.end(env)

overlay_multi_root_watches_higher_priority_root_test = unittest.make(
    _overlay_multi_root_watches_higher_priority_root_test_impl,
)

def _audio_session_heredoc_tpl():
    """The audio_session BuildConfig heredoc genrule, as its overlay spells it."""
    return """\
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")

genrule(
    name = "_build_config_src",
    outs = ["_build_config/com/ryanheise/audio_session/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\\npackage com.ryanheise.audio_session;\\npublic final class BuildConfig {\\n  public static final boolean DEBUG = false;\\n  public static final String LIBRARY_PACKAGE_NAME = \\"com.ryanheise.audio_session\\";\\n  public static final String BUILD_TYPE = \\"release\\";\\n}\\nEOF\\n",
)
"""

def _overlay_rewrites_cat_genrules_to_write_file_test_impl(ctx):
    """Overlay templates using `cat > $@ <<'EOF'` genrules are rewritten to `write_file`."""
    env = unittest.begin(ctx)

    tpl = _audio_session_heredoc_tpl()
    rendered = apply_overlay_substitutions(
        content = tpl,
        hub_name = "deps",
        package_name = "audio_session",
        version = "0.1.21",
        language_version = "3.4",
        deps = "",
    )
    asserts.true(
        env,
        'load("@bazel_skylib//rules:write_file.bzl", "write_file")' in rendered,
        rendered,
    )
    asserts.true(
        env,
        'write_file(\n    name = "_build_config_src",\n    out = "_build_config/com/ryanheise/audio_session/BuildConfig.java",' in rendered,
        rendered,
    )
    asserts.false(env, "genrule" in rendered, rendered)
    asserts.false(env, "cat >" in rendered, rendered)

    return unittest.end(env)

overlay_rewrites_cat_genrules_to_write_file_test = unittest.make(
    _overlay_rewrites_cat_genrules_to_write_file_test_impl,
)

def _overlay_heredoc_content_matches_cat_bytes_test_impl(ctx):
    """The rewritten `content` holds the bytes the heredoc `cat` would write.

    The heredoc body the rewrite cuts out is still Starlark-encoded source
    text; each rendered `content` entry must parse back to the exact file
    line, so the `write_file` output equals the `cat` output byte for byte.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = _audio_session_heredoc_tpl(),
        hub_name = "deps",
        package_name = "audio_session",
        version = "0.1.21",
        language_version = "3.4",
        deps = "",
    )
    want_lines = [
        "package com.ryanheise.audio_session;",
        "public final class BuildConfig {",
        "  public static final boolean DEBUG = false;",
        '  public static final String LIBRARY_PACKAGE_NAME = "com.ryanheise.audio_session";',
        '  public static final String BUILD_TYPE = "release";',
        "}",
        "",
    ]
    want_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in want_lines])
    asserts.true(env, want_entries in rendered, rendered)

    return unittest.end(env)

overlay_heredoc_content_matches_cat_bytes_test = unittest.make(
    _overlay_heredoc_content_matches_cat_bytes_test_impl,
)

def _overlay_heredoc_decodes_mixed_escapes_test_impl(ctx):
    """A body holding a quote, a backslash, a tab and a single quote decodes.

    Each escape in the cut-out source text must reach the rendered `content`
    as the character it names, not re-escaped: the `write_file` output must
    equal the `cat` heredoc bytes for every escape a Starlark literal holds.
    """
    env = unittest.begin(ctx)

    tpl = """\
genrule(
    name = "mixed_src",
    outs = ["mixed/out.txt"],
    cmd = "cat > $@ <<'EOF'\\nquote \\"here\\"\\nback\\\\slash\\ncol\\there\\nit\\'s fine\\nEOF\\n",
)
"""
    rendered = apply_overlay_substitutions(
        content = tpl,
        hub_name = "deps",
        package_name = "mixed_pkg",
        version = "1.0.0",
        language_version = "3.4",
        deps = "",
    )
    want_lines = [
        'quote "here"',
        "back\\slash",
        "col\there",
        "it's fine",
        "",
    ]
    want_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in want_lines])
    asserts.true(env, want_entries in rendered, rendered)

    return unittest.end(env)

overlay_heredoc_decodes_mixed_escapes_test = unittest.make(
    _overlay_heredoc_decodes_mixed_escapes_test_impl,
)

# `_read_spoke_pubspec` refuses a present, non-null `environment.sdk` pub
# does not read before deriving anything, so a bad constraint can never
# silently fall back to a default language version. The `fail()` itself runs
# in the repository rule and is untestable here, so this test pins the
# predicate and its message through a path-package label.
def _spoke_sdk_constraint_refusal_test_impl(ctx):
    env = unittest.begin(ctx)

    for content, quoted in [
        # `sdk: "3.10"` and the bare number `sdk: 3.5`, which reads as its text.
        ({"name": "my_pkg", "environment": {"sdk": "3.10"}}, '"3.10"'),
        ({"name": "my_pkg", "environment": {"sdk": "3.5"}}, '"3.5"'),
    ]:
        err = pubspec_environment_error(content, "my_pkg/pubspec.yaml")
        asserts.true(env, err != None, "bad sdk is refused: %s" % content)
        asserts.true(env, "my_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        asserts.true(env, "environment.sdk" in err, "refusal names environment.sdk: %s" % err)
        asserts.true(env, quoted in err, "refusal quotes the value: %s" % err)

    for content in [
        {"name": "my_pkg", "environment": {"sdk": "^3.0.0"}},
        {"name": "my_pkg", "environment": {"sdk": None}},
        {"name": "my_pkg"},
    ]:
        asserts.true(
            env,
            pubspec_environment_error(content, "my_pkg/pubspec.yaml") == None,
            "sdk block reads as before: %s" % content,
        )

    return unittest.end(env)

spoke_sdk_constraint_refusal_test = unittest.make(
    _spoke_sdk_constraint_refusal_test_impl,
)

def flutter_pub_package_test_suite(name):
    small_unittest_suite(
        name,
        spokes_state_their_resolved_version_test,
        spoke_without_a_version_states_none_test,
        hardcoded_language_version_is_rejected_test,
        overlay_substitutes_the_language_version_test,
        overlay_without_a_language_version_is_left_alone_test,
        overlay_substitutes_the_dependencies_test,
        hardcoded_overlay_dependency_is_rejected_test,
        overlay_watches_missing_package_and_candidates_test,
        overlay_watches_more_specific_version_candidates_test,
        overlay_multi_root_watches_higher_priority_root_test,
        overlay_rewrites_cat_genrules_to_write_file_test,
        overlay_heredoc_content_matches_cat_bytes_test,
        overlay_heredoc_decodes_mixed_escapes_test,
        plugin_spoke_carries_resources_test,
        plugin_defines_reach_the_generated_build_test,
        library_spoke_carries_resources_test,
        spoke_sdk_constraint_refusal_test,
    )
