"""Tests for `path:` dependency spokes: scoped linking and lock-root resolution.

A path package is symlinked into its spoke, so the generator reads it in
place. The link plan parses the package's own `pubspec.yaml` from the spoke
and links only what the spoke generator reads or exposes:

* `lib/`, the pubspec, hook scripts, declared assets/fonts/shaders (plus
  each shader's own directory), and the plugin's platform directories —
  mirrored one file at a time into real repository directories, so the
  generator's `ctx.file` writes can never land in the user tree through a
  symlinked directory. A directory that arrives as a symlink resolves to
  its target and mirrors the same way — no directory is ever symlinked —
  and every link at any depth is confined to the workspace and checked
  for cycles.
* `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files,
  and user BUILD files stay unlinked at the package root — skipped
  top-level subtrees are not even watched, while every declared path is
  watched before testing whether it exists, so creating it later
  refetches the spoke instead of leaving its files silently missing.
  `lib/` and declared asset directories mirror whole, so `lib/build/`,
  `lib/example/`, `lib/.hidden/`, and skip names directly under a
  declared asset directory link normally. Elsewhere below the top level
  only user BUILD files stay out (watched, never linked), so nested
  `example/`, `build/`, and dot-files link normally.
* Source links fail closed, naming the package and the link, when they
  resolve to the package or an ancestor, enter a symlink cycle, or leave
  the workspace's real root — as do the package directory itself and any
  of its parent components. Path comparisons fold case exactly when the
  fetch host proves case-insensitive.
* A `path:` entry resolves against the lock file's own directory, and only
  the root module's workspace is reachable from a spoke.
* The lock entry needs a true `relative` marker and a non-absolute path,
  and the package's pubspec `name` and `version` must match the lock entry
  (overlays and code assets are selected by lock name and version): a
  pubspec with no `version:` field reads as `0.0.0`, the way `pub get`
  locks it, and the two versions compare as parsed semantic versions —
  quoting, surrounding whitespace and the YAML scalar type do not matter,
  while an unparsable version on either side fails the fetch.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_mirror.bzl",
    "ancestor_link_refusal",
    "cycle_refusal",
    "detect_case_insensitive_host",
    "is_path_spoke_skipped_dir",
    "link_target_is_cycle",
    "make_link_scope",
    "mirror_tree_bounded",
    "outside_workspace_refusal",
    "path_spoke_is_ancestor_cycle",
    "path_spoke_resolves_outside",
    "paths_match",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "link_path_package",
    "malformed_pub_version_refusal",
    "missing_pubspec_refusal",
    "parse_pubspec_identity",
    "path_spoke_platform_dirs",
    "pubspec_name_refusal",
    "pubspec_version_refusal",
)
load("//flutter/private:flutter_pub_package_helpers.bzl", "scoped_shader_includes_block")
load("//flutter/private:flutter_pub_path.bzl", "foreign_lock_path_error", "is_absolute_lock_path", "is_relative_path_dependency", "workspace_relative_lock_path")
load("//flutter/private:flutter_pub_semver.bzl", "parse_pub_version")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_plugin_block")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _tree_lookup(tree, rel, fold):
    """The node at `rel` in a nested-dict tree, optionally folding case.

    With `fold`, each segment matches the first key that agrees
    case-insensitively, like a case-insensitive filesystem resolving a
    wrong-case spelling; directory listings still report the true names.
    """
    node = tree
    if rel == "":
        return node
    for seg in rel.split("/"):
        if type(node) != "dict":
            return "missing"
        if seg in node:
            node = node[seg]
            continue
        if not fold:
            return "missing"
        hit = None
        for key in node:
            if key.lower() == seg.lower():
                hit = key
                break
        if hit == None:
            return "missing"
        node = node[hit]
    return node

def _mock_target_rel(real):
    """The tree lookup for a symlink target, or None outside the workspace."""
    prefix = "/workspace/"
    if not real.startswith(prefix):
        return None
    return real[len(prefix):]

def _make_mock_link_ctx(tree, path_value = "platform_assets", package_name = "platform_assets", version = "", hub_name = "test_hub", case_insensitive_fs = False):
    """Fake repository_ctx for `link_path_package` over an in-memory tree.

    Tree leaves: None is an empty file, a string is a file with that
    content, a dict is a real directory, and `struct(symlink_to = ...)` is
    a symlink node resolving to the given real path. A symlink struct with
    `is_dir = True` is a directory link: its children list the target's
    entries, like a fetch host that follows directory symlinks. With
    `case_insensitive_fs`, lookups also resolve wrong-case spellings (like
    APFS or NTFS default) while `readdir` still lists the true names, so
    the case probe can tell the two hosts apart.

    Args:
        tree: Nested dicts relative to a fake `/workspace` root.
        path_value: Value for `ctx.attr.path`.
        package_name: Value for `ctx.attr.package_name`.
        version: Value for `ctx.attr.version` (the lock's version).
        hub_name: Value for `ctx.attr.hub_name`.
        case_insensitive_fs: Resolve lookups folding case.

    Returns:
        struct(ctx, watched, linked): the fake ctx, the watched path
        strings, and the symlinked (link name, resolved target) pairs.
    """
    watched = []
    linked = []
    linked_names = {}

    def _make_path(rel, disk_rel = None):
        look = disk_rel if disk_rel != None else rel
        full = "/workspace/" + rel if rel else "/workspace"
        disk_full = "/workspace/" + look if look else "/workspace"
        node = _tree_lookup(tree, look, case_insensitive_fs)
        if type(node) == "struct":
            real = node.symlink_to
            exists = True
            is_dir = node.is_dir if hasattr(node, "is_dir") else False
            content = ""
            target_rel = _mock_target_rel(real)
            target = _tree_lookup(tree, target_rel, case_insensitive_fs) if target_rel != None else "missing"
            names = sorted(target.keys()) if is_dir and type(target) == "dict" else []
            kid_base = target_rel
        else:
            real = disk_full
            exists = node != "missing"
            is_dir = type(node) == "dict"
            content = node if type(node) == "string" else ""
            names = sorted(node.keys()) if is_dir else []
            kid_base = look

        def _readdir():
            return [_make_path(rel + "/" + c if rel else c, kid_base + "/" + c if kid_base != None and kid_base else c) for c in names]

        def _get_child(*segments):
            child_rel = rel
            disk = kid_base
            for seg in segments:
                child_rel = child_rel + "/" + seg if child_rel else seg
                disk = (disk + "/" + seg if disk else seg) if disk != None else None
                if disk != None:
                    inter = _tree_lookup(tree, disk, case_insensitive_fs)
                    if type(inter) == "struct":
                        disk = _mock_target_rel(inter.symlink_to)
            return _make_path(child_rel, disk)

        return struct(
            path = full,
            basename = rel.split("/")[-1] if rel else "",
            exists = exists,
            is_dir = is_dir,
            realpath = real,
            content = content,
            readdir = _readdir,
            get_child = _get_child,
        )

    def _watch(path_obj):
        watched.append(path_obj.path)

    def _symlink(target, link_name):
        linked.append(struct(name = link_name, target = target.realpath, is_dir = target.is_dir))
        linked_names[link_name] = target.content

    def _repo_path(rel):
        return struct(exists = rel in linked_names, link_name = rel)

    def _read(path_obj):
        return linked_names.get(path_obj.link_name, "")

    return struct(
        ctx = struct(
            attr = struct(path = path_value, package_name = package_name, version = version, hub_name = hub_name),
            workspace_root = _make_path(""),
            watch = _watch,
            symlink = _symlink,
            path = _repo_path,
            read = _read,
        ),
        watched = watched,
        linked = linked,
    )

_SCOPED_PUBSPEC = """name: mypkg
flutter:
  assets:
    - assets/any.txt
    - assets/dir/
"""

# A package exercising every scoping rule: declared and undeclared assets, a
# nested user BUILD file, an example app with its own build output and
# `.plugin_symlinks` cycle, tool state, a dot-directory, an (undeclared,
# non-plugin) android tree, and an undeclared top-level file.
_SCOPED_CONTENTS = {
    "pubspec.yaml": _SCOPED_PUBSPEC,
    "lib": {
        "mypkg.dart": None,
    },
    "assets": {
        "any.txt": None,
        "other.txt": None,
        "dir": {
            "one.txt": None,
            "BUILD.bazel": None,
        },
        "icons": {},
    },
    "example": {
        "main.dart": None,
        "build": {
            "stale.txt": None,
        },
        ".plugin_symlinks": {
            "mypkg": struct(symlink_to = "/workspace/mypkg"),
        },
    },
    "build": {
        "output.txt": None,
    },
    ".dart_tool": {
        "package_config.json": None,
    },
    ".hidden": {
        "x.txt": None,
    },
    "android": {
        "settings.gradle": None,
    },
    "tool.sh": None,
}

_SCOPED_LINKED = [
    "assets/any.txt",
    "assets/dir/one.txt",
    "lib/mypkg.dart",
    "pubspec.yaml",
]

_SCOPED_WATCHED = [
    "/workspace/mypkg",
    "/workspace/mypkg/assets",
    "/workspace/mypkg/assets/any.txt",
    "/workspace/mypkg/assets/dir",
    "/workspace/mypkg/assets/dir/BUILD.bazel",
    "/workspace/mypkg/assets/dir/one.txt",
    "/workspace/mypkg/hook/build.dart",
    "/workspace/mypkg/hook/link.dart",
    "/workspace/mypkg/lib",
    "/workspace/mypkg/lib/mypkg.dart",
    "/workspace/mypkg/pubspec.yaml",
]

def _link_scopes_to_the_pubspec_plan_test_impl(ctx):
    """The spoke links the pubspec plan — nothing it does not read or expose.

    `example/` (with its `build/` output and `.plugin_symlinks` cycle),
    `build/`, `.dart_tool/`, dot-directories, undeclared files, the
    non-plugin `android/` tree, and user BUILD files stay out; skipped
    subtrees are not even watched, while the nested BUILD file is watched
    (appearing content refetches) but not linked.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({"mypkg": _SCOPED_CONTENTS}, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    asserts.equals(env, _SCOPED_LINKED, sorted([link.name for link in mock.linked]))
    asserts.equals(env, sorted(_SCOPED_WATCHED), sorted({w: True for w in mock.watched}))
    for link in mock.linked:
        asserts.true(
            env,
            link.target.startswith("/workspace/mypkg/"),
            "link {} must point into the package, got {}".format(link.name, link.target),
        )
    return unittest.end(env)

link_scopes_to_the_pubspec_plan_test = unittest.make(_link_scopes_to_the_pubspec_plan_test_impl)

_PLUGIN_PUBSPEC = """name: mypkg
flutter:
  plugin:
    platforms:
      android:
        package: com.example.mypkg
        pluginClass: MyPlugin
"""

def _plugin_platform_dir_is_mirrored_not_symlinked_test_impl(ctx):
    """A declared platform dir mirrors file by file; the write stays in-spoke.

    The generator always emits `android/BUILD.bazel`, so linking `android/`
    as one directory symlink would carry that write into the user's tree
    (overwriting a user-owned file or creating a new main-repo package).
    Instead the spoke holds a real `android/` directory whose children are
    linked one by one; the generated file then replaces a file symlink (or
    is created) inside the spoke. The user's own BUILD file is watched but
    not linked, and the undeclared `ios/` tree stays out entirely.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": _PLUGIN_PUBSPEC,
            "lib": {"mypkg.dart": None},
            "android": {
                "BUILD.bazel": None,
                "settings.gradle": None,
                "src": {"main": {"Foo.kt": None}},
            },
            "ios": {"Runner.xcodeproj": None},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.false(env, "android" in names, "android/ must not be one dir symlink, got {}".format(names))
    asserts.true(env, "android/settings.gradle" in names, "android children must be linked one by one, got {}".format(names))
    asserts.true(env, "android/src/main/Foo.kt" in names, "nested android sources must be linked, got {}".format(names))
    asserts.false(env, "android/BUILD.bazel" in names, "the user BUILD file must not be linked, got {}".format(names))
    for link in mock.linked:
        asserts.false(
            env,
            link.name == "ios" or link.name.startswith("ios/"),
            "undeclared ios/ must stay out, got {}".format(names),
        )
        if link.name.startswith("android/"):
            asserts.true(
                env,
                link.target.startswith("/workspace/mypkg/android/"),
                "link {} must point into the package's android/, got {}".format(link.name, link.target),
            )
    asserts.true(env, "/workspace/mypkg/android/BUILD.bazel" in mock.watched, "the user BUILD file must still be watched, got {}".format(sorted(mock.watched)))
    asserts.true(env, "/workspace/mypkg/ios/Runner.xcodeproj" not in mock.watched, "undeclared ios/ must not be watched, got {}".format(sorted(mock.watched)))
    return unittest.end(env)

plugin_platform_dir_is_mirrored_not_symlinked_test = unittest.make(_plugin_platform_dir_is_mirrored_not_symlinked_test_impl)

def _non_plugin_package_links_no_android_test_impl(ctx):
    """Without a plugin block no platform directory is generator-read."""
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\n",
            "lib": {"mypkg.dart": None},
            "android": {"settings.gradle": None},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, ["lib/mypkg.dart", "pubspec.yaml"], names)
    for seen in mock.watched:
        asserts.false(env, "/android" in seen, "android/ must stay out, saw {}".format(seen))
    return unittest.end(env)

non_plugin_package_links_no_android_test = unittest.make(_non_plugin_package_links_no_android_test_impl)

def _workspace_sibling_link_replicates_without_descending_test_impl(ctx):
    """A link leaving the package for a workspace sibling replicates as-is.

    Links that resolve inside the workspace keep working exactly as today,
    including links that leave the package but stay in the workspace; only
    targets outside the workspace's real root are refused (see
    `path_spoke_resolves_outside` — `fail()` itself is untestable here).
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\n",
            "lib": {
                "mypkg.dart": None,
                "ext.so": struct(symlink_to = "/workspace/shared/ext.so"),
            },
        },
        "shared": {
            "ext.so": None,
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    by_name = {link.name: link.target for link in mock.linked}
    asserts.equals(env, "/workspace/shared/ext.so", by_name.get("lib/ext.so", "missing"))
    asserts.true(env, "/workspace/mypkg/lib/ext.so" in mock.watched, "the replicated link must be watched, got {}".format(sorted(mock.watched)))
    for seen in mock.watched:
        asserts.false(env, seen.startswith("/workspace/shared"), "the walk must never descend into the target, saw {}".format(seen))
    return unittest.end(env)

workspace_sibling_link_replicates_without_descending_test = unittest.make(_workspace_sibling_link_replicates_without_descending_test_impl)

_OVERLAP_PUBSPEC = """name: mypkg
flutter:
  assets:
    - data/x.txt
    - data/
  shaders:
    - shaders/ripple.frag
"""

def _overlapping_entries_link_once_test_impl(ctx):
    """A file inside its own declared dir (or a shader in its dir) links once.

    The real fetch fails the second `ctx.symlink` to the same spoke path
    with "File exists", so the link set dedupes: the file entry wins, the
    directory mirror covers the rest.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": _OVERLAP_PUBSPEC,
            "lib": {"m.dart": None},
            "data": {"x.txt": None, "y.txt": None},
            "shaders": {"ripple.frag": None, "include": {"common.glsl": None}},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(
        env,
        ["data/x.txt", "data/y.txt", "lib/m.dart", "pubspec.yaml", "shaders/include/common.glsl", "shaders/ripple.frag"],
        names,
    )
    return unittest.end(env)

overlapping_entries_link_once_test = unittest.make(_overlapping_entries_link_once_test_impl)

def _ancestor_link_is_refused_test_impl(ctx):
    """A link to the package or an ancestor fails naming package and link.

    `link_path_package` itself `fail()`s on this shape (untestable here),
    so these pin the predicate and the message it fails with: self, parent,
    and root refuse; children, siblings, and prefix-lookalikes pass.
    """
    env = unittest.begin(ctx)
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg"))
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w"))
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg/lib/x"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/other"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg2"))
    message = ancestor_link_refusal("mypkg", "example/.plugin_symlinks/mypkg", "/workspace/mypkg")
    asserts.true(env, "mypkg" in message, "refusal must name the package: {}".format(message))
    asserts.true(env, "example/.plugin_symlinks/mypkg" in message, "refusal must name the link: {}".format(message))
    return unittest.end(env)

ancestor_link_is_refused_test = unittest.make(_ancestor_link_is_refused_test_impl)

def _outside_workspace_is_refused_test_impl(ctx):
    """A node outside the workspace's real root fails naming package and paths.

    `link_path_package` itself `fail()`s on this shape (untestable here),
    so these pin the predicate and the message it fails with: the
    workspace itself and everything under it passes (including a
    lookalike prefix without the slash), while host paths and the root
    refuse.
    """
    env = unittest.begin(ctx)
    asserts.false(env, path_spoke_resolves_outside("/workspace", "/workspace"))
    asserts.false(env, path_spoke_resolves_outside("/workspace", "/workspace/pkg"))
    asserts.false(env, path_spoke_resolves_outside("/workspace", "/workspace/pkg/lib/x"))
    asserts.true(env, path_spoke_resolves_outside("/workspace", "/host/dir"))
    asserts.true(env, path_spoke_resolves_outside("/workspace", "/"))
    asserts.true(env, path_spoke_resolves_outside("/workspace", "/workspace2"))
    asserts.true(env, path_spoke_resolves_outside("/workspace", "/other"))
    message = outside_workspace_refusal("mypkg", "assets", "/host/dir")
    asserts.true(env, "mypkg" in message, "refusal must name the package: {}".format(message))
    asserts.true(env, "assets" in message, "refusal must name the offending path: {}".format(message))
    asserts.true(env, "/host/dir" in message, "refusal must name the real path: {}".format(message))
    return unittest.end(env)

outside_workspace_is_refused_test = unittest.make(_outside_workspace_is_refused_test_impl)

def _relative_marker_decides_test_impl(ctx):
    """Only a true `relative` marker accepts a path entry.

    The lock parser stringifies every description value, so YAML
    `relative: false` arrives as `"False"`; only the parsed string
    `"true"` (any case) or a real boolean `True` passes. Anything else —
    false, missing, empty — refuses the entry.
    """
    env = unittest.begin(ctx)
    asserts.true(env, is_relative_path_dependency(True))
    asserts.true(env, is_relative_path_dependency("true"))
    asserts.true(env, is_relative_path_dependency("True"))
    asserts.true(env, is_relative_path_dependency("TRUE"))
    asserts.false(env, is_relative_path_dependency(False))
    asserts.false(env, is_relative_path_dependency("False"))
    asserts.false(env, is_relative_path_dependency("false"))
    asserts.false(env, is_relative_path_dependency(""))
    asserts.false(env, is_relative_path_dependency(None))
    asserts.false(env, is_relative_path_dependency("yes"))
    asserts.false(env, is_relative_path_dependency("1"))
    return unittest.end(env)

relative_marker_decides_test = unittest.make(_relative_marker_decides_test_impl)

def _absolute_lock_path_decides_test_impl(ctx):
    """An absolute lock path fails in every spelling; relative paths pass."""
    env = unittest.begin(ctx)
    asserts.true(env, is_absolute_lock_path("/x"))
    asserts.true(env, is_absolute_lock_path("C:/x"))
    asserts.true(env, is_absolute_lock_path("C:\\x"))
    asserts.true(env, is_absolute_lock_path("\\\\server\\x"))
    asserts.true(env, is_absolute_lock_path("//server/x"))
    asserts.true(env, is_absolute_lock_path("C:drive"))
    asserts.false(env, is_absolute_lock_path("pkg"))
    asserts.false(env, is_absolute_lock_path("a/b"))
    asserts.false(env, is_absolute_lock_path("../shared/x"))
    asserts.false(env, is_absolute_lock_path(""))
    return unittest.end(env)

absolute_lock_path_decides_test = unittest.make(_absolute_lock_path_decides_test_impl)

_DIR_LINK_PUBSPEC = """name: dirlinkpkg
flutter:
  plugin:
    platforms:
      android:
        package: com.example.dirlinkpkg
        pluginClass: DirlinkPlugin
  assets:
    - assets/
    - path: assets/extra.txt
      platforms:
        - android
"""

def _dir_link_mirrors_not_symlinks_test_impl(ctx):
    """A directory symlink mirrors file by file; no directory is symlinked.

    The plugin's `android/` and `assets/` are links to directories elsewhere
    in the workspace: the spoke holds one file symlink per file, so the
    generated `android/BUILD.bazel` lands in the spoke, never in the user's
    tree. The linked `assets/` plus the conditional per-file entry for
    `assets/extra.txt` under it link that file exactly once (no "File
    exists"); the link targets are watched entry by entry, so adding a file
    under them refetches; nested `com/example` Kotlin links (skip names stop
    at the mirrored tree's top level, so `android/build/` stays out); and the
    user's BUILD file is watched but not linked.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "dirlinkpkg": {
            "pubspec.yaml": _DIR_LINK_PUBSPEC,
            "lib": {"dirlinkpkg.dart": None},
            "android": struct(symlink_to = "/workspace/shared/android", is_dir = True),
            "assets": struct(symlink_to = "/workspace/shared/assets", is_dir = True),
        },
        "shared": {
            "android": {
                "BUILD.bazel": "user BUILD sentinel, watched but never linked",
                "settings.gradle": None,
                "build": {"stale.txt": None},
                "src": {"main": {"kotlin": {"com": {"example": {"Plugin.kt": None}}}}},
            },
            "assets": {
                "any.txt": None,
                "extra.txt": None,
            },
        },
    }, path_value = "dirlinkpkg", package_name = "dirlinkpkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, [
        "android/settings.gradle",
        "android/src/main/kotlin/com/example/Plugin.kt",
        "assets/any.txt",
        "assets/extra.txt",
        "lib/dirlinkpkg.dart",
        "pubspec.yaml",
    ], names)
    for link in mock.linked:
        asserts.false(env, link.is_dir, "link {} must be a file symlink, never a directory symlink".format(link.name))
        asserts.true(
            env,
            link.target.startswith("/workspace/"),
            "link {} must point into the workspace, got {}".format(link.name, link.target),
        )
    for seen in [
        "/workspace/shared/android",
        "/workspace/shared/assets",
        "/workspace/shared/android/BUILD.bazel",
    ]:
        asserts.true(env, seen in mock.watched, "{} must be watched, got {}".format(seen, sorted(mock.watched)))
    return unittest.end(env)

