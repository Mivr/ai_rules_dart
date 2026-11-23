"""Sourcing Flutter repositories from a pre-extracted local Flutter SDK.

A warmed Flutter SDK on disk already holds every artifact the download-mode
repository rules fetch: its `bin/cache` tree is what `flutter precache` (and a
first `flutter build`) materializes from exactly the archives pinned in
`versions.bzl`. The helpers here let each repository rule serve its files out
of that tree instead of the network:

* `resolve_local_sdk_root` turns the user-facing `local_path` (workspace-root
  relative, or absolute) into a repository-space path, watching it so a moved
  SDK refetches.
* `read_local_sdk_version` parses `bin/cache/flutter.version.json`, so the
  version stamping and the version manifest come from the SDK's own bytes
  rather than a table that could drift from them.
* `link_local_dir` / `link_local_file` symlink one repo entry at a SDK
  subtree, failing with the expected SDK-relative path when it is absent, and
  watching the linked tree so edits invalidate the repository.

Every helper fails rather than falling back to the network: a local
repository never downloads.
"""

visibility(["//flutter/..."])

def resolve_local_sdk_root(repository_ctx, local_path):
    """Resolves a `local_path` toolchain value to a watched SDK root path.

    A relative path resolves against the main workspace root (the directory
    holding the root `MODULE.bazel`), so `local_path = "third_party/flutter"`
    means the same thing on every machine the workspace checks out on. An
    absolute path (POSIX, or a Windows drive path) is used as-is. `~` is not
    expanded: a leading `~` resolves to a literal `~` directory.

    Args:
        repository_ctx: The repository rule context.
        local_path: The user-supplied SDK path string. Must be non-empty.

    Returns:
        The SDK root as a `path` object, watched for changes.
    """
    if not local_path:
        fail("flutter local SDK: no local_path was given; pass the path to a pre-extracted Flutter SDK")
    if local_path.startswith("/") or (len(local_path) > 2 and local_path[1] == ":"):
        sdk_root = repository_ctx.path(local_path)
    else:
        sdk_root = repository_ctx.path(str(repository_ctx.workspace_root) + "/" + local_path)
    repository_ctx.watch(sdk_root)
    return sdk_root

def read_local_sdk_version(repository_ctx, sdk_root):
    """Reads the Flutter version and engine revision from a local SDK.

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.

    Returns:
        `struct(flutter_version, engine_revision)` parsed out of the SDK's own
        `bin/cache/flutter.version.json`.
    """
    manifest = sdk_root.get_child("bin/cache/flutter.version.json")
    if not manifest.exists:
        fail(
            "flutter local SDK: expected bin/cache/flutter.version.json under " +
            str(sdk_root) + ", but it does not exist; point local_path at a " +
            "pre-extracted Flutter SDK (one that has run `flutter precache`)",
        )
    repository_ctx.watch(manifest)
    parsed = json.decode(repository_ctx.read(manifest))
    flutter_version = parsed.get("flutterVersion", "")
    engine_revision = parsed.get("engineRevision", "")
    if not flutter_version or not engine_revision:
        fail(
            "flutter local SDK: bin/cache/flutter.version.json under " +
            str(sdk_root) + " has no flutterVersion/engineRevision; " +
            "it is not a usable Flutter SDK",
        )
    return struct(
        flutter_version = flutter_version,
        engine_revision = engine_revision,
    )

def missing_local_source_message(sdk_rel, what, root):
    """Renders the failure message for a local-SDK piece that is absent.

    A pure helper (no `repository_ctx`) so the wording is unit-testable: the
    message must name the real SDK-relative path, what it is, and the SDK
    root. Kept in one place so every repository rule reports a missing piece
    the same way.

    Args:
        sdk_rel: SDK-relative path that was expected (e.g. `"bin/cache/dart-sdk"`).
        what: Human-readable artifact description (e.g. `"the Flutter-bundled Dart SDK"`).
        root: The SDK root string, as the user passed it in `local_path`.

    Returns:
        The failure message string.
    """
    return (
        "flutter local SDK: expected {rel} ({what}) under {root}, but it " +
        "does not exist; point local_path at a complete pre-extracted " +
        "Flutter SDK (one that has run `flutter precache`)"
    ).format(
        rel = sdk_rel,
        what = what,
        root = root,
    )

def _check_local_source(repository_ctx, source, sdk_rel, what):
    if not source.exists:
        fail(missing_local_source_message(
            sdk_rel,
            what,
            str(repository_ctx.attr.local_path),
        ))

