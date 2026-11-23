"""How `pub.from_lock` serves the `path`, `sdk` and unknown sources of a lock.

`hosted` and `git` entries become package repositories (`pub_emit.bzl`). The
other sources a `pubspec.lock` can hold are served like this:

- `path`: the package is source in the module that owns the lock, the way
  `dart pub get` reads it from its directory. Its directory (the lock's
  directory joined with `description.path`) holds a BUILD file with a
  `dart_library` named after the package, as Gazelle writes it; the hub
  aliases `@<hub>//:<name>` to `//<dir>:<name>`, and a package repository that
  depends on the package (a `dependency_overrides` fork, say) gets that label
  too. No repository is generated: an edit to the package is an edit to the
  module. A directory without a BUILD file gets a hub target that fails when
  used, naming the package and what to write; a path outside the module, or an
  absolute one, fails the evaluation.
- `sdk`: an SDK package (`flutter`, `flutter_test`, ...) that only the Flutter
  rules build. The hub gets a target that fails when used, naming the package
  and `flutter.pub`; a package repository that depends on it drops the edge,
  as before, so a Flutter lock still serves its pure-Dart packages (builders
  for `dart_build_runner`, say).
- anything else fails the evaluation, naming the package and the source.
"""

visibility(["//dart/..."])

def _segments(path):
    return [seg for seg in path.split("/") if seg and seg != "."]

def lock_dir_segments(lock):
    """The directory of a lock file in its repository, as path segments.

    Args:
      lock: The lock file's Label.

    Returns:
      The label's package segments plus the directory part of its name.
    """
    return _segments(lock.package) + _segments(lock.name.rpartition("/")[0])

def _is_true(value):
    return type(value) == "string" and value.lower() == "true"

def _is_absolute(path):
    return path.startswith("/") or path.startswith("\\") or (len(path) >= 2 and path[1] == ":")

def path_package_dir(name, info, lock):
    """Resolves a `source: path` entry to its directory in the lock's repository.

    Pub records a path dependency relative to the directory of the package
    that depends on it, which for every entry of a lock is the lock's own
    directory (`relative: true`); an absolute path is `relative: false`.

    Args:
      name: The package name.
      info: The decoded lock entry.
      lock: The lock file's Label.

    Returns:
      `struct(dir, error)`: `dir` is the package directory relative to the
      repository root (`""` for the root), or `error` says why the entry
      cannot be served.
    """
    desc = info.get("description", {})
    path = desc.get("path", "") if type(desc) == "dict" else ""
    where = 'pub package "%s" in %s is a path dependency' % (name, lock)
    if type(path) != "string" or not path:
        return struct(dir = None, error = "%s with no `path` in its description. Run `dart pub get` and commit the lock." % where)
    if _is_absolute(path) or not _is_true(desc.get("relative", "")):
        return struct(dir = None, error = (
            "%s on the absolute path \"%s\". Bazel builds only what is inside the module, so a path " +
            "package must be a relative `path:` inside it: move the package into the module (as a pub " +
            "workspace member, say) and run `dart pub get`."
        ) % (where, path))
    out = []
    for seg in lock_dir_segments(lock) + path.replace("\\", "/").split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not out:
                return struct(dir = None, error = (
                    "%s on \"%s\", which is outside the module that owns the lock. Bazel builds only " +
                    "what is inside the module: move the package into it (as a pub workspace member, " +
                    "say) and run `dart pub get`, or depend on it from a pub server or a git repository."
                ) % (where, path))
            out.pop()
        else:
            out.append(seg)
    return struct(dir = "/".join(out), error = None)

def path_package_label(name, lock, dir):
    """The label of a path package's `dart_library`: `//<dir>:<name>` in the lock's repository.

    Args:
      name: The package name (the target name Gazelle gives a package's library).
      lock: The lock file's Label.
      dir: The package directory, from `path_package_dir`.

    Returns:
      The label string, canonical so that it means the same in every repository.
    """
    return "@@%s//%s:%s" % (lock.repo_name, dir, name)

def missing_build_file_message(name, lock, dir):
    """The message of a hub target for a path package whose directory has no BUILD file.

    Args:
      name: The package name.
      lock: The lock file's Label.
      dir: The package directory.

    Returns:
      The message.
    """
    return (
        "pub package \"%s\" in %s is a path dependency on the directory \"%s\", which has no BUILD file. " +
        "Add one with a `dart_library` named \"%s\" (Gazelle writes it), and depend on it as //%s or " +
        "through this hub."
    ) % (name, lock, dir or ".", name, dir)

def sdk_package_message(name, info, lock):
    """The message of a hub target for an SDK package.

    Args:
      name: The package name.
      info: The decoded lock entry.
      lock: The lock file's Label.

    Returns:
      The message.
    """
    sdk = info.get("description", {}).get("name", "") or "?"
    return (
        "pub package \"%s\" in %s comes from the \"%s\" SDK (source: sdk), which `pub.from_lock` does not " +
        "build. Depend on it through the hub of rules_flutter's `flutter.pub`, which reads the same lock."
    ) % (name, lock, sdk)

def unknown_source_error(name, info, lock):
    """The evaluation error for a lock entry whose source no rule serves.

    Args:
      name: The package name.
      info: The decoded lock entry.
      lock: The lock file's Label.

    Returns:
      The message.
    """
    return (
        "pub package \"%s\" %s in %s has source \"%s\", which `pub.from_lock` cannot serve: it serves " +
        "hosted, git, path and sdk entries. Depend on the package from a pub server, a git repository or " +
        "a path inside the module, run `dart pub get`, and commit the lock."
    ) % (name, info.get("version", ""), lock, info.get("source", ""))

def local_entry_conflict(name, kind, first, second):
    """The error for one package name served from two places across locks.

    Args:
      name: The package name.
      kind: What the second entry is (`a path package at //x`, `a hosted package`, ...).
      first: What the first entry is, the same way.
      second: The lock of the second entry.

    Returns:
      The message.
    """
    return "pub package \"%s\" is %s in one lock and %s in %s. Make the locks agree (`dart pub get`)." % (name, first, kind, second)

def _repo_root(ctx, lock):
    """The directory of the lock's repository, walked up from the lock file."""
    root = ctx.path(lock).dirname
    for _ in lock_dir_segments(lock):
        root = root.dirname
    return root

def check_path_build_files(ctx, resolution):
    """Turns each path package of the root module whose directory has no BUILD file into a failing hub target.

    Both `BUILD.bazel` and `BUILD` are watched whether or not they exist, so
    adding one re-evaluates. A path package of another module's lock is not
    checked: that module ships its BUILD files.

    Args:
      ctx: The module extension context.
      resolution: The `resolve_pub_packages` result; its `path_packages` and
        `unavailable` are updated in place.

    Returns:
      The same resolution.
    """
    for hub_name in sorted(resolution.path_packages.keys()):
        packages = resolution.path_packages[hub_name]
        for name in sorted(packages.keys()):
            pkg = packages[name]
            if pkg.lock.repo_name != "":
                continue
            directory = _repo_root(ctx, pkg.lock)
            for seg in pkg.dir.split("/") if pkg.dir else []:
                directory = directory.get_child(seg)
            found = False
            for build in ["BUILD.bazel", "BUILD"]:
                path = directory.get_child(build)
                ctx.watch(path)
                found = found or path.exists
            if not found:
                resolution.unavailable.setdefault(hub_name, {})[name] = missing_build_file_message(name, pkg.lock, pkg.dir)
                packages[name] = struct(label = "@%s//:%s" % (hub_name, name), dir = pkg.dir, lock = pkg.lock)
    return resolution