dir_link_mirrors_not_symlinks_test = unittest.make(_dir_link_mirrors_not_symlinks_test_impl)

_ESCAPED_LINK_PUBSPEC = """name: hpkg
flutter:
  assets:
    - enc%20c.png
    - pct%25.png
    - dir%20d/
  fonts:
    - family: Esc
      fonts:
        - asset: fonts/f%20g.ttf
  shaders:
    - shaders/a%20b.frag
"""

def _escaped_entries_link_decoded_test_impl(ctx):
    """Escaped entries link the decoded files, in every entry kind.

    The link plan resolves declarations against the source tree, so it
    must read the decoded names: `enc%20c.png` links `enc c.png`, and the
    same for a `%25` asset, a directory entry, a font asset and a shader.
    Linking the raw entry text would watch a missing path and leave the
    file out of the spoke, failing expansion with no file found.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "hpkg": {
            "pubspec.yaml": _ESCAPED_LINK_PUBSPEC,
            "enc c.png": None,
            "pct%.png": None,
            "dir d": {"f.png": None},
            "fonts": {"f g.ttf": None},
            "shaders": {"a b.frag": None},
        },
    }, path_value = "hpkg", package_name = "hpkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(
        env,
        ["dir d/f.png", "enc c.png", "fonts/f g.ttf", "pct%.png", "pubspec.yaml", "shaders/a b.frag"],
        names,
    )
    return unittest.end(env)

escaped_entries_link_decoded_test = unittest.make(_escaped_entries_link_decoded_test_impl)

def _nested_links_stay_confined_test_impl(ctx):
    """Links nested inside a mirrored directory stay confined to the workspace.

    A file link nested in `lib/` replicates as one watched symlink without
    descending into its target; a directory link nested there resolves back
    through the workspace root and mirrors entry by entry; and a link nested
    inside that mirrored target replicates too. Every emitted link is a file
    symlink pointing into the workspace.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "nestedpkg": {
            "pubspec.yaml": "name: nestedpkg\n",
            "lib": {
                "nestedpkg.dart": None,
                "sibling.txt": None,
                "ext_link.txt": struct(symlink_to = "/workspace/nestedpkg/lib/sibling.txt"),
                "dir_link": struct(symlink_to = "/workspace/shared/dir", is_dir = True),
            },
        },
        "shared": {
            "dir": {
                "deep.txt": None,
                "inner_link.txt": struct(symlink_to = "/workspace/nestedpkg/lib/sibling.txt"),
            },
        },
    }, path_value = "nestedpkg", package_name = "nestedpkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, [
        "lib/dir_link/deep.txt",
        "lib/dir_link/inner_link.txt",
        "lib/ext_link.txt",
        "lib/nestedpkg.dart",
        "lib/sibling.txt",
        "pubspec.yaml",
    ], names)
    for link in mock.linked:
        asserts.false(env, link.is_dir, "link {} must be a file symlink, never a directory symlink".format(link.name))
        asserts.true(
            env,
            link.target.startswith("/workspace/"),
            "link {} must point into the workspace, got {}".format(link.name, link.target),
        )
    asserts.true(env, "/workspace/shared/dir" in mock.watched, "the mirrored link target must be watched, got {}".format(sorted(mock.watched)))
    return unittest.end(env)