def link_local_dir(repository_ctx, sdk_root, sdk_rel, repo_rel, what):
    """Symlinks one repository directory at a local SDK subtree.

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.
        sdk_rel: SDK-relative source directory (e.g. `"bin/cache/dart-sdk"`).
        repo_rel: Repository-relative link to create (e.g. `"dart-sdk"`).
        what: Human-readable artifact description for the missing-path error
            (e.g. `"the Flutter-bundled Dart SDK"`).
    """
    source = sdk_root.get_child(sdk_rel)
    _check_local_source(repository_ctx, source, sdk_rel, what)
    repository_ctx.watch_tree(source)
    repository_ctx.symlink(source, repo_rel)

def link_local_file(repository_ctx, sdk_root, sdk_rel, repo_rel, what):
    """Symlinks one repository file at a local SDK file.

    Same contract as `link_local_dir`, for single files (e.g. `flutter.jar`).

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.
        sdk_rel: SDK-relative source file.
        repo_rel: Repository-relative link to create.
        what: Human-readable artifact description for the missing-path error.
    """
    source = sdk_root.get_child(sdk_rel)
    _check_local_source(repository_ctx, source, sdk_rel, what)
    repository_ctx.watch(source)
    repository_ctx.symlink(source, repo_rel)

def engine_cache_dir(artifact_path):
    """Returns the `bin/cache/artifacts/engine` subdirectory holding an artifact.

    Mirrors flutter_tool's `Cache` layout (`flutter_cache.dart` binary-dir
    tables): a plain archive (`darwin-x64/artifacts.zip`) extracts into
    `engine/<dir>/`, while a cross-compile gen_snapshot archive
    (`android-arm64-release/linux-x64.zip`) extracts one level deeper, into
    `engine/<dir>/<archive-base>/` — verified against a real `flutter
    precache --all-platforms` install. Bare filenames
    (`flutter_patched_sdk.zip`) extract into `engine/common/`.

    One layout quirk is normalized: the Linux and Windows *debug* desktop
    engines are published as `linux-x64-debug/linux-x64-flutter-gtk.zip` (and
    the Windows equivalent), but flutter_tool extracts them into the bare host
    directory (`engine/linux-x64/`, shared with the host tools) — see
    `LinuxEngineArtifacts.getBinaryDirs` and `_getWindowsDesktopBinaryDirs`,
    whose debug entries list `linux-$arch` / `windows-$arch` with no `-debug`
    suffix. Every other mode keeps its suffix (`-profile`, `-release`), and
    macOS never has one for debug.

    Args:
        artifact_path: GCS artifact path (e.g. `"ios-release/artifacts.zip"`).

    Returns:
        The cache subdirectory relative to `bin/cache/artifacts/engine`.
    """
    parts = artifact_path.split("/")
    if len(parts) == 1:
        return "common"
    cache_dir = "/".join(parts[:-1])
    base = parts[-1]
    is_host_archive = (
        base == "artifacts.zip" or base.endswith(".framework.zip") or
        base.endswith("-flutter.zip") or base.endswith("-flutter-gtk.zip") or
        base in ("font-subset.zip", "flutter-cpp-client-wrapper.zip")
    )
    if not is_host_archive:
        # A cross-compile gen_snapshot archive: one binary that extracts one
        # level deeper than its directory (`android-arm64-release/linux-x64.zip`
        # into `engine/android-arm64-release/linux-x64/`).
        if artifact_path.endswith(".zip"):
            return artifact_path[:-len(".zip")]
        return artifact_path
    for os_prefix in ("linux-", "windows-"):
        if cache_dir.startswith(os_prefix) and cache_dir.endswith("-debug"):
            return cache_dir[:-len("-debug")]
    return cache_dir

def host_engine_cache_dir(host_platform):
    """Maps a host platform key to the SDK engine-cache directory holding its tools.

    flutter_tool keeps one host-tools directory per host *OS family*, not per
    Bazel platform: macOS is always `darwin-x64` (the same universal binaries
    serve Apple Silicon via `darwin-$arch` archives — see
    `FlutterSdk.getBinaryDirs` and `FontSubsetArtifacts.getBinaryDirs`), while
    Linux and Windows keep their architecture (`linux-x64`, `linux-arm64`,
    `windows-x64`).

    Args:
        host_platform: Host platform key (e.g. `"darwin-arm64"`, `"linux-x64"`).

    Returns:
        The cache subdirectory relative to `bin/cache/artifacts/engine`.
    """
    if host_platform.startswith("darwin-"):
        return "darwin-x64"
    return host_platform

