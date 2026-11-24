"""Workspace-relative resolution for `relative: true` pub path dependencies.

Lives apart from `extensions.bzl` so the extension file stays under the
quality floor's per-file size cap. A path package has no server to plan it
from: `collect_path_deps` reads every path package's own pubspec at
evaluation, confined to the workspace, for the dependency names planning
needs.
"""

load("@rules_dart//dart/pub:yaml.bzl", "pubspec_deps", "yaml_to_json")
load("//flutter/private:flutter_pub_mirror.bzl", "detect_case_insensitive_host", "outside_workspace_refusal", "path_spoke_resolves_outside")

visibility(["//flutter/..."])

# What a user does about a path package Bazel cannot see.
_OUTSIDE_REMEDY = (
    " Bazel builds only what is inside the workspace: move the package into it (as a pub workspace " +
    "member, say) and run `flutter pub get`, or depend on it from a pub server or a git repository."
)

def is_relative_path_dependency(relative_value):
    """Whether a lock `description.relative` value counts as `relative: true`.

    The lock parser stringifies every description value, so a YAML
    `relative: false` arrives as the string `"False"` — which is truthy in
    Starlark, and the old truthiness test never refused it. Only the
    parsed string `"true"` (any case) or a real boolean `True` accepts
    the entry; `False`, a missing or empty value, or anything else
    refuses it. Returning a boolean instead of failing keeps the rule
    testable: `unittest` cannot assert on `fail()`.

    Args:
        relative_value: The lock entry's `relative` description value.

    Returns:
        True only for a true relative marker.
    """
    if type(relative_value) == "bool":
        return relative_value
    if type(relative_value) == "string":
        return relative_value.lower() == "true"
    return False

def is_absolute_lock_path(entry_path):
    """Whether a lock path value is absolute in any spelling.

    Catches POSIX (`/x`), drive-letter (`C:/x`, `C:\\x`, and bare `C:`
    drive-relative, which resolves against the fetch host's drive), and
    UNC (`\\\\server\\x`, via its leading backslash; `//server/x` via its
    leading slash) spellings. Anything else — including `..` segments,
    which `workspace_relative_lock_path` still normalizes lexically and
    refuses when they leave the workspace — is not absolute.

    Args:
        entry_path: The lock entry's path value.

    Returns:
        True when the path is absolute and must be refused.
    """
    if type(entry_path) != "string" or not entry_path:
        return False
    first = entry_path[0]
    if first == "/" or first == "\\":
        return True
    if len(entry_path) >= 2 and entry_path[1] == ":":
        drive = entry_path[0]
        if (drive >= "A" and drive <= "Z") or (drive >= "a" and drive <= "z"):
            return True
    return False

def foreign_lock_path_error(hub_name, package_name, lock_label):
    """Refuse a `relative: true` path dependency under a non-root lock.

    Args:
        hub_name: The flutter.pub hub name, for the refusal message.
        package_name: The path dependency's name, for the refusal message.
        lock_label: The lock file label. Under Bazel's module extension
            semantics a path dependency is relative to the dependent
            package, which lives in the module that owns the lock. A label
            attribute on a module extension tag resolves in the defining
            module, and `ctx.workspace_root` in the spoke is always the
            root module — so a lock owned by a non-root module has no
            repository-local root the spoke could resolve against.
            Resolving the path in the consumer workspace would link the
            wrong directory without a sound repository to anchor it.

    Returns:
        `None` for a root-module lock (empty `workspace_name`): entry
        paths resolve against the consumer workspace, and the spoke
        re-validates the result. Otherwise a human-readable refusal naming
        the hub, the package, and the owning module; the caller `fail()`s
        with it. Returning the message instead of failing keeps the rule
        testable: `unittest` cannot assert on `fail()`.
    """
    if not lock_label.workspace_name:
        return None
    return (
        "flutter.pub hub \"{hub}\": path dependency \"{pkg}\" is locked by " +
        "module \"{owner}\", not the root module. `relative: true` paths " +
        "resolve in the lock-owning module, which the spoke cannot reach " +
        "from the consumer workspace. Declare the `path:` dependency in " +
        "the root module's own lock instead."
    ).format(
        hub = hub_name,
        pkg = package_name,
        owner = lock_label.workspace_name,
    )