nested_links_stay_confined_test = unittest.make(_nested_links_stay_confined_test_impl)

_SKIP_ROOT_PUBSPEC = """name: skippkg
flutter:
  plugin:
    platforms:
      android:
        package: com.example.skippkg
        pluginClass: SkipPlugin
  assets:
    - assets/icons/
"""

def _skips_stop_at_mirror_root_test_impl(ctx):
    """Skip names stop at each skipping tree's top level; dot-files link.

    `lib/` and declared asset directory trees mirror whole, so skip names
    directly under them link too. Elsewhere `build/` and `example/`
    segments nested under a platform dir link normally (so do
    `com/example` Kotlin, dot-files inside a declared asset directory,
    and dot-directories below a skipping tree's top level) — only each
    skipping mirrored tree's immediate children consult the skip list.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "skippkg": {
            "pubspec.yaml": _SKIP_ROOT_PUBSPEC,
            "lib": {
                "skippkg.dart": None,
                "src": {
                    "build": {"gen.dart": None},
                    "example": {"sample.dart": None},
                },
            },
            "android": {"src": {"main": {"kotlin": {"com": {"example": {"Plugin.kt": None}}}}}},
            "assets": {"icons": {".keep": None, "sub": {".cache": {"c.txt": None}}, "a.txt": None}},
        },
    }, path_value = "skippkg", package_name = "skippkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, [
        "android/src/main/kotlin/com/example/Plugin.kt",
        "assets/icons/.keep",
        "assets/icons/a.txt",
        "assets/icons/sub/.cache/c.txt",
        "lib/skippkg.dart",
        "lib/src/build/gen.dart",
        "lib/src/example/sample.dart",
        "pubspec.yaml",
    ], names)
    return unittest.end(env)

skips_stop_at_mirror_root_test = unittest.make(_skips_stop_at_mirror_root_test_impl)

_COV76_PUBSPEC = """name: cov76pkg
flutter:
  assets:
    - assets/