def macos_framework_cache_path(cache_dir):
    """Returns the engine-cache-relative path of the extracted macOS desktop framework.

    A real install holds the macOS desktop engine as an xcframework
    (`engine/darwin-x64/FlutterMacOS.xcframework`, per
    `_macOSDesktopBinaryDirs`); only the downloaded double-zip carries a bare
    `FlutterMacOS.framework`. The Linux/Windows lipo is universal, so the one
    `macos-arm64_x86_64` slice serves every Mac.

    Args:
        cache_dir: Engine-cache directory (e.g. `"darwin-x64"`,
            `"darwin-x64-profile"`).

    Returns:
        The framework path relative to `bin/cache/artifacts/engine`, to link
        as `engine/FlutterMacOS.framework`.
    """
    return (
        cache_dir +
        "/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework"
    )

def missing_local_file_message(src, what):
    """Renders the failure for a local-SDK file that must be staged but is absent.

    Pure helper so the exact wording is unit-testable: the whole
    concatenation is parenthesized before `.format()`, so every placeholder
    renders (an unparenthesized `"a{x}" + "b".format(...)` binds `.format()`
    to the last literal only and would print `{src}` literally).

    Args:
        src: Absolute source path string inside the local SDK.
        what: Human-readable description of the file.

    Returns:
        The failure message string.
    """
    return (
        "flutter local SDK: expected {src} ({what}), but it does not " +
        "exist; point local_path at a complete pre-extracted Flutter " +
        "SDK (one that has run `flutter precache`)"
    ).format(src = src, what = what)

def copy_failed_message(src, what, err):
    """Renders the failure for a local-SDK staging copy that errored.

    Args:
        src: Absolute source path string inside the local SDK.
        what: Human-readable description of the file.
        err: The copy tool's stderr.

    Returns:
        The failure message string.
    """
    return "flutter local SDK: could not stage {what} ({src}); {err}".format(
        what = what,
        src = src,
        err = err,
    )

def local_sdk_vm_path(sdk_bin, is_windows):
    """Resolves the local SDK's bundled Dart VM inside its `bin` directory.

    Args:
        sdk_bin: The SDK's `bin` directory path.
        is_windows: Whether the fetching host is Windows.

    Returns:
        The `dartvm` (`dartvm.exe`) path when present, else `dart` (`dart.exe`).
    """
    names = ["dartvm.exe", "dart.exe"] if is_windows else ["dartvm", "dart"]
    for name in names:
        candidate = sdk_bin.get_child(name)
        if candidate.exists:
            return candidate
    return sdk_bin.get_child(names[-1])

def local_sdk_vm_environment(is_windows):
    """The scrubbed environment for running the local SDK's Dart VM.

    Args:
        is_windows: Whether the fetching host is Windows.

    Returns:
        Environment overrides that blank the user's home-directory variables.
    """
    if is_windows:
        return {"USERPROFILE": "", "LOCALAPPDATA": ""}
    return {"HOME": ""}

def copy_local_file(repository_ctx, sdk_bin, src, dst, what, executable):
    """Stages one SDK file as a repo-owned copy, without network or host tools.

    Symlinks cannot be patched or rewritten in place without writing through
    into the user's SDK tree, so files the fetch must modify (the dartdev AOT
    snapshot) or must own (the `dart` launcher) are copied instead. The copy
    runs `copy_local_file.dart` on the SDK's own bundled Dart VM, so binary
    bytes survive and no `cp` or `cmd` is needed. The source is watched, so an
    SDK edit refetches the repository. The destination's parent directories
    must already exist.

    Args:
        repository_ctx: The repository rule context.
        sdk_bin: The local SDK's `bin` directory path, holding the Dart VM.
        src: Absolute source path string inside the local SDK.
        dst: Absolute destination path string inside the repository.
        what: Human-readable description for the failure message.
        executable: Whether the copy is made executable (`0755`, else `0644`).
    """
    src_path = repository_ctx.path(src)
    if not src_path.exists:
        fail(missing_local_file_message(src, what))
    repository_ctx.watch(src_path)
    is_windows = "windows" in repository_ctx.os.name.lower()
    result = repository_ctx.execute(
        [
            str(local_sdk_vm_path(sdk_bin, is_windows)),
            "--packages=" + str(repository_ctx.path(Label("//flutter/private/dartdev_patch:empty.json"))),
            str(repository_ctx.path(Label("//flutter/private/tools:copy_local_file.dart"))),
            src,
            dst,
            "true" if executable else "false",
        ],
        environment = local_sdk_vm_environment(is_windows),
    )
    if result.return_code != 0:
        fail(copy_failed_message(src, what, result.stderr.strip()))

def copy_local_text_file(repository_ctx, src, dst_rel, what):
    """Stages one UTF-8 text SDK file as a repo-owned copy in pure Starlark.

    For trimmed SDK fixtures that carry no bundled Dart VM. The source is
    watched, so an SDK edit refetches the repository.

    Args:
        repository_ctx: The repository rule context.
        src: Absolute source path string inside the local SDK.
        dst_rel: Destination path relative to the repository root.
        what: Human-readable description for the failure message.
    """
    src_path = repository_ctx.path(src)
    if not src_path.exists:
        fail(missing_local_file_message(src, what))
    repository_ctx.watch(src_path)
    repository_ctx.file(dst_rel, repository_ctx.read(src_path), executable = False)