def workspace_relative_lock_path(hub_name, package_name, lock_label, entry_path):
    """Join a `relative: true` lock path onto the lock file's directory.

    Pub records a path dependency relative to the dependent package — for a
    root dependency, the lock file's own directory. The extension resolves it
    lexically to a workspace-relative path and fails closed on anything that
    escapes the workspace; the spoke rule re-validates at fetch time.

    Args:
        hub_name: The flutter.pub hub name, for failure messages.
        package_name: The path dependency's name, for failure messages.
        lock_label: The lock file label; its package plus the dirname of
            its name is the lock's directory. Must live in the root module
            (see `foreign_lock_path_error`).
        entry_path: The lock entry's relative path value.

    Returns:
        The workspace-relative package directory.
    """
    if is_absolute_lock_path(entry_path):
        fail(("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" has absolute path {path} in the lock." +
              _OUTSIDE_REMEDY).format(
            hub = hub_name,
            pkg = package_name,
            path = repr(entry_path),
        ))
    parts = []
    if lock_label.package:
        parts.extend(lock_label.package.split("/"))
    lock_dir = lock_label.name.rpartition("/")[0]
    if lock_dir:
        parts.extend(lock_dir.split("/"))
    parts.extend(entry_path.replace("\\", "/").split("/"))
    out = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not out:
                fail(("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" on {path} resolves outside the workspace." +
                      _OUTSIDE_REMEDY).format(
                    hub = hub_name,
                    pkg = package_name,
                    path = repr(entry_path),
                ))
            out.pop()
        else:
            out.append(part)
    if not out:
        fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" resolves to the workspace root, not a package directory. Refusing it rather than symlinking the whole workspace.".format(
            hub = hub_name,
            pkg = package_name,
        ))
    return "/".join(out)

def normalize_realpath(raw):
    """Normalizes a realpath string to forward slashes without a trailing slash.

    Windows drive roots such as `D:/` or `D:\\` normalize to `D:` so joining
    `"/"` in confinement checks produces `D:/...` rather than `D://...`.

    Args:
        raw: A path object or path string.

    Returns:
        The normalized forward-slash path string.
    """
    norm = str(raw).replace("\\", "/")
    if len(norm) > 1 and norm.endswith("/"):
        norm = norm.rstrip("/")
    return norm

def _is_case_insensitive_workspace(ws_root, ws_realpath, segments, os_name):
    """Returns True when path confinement checks should fold case."""
    if "win" in os_name.lower():
        return True
    if len(ws_realpath) >= 2 and ws_realpath[1] == ":":
        drive = ws_realpath[0]
        if ("A" <= drive and drive <= "Z") or ("a" <= drive and drive <= "z"):
            return True
    if hasattr(ws_root, "readdir"):
        return detect_case_insensitive_host(struct(workspace_root = ws_root), segments)
    return False

def _prefix_escape_error(ws_root, ws_realpath, hub_name, name, segments, case_insensitive):
    """Returns a confinement error if any existing prefix of `segments` resolves outside `ws_realpath`."""
    prefix = []
    for seg in segments:
        prefix.append(seg)
        node = ws_root.get_child(*prefix)
        if not node.exists:
            break
        node_real = normalize_realpath(node.realpath)
        if path_spoke_resolves_outside(ws_realpath, node_real, case_insensitive):
            return 'flutter.pub hub "%s": path dependency "%s" resolves outside workspace (%s)' % (
                hub_name,
                name,
                str(node.realpath),
            )
    return None