"""

def _lib_and_asset_dir_skip_names_link_test_impl(ctx):
    """COV-76: `lib/` and asset dirs mirror whole; root skips stay.

    `lib/build/a.dart`, `lib/example/b.dart`, and `lib/.hidden/c.dart`
    all mirror (as do skip names directly under the declared `assets/`
    dir), while the package-root `build/`, `example/`, and `.dart_tool/`
    subtrees stay unlinked and unwatched. Fails against main's
    `flutter_pub_mirror.bzl`, which drops the `lib/`- and asset-dir-top
    names.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "cov76pkg": {
            "pubspec.yaml": _COV76_PUBSPEC,
            "lib": {
                "cov76pkg.dart": None,
                "build": {"a.dart": None},
                "example": {"b.dart": None},
                ".hidden": {"c.dart": None},
            },
            "assets": {
                "ok.txt": None,
                "build": {"d.txt": None},
                "example": {"e.txt": None},
                ".hidden": {"f.txt": None},
            },
            "build": {"root.txt": None},
            "example": {"main.dart": None},
            ".dart_tool": {"package_config.json": None},
        },
    }, path_value = "cov76pkg", package_name = "cov76pkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, [
        "assets/.hidden/f.txt",
        "assets/build/d.txt",
        "assets/example/e.txt",
        "assets/ok.txt",
        "lib/.hidden/c.dart",
        "lib/build/a.dart",
        "lib/cov76pkg.dart",
        "lib/example/b.dart",
        "pubspec.yaml",
    ], names)
    for skipped in ["build/root.txt", "example/main.dart", ".dart_tool/package_config.json"]:
        asserts.false(env, skipped in names, skipped + " must stay out, got {}".format(names))
    for seen in [
        "/workspace/cov76pkg/build",
        "/workspace/cov76pkg/build/root.txt",
        "/workspace/cov76pkg/example",
        "/workspace/cov76pkg/example/main.dart",
        "/workspace/cov76pkg/.dart_tool",
        "/workspace/cov76pkg/.dart_tool/package_config.json",
    ]:
        asserts.false(env, seen in mock.watched, seen + " must stay unwatched, got {}".format(sorted(mock.watched)))
    return unittest.end(env)

