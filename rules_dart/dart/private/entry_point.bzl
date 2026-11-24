"""The entry point an executable takes from a library it depends on directly.

A stock project keeps `lib/main.dart` beside the rest of `lib/`, so the first
BUILD file a person writes for it globs all of `lib/` into a library and names
`lib/main.dart` as the `main` of the program that depends on it. One source
belongs to one target, and here the library owns it: the program compiles no
copy of `main`. Its entry module takes the library's `main` by the library's
`package:` URI (the module compiler links it from the library's module), and
whatever the entry adds (a test runner's bootstrap, the plugin registrant, a
native-assets mapping) names `main` by that URI too, so the linked program is
the one the stock tool compiles: the same `main`, in the same library.

Only `main`, and only a library in `deps` itself: a source an executable lists
in `srcs` that a library lists too, and a `main` that only a library further
down lists, are still the duplicate `duplicated_source` reports.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "owned_package_records")
load("//dart/private:dart_info.bzl", "package_lib_prefix")

visibility(["//dart/..."])

def entry_point_library(main, deps):
    """The library in `deps` that lists `main` among its own sources, or None.

    Reads each candidate's own files (`DefaultInfo.files`, which a library
    sets to its own sources), never a closure: only a dependency whose
    package's `lib/` holds `main` can list it.

    Args:
      main: The executable's `main` File, or None.
      deps: The executable's direct dependency targets.

    Returns:
      `struct(label, uri, file)`, or None: the library's label as a string, the
      `package:` URI its module compiles `main` under, and `main`.
    """
    if main == None:
        return None
    path = main.short_path
    for dep in deps:
        if DartInfo not in dep:
            continue
        record = None
        for r in owned_package_records(dep[DartInfo]):
            prefix = package_lib_prefix(r.lib_root)
            if r.package_name and path.startswith(prefix):
                record = r
                break
        if record == None:
            continue

        # lint-allow: depset-flatten a direct dependency's own files (no closure), only for the one whose `lib/` holds `main`
        if main not in dep[DefaultInfo].files.to_list():
            continue
        return struct(
            label = str(dep.label),
            uri = "package:%s/%s" % (record.package_name, path[len(package_lib_prefix(record.lib_root)):]),
            file = main,
        )
    return None

def entry_sources_from_library(sources, entry_point):
    """An entry module's sources once `main` comes from a library: no file of it.

    Args:
      sources: The entry's `struct(uri, file)` list, as the executable would
        compile it with `main` its own.
      entry_point: The struct from `entry_point_library`, or None.

    Returns:
      `sources` unchanged when `entry_point` is None. Otherwise the list with
      `main` replaced by `struct(uri = <its package: URI>, file = None)` when
      `main` is the entry point (first), and left out when another source
      (a bootstrap) is, since that source imports it by the same URI.
    """
    if entry_point == None:
        return sources
    out = []
    for i, s in enumerate(sources):
        if s.file != entry_point.file:
            out.append(s)
        elif i == 0:
            out.append(struct(uri = entry_point.uri, file = None))
    return out