def resolve_path_pubspec(ws_root, ws_realpath, hub_name, name, rel_path, os_name = ""):
    """Validates workspace confinement for `<rel_path>/pubspec.yaml` without failing.

    Accepts forward-slash or backslash relative paths while refusing POSIX,
    Windows drive-letter, and UNC absolute paths, `.`/`..` segments, missing or
    directory `pubspec.yaml` entries, and symlinks resolving outside the
    workspace root. Returns the `pubspec_file` `path` directly so callers pass
    it to `yaml_to_json` without constructing a Bazel package `Label`
    (which fails on case-insensitive hosts when a directory such as `build/`
    collides in name with `BUILD`).

    Args:
        ws_root: The workspace root `path` object.
        ws_realpath: Normalized realpath string of `ws_root`.
        hub_name: The `flutter.pub` hub name.
        name: The pub package name.
        rel_path: The lock's workspace-relative path string.
        os_name: Host OS name from `module_ctx.os.name`, if available.

    Returns:
        `struct(segments, pubspec_file, error)` where `error` is `None` on
        success or a human-readable refusal message.
    """
    if is_absolute_lock_path(rel_path) or rel_path in ("", "."):
        err = 'flutter.pub hub "%s": path dependency "%s" has invalid path %r' % (
            hub_name,
            name,
            rel_path,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    segments = rel_path.replace("\\", "/").split("/")
    if ".." in segments or "." in segments or "" in segments:
        err = 'flutter.pub hub "%s": path dependency "%s" escapes workspace (%r)' % (
            hub_name,
            name,
            rel_path,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    norm_ws = normalize_realpath(ws_realpath)
    case_insensitive = _is_case_insensitive_workspace(ws_root, norm_ws, segments, os_name)
    prefix_err = _prefix_escape_error(ws_root, norm_ws, hub_name, name, segments, case_insensitive)
    if prefix_err:
        return struct(segments = [], pubspec_file = None, error = prefix_err)
    pkg_dir = ws_root.get_child(*segments)
    pubspec_file = pkg_dir.get_child("pubspec.yaml")
    if not pubspec_file.exists or (hasattr(pubspec_file, "is_dir") and pubspec_file.is_dir):
        err = 'flutter.pub hub "%s": path dependency "%s" has no readable pubspec.yaml' % (
            hub_name,
            name,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    pubspec_real = normalize_realpath(pubspec_file.realpath)
    if path_spoke_resolves_outside(norm_ws, pubspec_real, case_insensitive):
        err = 'flutter.pub hub "%s": path dependency "%s" pubspec.yaml resolves outside workspace (%s)' % (
            hub_name,
            name,
            str(pubspec_file.realpath),
        )
        return struct(segments = [], pubspec_file = None, error = err)
    return struct(segments = segments, pubspec_file = pubspec_file, error = None)

def _resolve_workspace_root(module_ctx, lock_label):
    """Resolves the root module's workspace directory `path` from `lock_label`."""
    if lock_label == None:
        return module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    root = module_ctx.path(lock_label).dirname
    lock_dir = lock_label.name.rpartition("/")[0]
    if lock_dir:
        for _ in lock_dir.split("/"):
            root = root.dirname
    if lock_label.package:
        for _ in lock_label.package.split("/"):
            root = root.dirname
    return root

def collect_path_deps(module_ctx, hub_name, path_pkgs, lock_label = None):
    """Collects pubspec dependencies for workspace path packages.

    Args:
        module_ctx: The module extension context.
        hub_name: The name of the pub hub.
        path_pkgs: Dict mapping package name to path package info struct.
        lock_label: Optional root-module `pubspec.lock` label anchoring the workspace root.

    Returns:
        Dict mapping package name to its sorted dependency list.
    """
    if not path_pkgs:
        return {}
    ws_root = _resolve_workspace_root(module_ctx, lock_label)
    ws_realpath = normalize_realpath(ws_root.realpath)
    os_name = module_ctx.os.name if hasattr(module_ctx, "os") else ""
    names = []
    pubspec_files = []

    for name in sorted(path_pkgs.keys()):
        info = path_pkgs[name]
        resolved = resolve_path_pubspec(
            ws_root,
            ws_realpath,
            hub_name,
            name,
            info.path,
            os_name = os_name,
        )
        if resolved.error:
            fail(resolved.error)
        module_ctx.watch(resolved.pubspec_file)
        names.append(name)
        pubspec_files.append(resolved.pubspec_file)

    # Every path package's pubspec in one `yaml2json` run.
    data = yaml_to_json(module_ctx, pubspec_files, [path_pkgs[name].path + "/pubspec.yaml" for name in names])
    return {name: sorted(pubspec_deps(pubspec)) for name, pubspec in zip(names, data)}

def fail_on_outside_package_path(ctx, package_name, segments, workspace_realpath, case_insensitive = False):
    """Fail when the package dir or any parent component leaves the workspace.

    A path whose intermediate directory is a link out of the workspace
    (`third_party -> /host`) would otherwise be accepted: lexically the
    entry stays inside, but the resolved tree is host bytes. Each prefix
    of the workspace-relative path is resolved and refused, naming the
    package, the offending prefix, and its real path, when it lands
    outside the main workspace's real root. Missing prefixes stop the
    walk: the caller reports the missing directory itself.

    Args:
        ctx: The repository context.
        package_name: The pub package being linked, for the refusal.
        segments: The workspace-relative path split on `/`.
        workspace_realpath: The workspace root's resolved real path.
        case_insensitive: True when the fetch host proves case-insensitive.
    """
    prefix = []
    for segment in segments:
        prefix.append(segment)
        node = ctx.workspace_root.get_child(*prefix)
        if not node.exists:
            break
        target_realpath = str(node.realpath)
        if path_spoke_resolves_outside(workspace_realpath, target_realpath, case_insensitive):
            fail(outside_workspace_refusal(package_name, "/".join(prefix), target_realpath))

def path_package_root(ctx):
    """Resolve a path package's workspace-root directory, refusing escapes.

    Every path spoke uses this one validation: an absolute path, a `.`/`..`
    segment, a missing directory, or any parent component resolving outside
    the workspace fails.

    Args:
        ctx: A repository context with `path`, `package_name`.

    Returns:
        `struct(src, segments, workspace_realpath, package_realpath,
        case_insensitive)` for the package directory.
    """
    rel = ctx.attr.path
    if rel.startswith("/") or rel in ("", "."):
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} is not a workspace-relative package directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    segments = rel.split("/")
    if ".." in segments or "." in segments or "" in segments:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} escapes its directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    src = ctx.workspace_root.get_child(*segments)
    if not src.exists:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} does not exist under the workspace. Refusing it rather than emitting an empty package.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    workspace_realpath = str(ctx.workspace_root.realpath)
    case_insensitive = detect_case_insensitive_host(ctx, segments)
    fail_on_outside_package_path(ctx, ctx.attr.package_name, segments, workspace_realpath, case_insensitive)
    return struct(
        src = src,
        segments = segments,
        workspace_realpath = workspace_realpath,
        package_realpath = str(src.realpath),
        case_insensitive = case_insensitive,
    )