lib_and_asset_dir_skip_names_link_test = unittest.make(_lib_and_asset_dir_skip_names_link_test_impl)

def _missing_declared_paths_are_watched_test_impl(ctx):
    """A declared path is watched before testing whether it exists.

    A declared asset file and a declared asset directory that are both
    missing at fetch time stay unlinked but watched, so creating either
    later refetches the spoke instead of leaving its files silently
    missing.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "latepkg": {
            "pubspec.yaml": "name: latepkg\nflutter:\n  assets:\n    - assets/late.txt\n    - assets/missing_dir/\n",
            "lib": {"latepkg.dart": None},
        },
    }, path_value = "latepkg", package_name = "latepkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, ["lib/latepkg.dart", "pubspec.yaml"], names)
    for seen in [
        "/workspace/latepkg/assets",
        "/workspace/latepkg/assets/late.txt",
        "/workspace/latepkg/assets/missing_dir",
    ]:
        asserts.true(env, seen in mock.watched, "{} must be watched, got {}".format(seen, sorted(mock.watched)))
    return unittest.end(env)

missing_declared_paths_are_watched_test = unittest.make(_missing_declared_paths_are_watched_test_impl)

def _cycle_refusal_names_the_link_test_impl(ctx):
    """Entering a symlink cycle fails fast naming the link as a cycle.

    `mirror_tree_bounded` reports the refusal instead of failing (the caller
    `fail()`s with it), so the walk stops at the cycle instead of running to
    the bound and reporting a misleading directory count.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "cycpkg": {
            "lib": {"a": {
                "back": struct(symlink_to = "/workspace/cycpkg/lib/a", is_dir = True),
                "f.txt": None,
            }},
        },
    }, path_value = "cycpkg", package_name = "cycpkg")
    src = mock.ctx.workspace_root.get_child("cycpkg")
    scope = make_link_scope("cycpkg", "/workspace/cycpkg", "/workspace", False, {})
    result = mirror_tree_bounded(
        mock.ctx,
        [(src.get_child("lib", "a"), "lib/a", ("/workspace/cycpkg/lib/a",), "lib/a")],
        scope,
        100,
    )
    asserts.false(env, result.leftover)
    asserts.true(env, "lib/a/back" in result.error, "refusal must name the link: {}".format(result.error))
    asserts.true(env, "cycle" in result.error, "refusal must say it is a cycle: {}".format(result.error))
    message = cycle_refusal("cycpkg", "lib/a/back", "/workspace/cycpkg/lib/a")
    for want in ["cycpkg", "lib/a/back", "cycle"]:
        asserts.true(env, want in message, "refusal must name the package, the link, and the cycle: {}".format(message))
    asserts.true(env, link_target_is_cycle(("/workspace/x",), "/workspace/x", False))
    asserts.false(env, link_target_is_cycle(("/workspace/x",), "/workspace/y", False))
    return unittest.end(env)

cycle_refusal_names_the_link_test = unittest.make(_cycle_refusal_names_the_link_test_impl)

def _case_folded_skip_applies_end_to_end_test_impl(ctx):
    """The probe's answer changes what a whole fetch links.

    A `Build/` directory at the root of a declared asset dir mirrors on
    both hosts (asset trees never skip), while a `Build/` directory at
    the root of the mirrored `android/` platform dir is skipped when the
    host folds case and mirrored when it does not, through the whole
    `link_path_package` fetch — the probe, not the caller, decides.
    """
    env = unittest.begin(ctx)
    tree = {
        "casepkg": {
            "pubspec.yaml": "name: casepkg\nflutter:\n  assets:\n    - assets/\n  plugin:\n    platforms:\n      android:\n        package: com.example.casepkg\n        pluginClass: CasePlugin\n",
            "lib": {"casepkg.dart": None},
            "assets": {
                "any.txt": None,
                "Build": {"top.txt": None},
            },
            "android": {
                "settings.gradle": None,
                "Build": {"stale.txt": None},
            },
        },
    }
    exact = _make_mock_link_ctx(tree, path_value = "casepkg", package_name = "casepkg")
    link_path_package(exact.ctx)
    asserts.equals(env, ["android/Build/stale.txt", "android/settings.gradle", "assets/Build/top.txt", "assets/any.txt", "lib/casepkg.dart", "pubspec.yaml"], sorted([link.name for link in exact.linked]))
    folded = _make_mock_link_ctx(tree, path_value = "casepkg", package_name = "casepkg", case_insensitive_fs = True)
    link_path_package(folded.ctx)
    asserts.equals(env, ["android/settings.gradle", "assets/Build/top.txt", "assets/any.txt", "lib/casepkg.dart", "pubspec.yaml"], sorted([link.name for link in folded.linked]))
    return unittest.end(env)