def _stage_sdk_snapshots(repository_ctx, sdk_bin, sdk_snapshots):
    """Stages the Dart `bin/snapshots` directory: symlinks plus one copy.

    Every snapshot is a symlink into the SDK except
    `dartdev_aot.dart.snapshot`, which the fetch patches and so stages as a
    repo-owned copy. A trimmed tree without that snapshot stages nothing for
    it; the patch step then has nothing to rewrite.

    Args:
        repository_ctx: The repository rule context.
        sdk_bin: The SDK's `bin` directory path, holding the Dart VM.
        sdk_snapshots: The SDK's `bin/snapshots` directory path.
    """
    for entry in sdk_snapshots.readdir():
        name = entry.basename
        if name == "dartdev_aot.dart.snapshot":
            copy_local_file(
                repository_ctx,
                sdk_bin,
                str(entry),
                str(repository_ctx.path("dart-sdk/bin/snapshots/" + name)),
                "the dartdev AOT snapshot",
                False,
            )
        else:
            repository_ctx.symlink(entry, "dart-sdk/bin/snapshots/" + name)

def _stage_sdk_bin(repository_ctx, sdk_bin):
    """Stages the Dart `bin` directory: symlinks, a copied launcher, snapshots.

    `bin/dart` is a repo-owned copy, not a symlink: `dart` finds its
    snapshots next to its own real path, so a symlinked launcher would run
    the user's unpatched snapshot instead of the declared, patched one. A
    copied launcher keeps snapshot resolution inside the repository. Every
    other entry is a symlink; `snapshots` is staged by
    [_stage_sdk_snapshots](#_stage_sdk_snapshots).

    Args:
        repository_ctx: The repository rule context.
        sdk_bin: The SDK's `bin` directory path.
    """
    for entry in sdk_bin.readdir():
        name = entry.basename
        if name == "snapshots":
            _stage_sdk_snapshots(repository_ctx, sdk_bin, entry)
        elif name == "dart" or name == "dart.exe":
            copy_local_file(
                repository_ctx,
                sdk_bin,
                str(entry),
                str(repository_ctx.path("dart-sdk/bin/" + name)),
                "the Dart launcher",
                True,
            )
        else:
            repository_ctx.symlink(entry, "dart-sdk/bin/" + name)

def stage_local_dart_sdk(repository_ctx, sdk_root):
    """Stages the bundled Dart SDK as a hybrid tree of symlinks and copies.

    `dart-sdk/bin/dart` and `dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot`
    are repo-owned copies; every other entry is a symlink into the SDK. The
    copies exist so the `dart` that actions run loads the declared, patched
    snapshot next to its own real path (a symlinked launcher would resolve
    through to the user's SDK and run its unpatched snapshot), and so the
    fetch can patch the snapshot without writing through into the user's
    tree. The whole SDK is never copied. The SDK tree is watched, so an SDK
    edit refetches the repository.

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.
    """
    sdk_dart = sdk_root.get_child("bin/cache/dart-sdk")
    if not sdk_dart.exists:
        fail(missing_local_source_message(
            "bin/cache/dart-sdk",
            "the Flutter-bundled Dart SDK",
            str(repository_ctx.attr.local_path),
        ))
    repository_ctx.watch_tree(sdk_dart)
    repository_ctx.file("dart-sdk/bin/snapshots/.keep", "")
    repository_ctx.delete("dart-sdk/bin/snapshots/.keep")
    for entry in sdk_dart.readdir():
        if entry.basename == "bin":
            _stage_sdk_bin(repository_ctx, entry)
        else:
            repository_ctx.symlink(entry, "dart-sdk/" + entry.basename)

    # A trimmed tree (the smoke fixture's placeholder SDK) has no `bin/`
    # directory at all and stages nothing; the patch step then skips itself.
    # But a `bin/` directory without a launcher is a broken SDK, and staging
    # it silently would fail later with an action that cannot find `dart` —
    # so the fetch fails here instead, naming the missing file.
    has_launcher = repository_ctx.path("dart-sdk/bin/dart").exists or repository_ctx.path("dart-sdk/bin/dart.exe").exists
    if sdk_dart.get_child("bin").exists and not has_launcher:
        fail(missing_local_source_message(
            "bin/cache/dart-sdk/bin/dart",
            "the Dart launcher",
            str(repository_ctx.attr.local_path),
        ))
