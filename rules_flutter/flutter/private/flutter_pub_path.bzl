"""Workspace-relative resolution for `relative: true` pub path dependencies.

Lives apart from `extensions.bzl` so the extension file stays under the
quality floor's per-file size cap; the extension `load()`s both helpers.
"""

visibility(["//flutter/..."])

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
        fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" has absolute path {path} in the lock. Re-resolve the lock with a relative `path:` dependency inside the workspace.".format(
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
                fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" resolves outside the workspace. Refusing it rather than reaching outside the workspace.".format(
                    hub = hub_name,
                    pkg = package_name,
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