case_folded_skip_applies_end_to_end_test = unittest.make(_case_folded_skip_applies_end_to_end_test_impl)

def _case_probe_needs_readdir_evidence_test_impl(ctx):
    """The case probe trusts only evidence a sensitive host cannot fake.

    A flipped spelling that resolves but has no exactly-named entry in
    its parent's `readdir()` means the filesystem matched a name it does
    not hold, so the host folds case; on such a host a target outside
    the workspace only by case still counts as inside. Two case-variant
    directories listed side by side prove a case-sensitive host instead,
    and an outside target differing only by case is refused. Only the
    deepest cased segment is flipped, so a lowercase package under a
    mixed-case parent (or cased letters only in an ancestor) still proves
    a folding host, while a letterless path answers False everywhere.
    """
    env = unittest.begin(ctx)
    folded = _make_mock_link_ctx({"mypkg": {"lib": {}}}, path_value = "mypkg", package_name = "mypkg", case_insensitive_fs = True)
    asserts.true(env, detect_case_insensitive_host(folded.ctx, ["mypkg"]))
    asserts.false(env, path_spoke_resolves_outside("/x/ws", "/x/WS/secret", True))
    listed = _make_mock_link_ctx({"mypkg": {"lib": {}}, "MYPKG": {"lib": {}}}, path_value = "mypkg", package_name = "mypkg")
    asserts.false(env, detect_case_insensitive_host(listed.ctx, ["mypkg"]))
    asserts.true(env, path_spoke_resolves_outside("/x/ws", "/x/WS/secret", False))
    mixed_folded = _make_mock_link_ctx({"Pkgs": {"casepkg": {"lib": {}}}}, path_value = "Pkgs/casepkg", package_name = "casepkg", case_insensitive_fs = True)
    asserts.true(env, detect_case_insensitive_host(mixed_folded.ctx, ["Pkgs", "casepkg"]))
    ancestor_folded = _make_mock_link_ctx({"Pkgs": {"123": {"lib": {}}}}, path_value = "Pkgs/123", package_name = "123", case_insensitive_fs = True)
    asserts.true(env, detect_case_insensitive_host(ancestor_folded.ctx, ["Pkgs", "123"]))
    mixed_listed = _make_mock_link_ctx({"Pkgs": {"casepkg": {"lib": {}}}, "pkgs": {"casepkg": {"lib": {}}}}, path_value = "Pkgs/casepkg", package_name = "casepkg")
    asserts.false(env, detect_case_insensitive_host(mixed_listed.ctx, ["Pkgs", "casepkg"]))
    mixed_only = _make_mock_link_ctx({"Pkgs": {"casepkg": {"lib": {}}}}, path_value = "Pkgs/casepkg", package_name = "casepkg")
    asserts.false(env, detect_case_insensitive_host(mixed_only.ctx, ["Pkgs", "casepkg"]))
    letterless = _make_mock_link_ctx({"123": {"lib": {}}}, path_value = "123", package_name = "123", case_insensitive_fs = True)
    asserts.false(env, detect_case_insensitive_host(letterless.ctx, ["123"]))
    return unittest.end(env)

case_probe_needs_readdir_evidence_test = unittest.make(_case_probe_needs_readdir_evidence_test_impl)

def _case_rule_folds_only_on_insensitive_hosts_test_impl(ctx):
    """Path comparisons fold case exactly on case-insensitive hosts.

    Exact spellings always match; a case-only difference matches only when
    the host probes case-insensitive, so two distinct entries never merge on
    a case-sensitive host while a case-variant package root, workspace root,
    or skip name still confines on an insensitive one. The probe flips the
    case of the existing package path and checks the parent's entries: a
    host answering for a spelling it does not list folds case, while one
    listing both variants is case-sensitive.
    """
    env = unittest.begin(ctx)
    asserts.true(env, paths_match("a/B", "a/B", False))
    asserts.true(env, paths_match("a/B", "a/b", True))
    asserts.false(env, paths_match("a/B", "a/b", False))
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/Pkg", "/W", True))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/Pkg", "/W", False))
    asserts.false(env, path_spoke_resolves_outside("/Workspace", "/workspace/x", True))
    asserts.true(env, path_spoke_resolves_outside("/Workspace", "/workspace/x", False))
    asserts.true(env, is_path_spoke_skipped_dir("Build", True))
    asserts.false(env, is_path_spoke_skipped_dir("Build", False))
    sensitive = _make_mock_link_ctx({"mypkg": {"lib": {}}}, path_value = "mypkg", package_name = "mypkg")
    asserts.false(env, detect_case_insensitive_host(sensitive.ctx, ["mypkg"]))
    decoy = _make_mock_link_ctx({"mypkg": {"lib": {}}, "MYPKG": {"lib": {}}}, path_value = "mypkg", package_name = "mypkg")
    asserts.false(env, detect_case_insensitive_host(decoy.ctx, ["mypkg"]))
    return unittest.end(env)

case_rule_folds_only_on_insensitive_hosts_test = unittest.make(_case_rule_folds_only_on_insensitive_hosts_test_impl)

def _pubspec_identity_parses_test_impl(ctx):
    """The spoke reads the package's pubspec name and version as strings.

    A missing (or empty) `version:` reads as `0.0.0`, exactly how `pub
    get` locks it; surrounding whitespace and quoting fall away before
    the comparison.
    """
    env = unittest.begin(ctx)
    identity = parse_pubspec_identity("name: mypkg\nversion: 0.1.0\n")
    asserts.equals(env, "mypkg", identity.name)
    asserts.equals(env, "0.1.0", identity.version)
    quoted = parse_pubspec_identity("name: \"mypkg\"\nversion: '1.2.3'\n")
    asserts.equals(env, "mypkg", quoted.name)
    asserts.equals(env, "1.2.3", quoted.version)
    padded = parse_pubspec_identity("name: mypkg\nversion: '  0.1.0  '\n")
    asserts.equals(env, "0.1.0", padded.version)
    unversioned = parse_pubspec_identity("name: mypkg\npublish_to: none\n")
    asserts.equals(env, "mypkg", unversioned.name)
    asserts.equals(env, "0.0.0", unversioned.version)
    empty = parse_pubspec_identity("name: mypkg\nversion:\n")
    asserts.equals(env, "0.0.0", empty.version)
    missing = parse_pubspec_identity("")
    asserts.equals(env, "", missing.name)
    asserts.equals(env, "0.0.0", missing.version)
    return unittest.end(env)

pubspec_identity_parses_test = unittest.make(_pubspec_identity_parses_test_impl)

def _pub_version_compares_semantically_test_impl(ctx):
    """Lock and pubspec versions compare parsed, not as raw strings.

    Whitespace, quoting (already unwrapped by YAML here) and leading
    zeros fall away; pre-release and build identifiers participate, so a
    build that moved is still a move.
    """
    env = unittest.begin(ctx)
    for lock, actual in [
        ("0.1.0", "0.1.0"),
        ("0.1.0", "  0.1.0  "),
        ("0.1.0", "00.01.00"),
        ("1.0.0-alpha", "1.0.0-alpha"),
        ("1.0.0-alpha.01", "1.0.0-alpha.1"),
        ("1.0.0+1", "1.0.0+1"),
        ("0.0.0", ""),
    ]:
        asserts.equals(
            env,
            parse_pub_version(lock).canonical,
            parse_pub_version(actual).canonical,
            "{} must agree with {}".format(lock, actual),
        )
        asserts.true(env, parse_pub_version(lock).ok, lock)
        asserts.true(env, parse_pub_version(actual).ok, actual)
    for lock, actual in [
        ("1.0.0", "2.0.0"),
        ("0.0.0", "0.1.0"),
        ("1.0.0", "1.0.0-alpha"),
        ("1.0.0+1", "1.0.0+2"),
        ("1.0.0", "1.0.0+1"),
    ]:
        asserts.false(
            env,
            parse_pub_version(lock).canonical == parse_pub_version(actual).canonical,
            "{} must disagree with {}".format(lock, actual),
        )
    return unittest.end(env)

pub_version_compares_semantically_test = unittest.make(_pub_version_compares_semantically_test_impl)

def _malformed_pub_version_is_refused_test_impl(ctx):
    """An unparsable version on either side fails naming hub, key, and value.

    `link_path_package` itself `fail()`s on these shapes (untestable
    here), so these pin the parse verdicts and the message it fails with.
    A numeric YAML scalar (`version: 2`) behaves exactly like its string
    spelling — the scalar type never changes the outcome.
    """
    env = unittest.begin(ctx)
    for bad in ["abc", "1.0", "1.0.0.0", "v1.0.0", "1.0.0-", "1.0.0+", "1.0.0-+", "2", "True"]:
        parsed = parse_pub_version(bad)
        asserts.false(env, parsed.ok, "{} must not parse".format(bad))
        asserts.equals(env, bad, parsed.text)
    asserts.false(env, parse_pub_version(2).ok, "an int scalar must not parse")
    asserts.equals(env, "2", parse_pub_version(2).text)
    message = malformed_pub_version_refusal("deps", "foo", "abc")
    asserts.true(env, "deps" in message, "refusal must name the hub: {}".format(message))
    asserts.true(env, "foo" in message, "refusal must name the lock key: {}".format(message))
    asserts.true(env, "abc" in message, "refusal must name the bad value: {}".format(message))
    return unittest.end(env)

malformed_pub_version_is_refused_test = unittest.make(_malformed_pub_version_is_refused_test_impl)

def _pubspec_mismatch_is_refused_test_impl(ctx):
    """A pubspec disagreeing with the lock fails naming hub, key, and values.

    `link_path_package` itself `fail()`s on these shapes (untestable
    here), so these pin the messages: the name refusal names the hub, the
    lock key, and both names; the version refusal names the hub, the key,
    and both versions; the missing-pubspec refusal names the hub and key.
    Each tells the user to re-resolve.
    """
    env = unittest.begin(ctx)
    name_message = pubspec_name_refusal("deps", "foo", "bar")
    asserts.true(env, "deps" in name_message, "refusal must name the hub: {}".format(name_message))
    asserts.true(env, "foo" in name_message, "refusal must name the lock key: {}".format(name_message))
    asserts.true(env, "bar" in name_message, "refusal must name the pubspec name: {}".format(name_message))
    asserts.true(env, "re-resolve" in name_message, "refusal must tell the user to re-resolve: {}".format(name_message))
    version_message = pubspec_version_refusal("deps", "foo", "1.0.0", "2.0.0")
    asserts.true(env, "deps" in version_message, "refusal must name the hub: {}".format(version_message))
    asserts.true(env, "foo" in version_message, "refusal must name the lock key: {}".format(version_message))
    asserts.true(env, "1.0.0" in version_message, "refusal must name the lock version: {}".format(version_message))
    asserts.true(env, "2.0.0" in version_message, "refusal must name the pubspec version: {}".format(version_message))
    asserts.true(env, "0.0.0" in version_message, "refusal must describe the missing-version rule: {}".format(version_message))
    asserts.true(env, "re-resolve" in version_message, "refusal must tell the user to re-resolve: {}".format(version_message))
    missing_message = missing_pubspec_refusal("deps", "foo")
    asserts.true(env, "deps" in missing_message, "refusal must name the hub: {}".format(missing_message))
    asserts.true(env, "foo" in missing_message, "refusal must name the lock key: {}".format(missing_message))
    return unittest.end(env)

pubspec_mismatch_is_refused_test = unittest.make(_pubspec_mismatch_is_refused_test_impl)

def _matching_identity_links_test_impl(ctx):
    """A pubspec agreeing with the lock on name and version links normally."""
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\nversion: 0.1.0\n",
            "lib": {"mypkg.dart": None},
        },
    }, path_value = "mypkg", package_name = "mypkg", version = "0.1.0", hub_name = "deps")
    link_path_package(mock.ctx)
    asserts.equals(env, ["lib/mypkg.dart", "pubspec.yaml"], sorted([link.name for link in mock.linked]))
    return unittest.end(env)

matching_identity_links_test = unittest.make(_matching_identity_links_test_impl)

def _unversioned_identity_links_test_impl(ctx):
    """A pubspec with no `version:` links against a `0.0.0` lock entry.

    `pub get` locks such a package as `0.0.0` (pub's `Version.none`), so
    the spoke must read the missing field the same way instead of
    refusing the fetch.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\npublish_to: none\n",
            "lib": {"mypkg.dart": None},
        },
    }, path_value = "mypkg", package_name = "mypkg", version = "0.0.0", hub_name = "deps")
    link_path_package(mock.ctx)
    asserts.equals(env, ["lib/mypkg.dart", "pubspec.yaml"], sorted([link.name for link in mock.linked]))
    return unittest.end(env)

unversioned_identity_links_test = unittest.make(_unversioned_identity_links_test_impl)

def _padded_identity_links_test_impl(ctx):
    """A whitespace-padded pubspec version links against the lock version.

    The comparison is semantic, so padding (and quoting, which YAML
    already unwrapped) never skews it.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\nversion: '  0.1.0  '\n",
            "lib": {"mypkg.dart": None},
        },
    }, path_value = "mypkg", package_name = "mypkg", version = "0.1.0", hub_name = "deps")
    link_path_package(mock.ctx)
    asserts.equals(env, ["lib/mypkg.dart", "pubspec.yaml"], sorted([link.name for link in mock.linked]))
    return unittest.end(env)

padded_identity_links_test = unittest.make(_padded_identity_links_test_impl)

def _path_spoke_platform_dirs_test_impl(ctx):
    """Only declared platforms resolve sources, so only they link."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], path_spoke_platform_dirs(parse_flutter_plugin_block("name: x\n")))
    asserts.equals(env, ["android"], path_spoke_platform_dirs(parse_flutter_plugin_block(_PLUGIN_PUBSPEC)))
    asserts.equals(
        env,
        ["darwin", "ios", "macos"],
        path_spoke_platform_dirs(parse_flutter_plugin_block("name: x\nflutter:\n  plugin:\n    platforms:\n      ios:\n        pluginClass: X\n")),
    )
    asserts.equals(
        env,
        ["android", "darwin", "ios", "linux", "macos", "windows"],
        path_spoke_platform_dirs(parse_flutter_plugin_block(
            "name: x\nflutter:\n  plugin:\n    platforms:\n      android:\n        package: a\n      ios:\n        pluginClass: X\n      macos:\n        pluginClass: X\n      linux:\n        pluginClass: X\n      windows:\n        pluginClass: X\n",
        )),
    )
    return unittest.end(env)

path_spoke_platform_dirs_test = unittest.make(_path_spoke_platform_dirs_test_impl)

def _scoped_shader_includes_block_test_impl(ctx):
    """Include globs cover the declared shaders' own dirs — never `**`."""
    env = unittest.begin(ctx)
    block = scoped_shader_includes_block(["shaders/glow.frag", "shaders/deep/ocean.vert", "ripple.frag"])
    asserts.true(env, "shader_includes = glob(" in block, block)
    asserts.true(env, '"shaders/**/*.glsl"' in block, block)
    asserts.true(env, '"shaders/**/*.frag"' in block, block)
    asserts.true(env, '"shaders/**/*.vert"' in block, block)
    asserts.true(env, '"shaders/deep/**/*.glsl"' in block, block)
    asserts.true(env, '"*.glsl"' in block, block)
    asserts.false(env, '"**/*.glsl"' in block, block)
    return unittest.end(env)

scoped_shader_includes_block_test = unittest.make(_scoped_shader_includes_block_test_impl)

def _skipped_dirs_test_impl(ctx):
    """Build output, tool state, the example app, and dot-dirs never link."""
    env = unittest.begin(ctx)
    for name in ["build", ".dart_tool", "example", ".hidden", ".plugin_symlinks"]:
        asserts.true(env, is_path_spoke_skipped_dir(name), name + " must be skipped")
    for name in ["lib", "assets", "shaders", "android", "hook"]:
        asserts.false(env, is_path_spoke_skipped_dir(name), name + " must link")
    return unittest.end(env)

skipped_dirs_test = unittest.make(_skipped_dirs_test_impl)

def _lock_path_joins_the_lock_dir_test_impl(ctx):
    """A root-module entry resolves against the lock file's directory."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/hello_world/platform_assets",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "platform_assets",
        ),
    )
    return unittest.end(env)

def _lock_path_stays_inside_the_workspace_test_impl(ctx):
    """`..` segments normalize lexically without leaving the workspace."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/shared/x",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "../shared/x",
        ),
    )
    return unittest.end(env)

def _lock_path_uses_the_lock_files_own_directory_test_impl(ctx):
    """A lock below the package root resolves entries against its own directory.

    Pub records a path dependency relative to the dependent package — the
    lock file's own directory, which is the label's package plus the dirname
    of its name. Ignoring the dirname links the wrong directory: with a root
    `localpkg/` decoy beside `app2/localpkg/`, the entry must still resolve
    to `app2/localpkg`.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "app2/localpkg",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//:app2/pubspec.lock"),
            "localpkg",
        ),
    )
    asserts.equals(
        env,
        "foo/app2/localpkg",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//foo:app2/pubspec.lock"),
            "localpkg",
        ),
    )
    asserts.equals(
        env,
        "shared/x",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//:app2/pubspec.lock"),
            "../shared/x",
        ),
    )
    return unittest.end(env)

lock_path_uses_the_lock_files_own_directory_test = unittest.make(_lock_path_uses_the_lock_files_own_directory_test_impl)

def _root_lock_needs_no_refusal_test_impl(ctx):
    """A main-repo lock (empty `workspace_name`) resolves path deps freely."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        foreign_lock_path_error(
            "deps",
            "platform_assets",
            struct(workspace_name = "", package = "e2e/hello_world"),
        ),
    )
    return unittest.end(env)

def _foreign_lock_path_dep_is_refused_test_impl(ctx):
    """A non-root lock's path dep is refused naming hub, package, and lock.

    Resolving it against the consumer workspace would link the wrong
    directory, silently. The message must carry everything the fix needs:
    declare the path dep in the root module's own lock instead.
    """
    env = unittest.begin(ctx)
    message = foreign_lock_path_error(
        "deps",
        "platform_assets",
        struct(workspace_name = "some_dep", package = ""),
    )
    asserts.true(env, message != None, "a foreign lock must be refused")
    asserts.true(env, "deps" in message, "refusal must name the hub")
    asserts.true(env, "platform_assets" in message, "refusal must name the package")
    return unittest.end(env)

root_lock_needs_no_refusal_test = unittest.make(_root_lock_needs_no_refusal_test_impl)
foreign_lock_path_dep_is_refused_test = unittest.make(_foreign_lock_path_dep_is_refused_test_impl)

lock_path_joins_the_lock_dir_test = unittest.make(_lock_path_joins_the_lock_dir_test_impl)
lock_path_stays_inside_the_workspace_test = unittest.make(_lock_path_stays_inside_the_workspace_test_impl)

def path_package_test_suite(name):
    """Declares the path-package spoke hermeticity unit tests.

    Args:
        name: Test suite name.
    """
    small_unittest_suite(
        name,
        absolute_lock_path_decides_test,
        ancestor_link_is_refused_test,
        case_folded_skip_applies_end_to_end_test,
        case_probe_needs_readdir_evidence_test,
        case_rule_folds_only_on_insensitive_hosts_test,
        cycle_refusal_names_the_link_test,
        dir_link_mirrors_not_symlinks_test,
        escaped_entries_link_decoded_test,
        foreign_lock_path_dep_is_refused_test,
        lib_and_asset_dir_skip_names_link_test,
        link_scopes_to_the_pubspec_plan_test,
        lock_path_joins_the_lock_dir_test,
        lock_path_stays_inside_the_workspace_test,
        lock_path_uses_the_lock_files_own_directory_test,
        malformed_pub_version_is_refused_test,
        matching_identity_links_test,
        missing_declared_paths_are_watched_test,
        nested_links_stay_confined_test,
        non_plugin_package_links_no_android_test,
        outside_workspace_is_refused_test,
        overlapping_entries_link_once_test,
        padded_identity_links_test,
        path_spoke_platform_dirs_test,
        plugin_platform_dir_is_mirrored_not_symlinked_test,
        pub_version_compares_semantically_test,
        pubspec_identity_parses_test,
        pubspec_mismatch_is_refused_test,
        relative_marker_decides_test,
        root_lock_needs_no_refusal_test,
        scoped_shader_includes_block_test,
        skipped_dirs_test,
        skips_stop_at_mirror_root_test,
        unversioned_identity_links_test,
        workspace_sibling_link_replicates_without_descending_test,
    )
