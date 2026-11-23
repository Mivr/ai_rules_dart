"""Header classification and target-private search paths for `flutter_apple_plugin_library`.

A plugin keeps its public headers under the directories named in `includes`.
Every other `.h` file is a target-private header: it is a declared source of the
plugin's ObjC compile but never reaches the plugin's public headers or its Clang
module. A companion target publishes the directories of the headers the ObjC
sources import by basename; the compile reaches it only through
`implementation_deps`, so those directories never leak to dependents.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

visibility(["//flutter/..."])

def _package_path(label):
    """The package-relative path of a source label, or `None` when it is not in this package."""
    if label.startswith(":"):
        return label[1:]
    if label.startswith("//") or label.startswith("@//"):
        pkg, _, name = label[label.index("//") + 2:].partition(":")
        return name if pkg == native.package_name() and name else None
    if label.startswith("@"):
        return None
    return label

def _dir_of(path):
    """The directory part of a package-relative path; `""` at the package root."""
    return path.rpartition("/")[0]

def _normalize_include(include):
    """An include directory without trailing slashes; `.` is the package root."""
    include = include.rstrip("/")
    return "" if include == "." else include

def _is_under(directory, include):
    """Whether `directory` is `include` or lies inside it."""
    return include == "" or directory == include or directory.startswith(include + "/")

def plugin_header_layout(headers, objc_files, includes):
    """Classify a plugin's `.h` files for the `rules_apple` backend.

    With non-empty `includes`, only headers under an include directory are
    public; the rest are private. With empty `includes`, every header is public.
    `search` lists the headers whose directory needs a target-private search
    path: those outside the exact include directories, unless the whole plugin
    sits at the package root with no `includes`.

    Args:
        headers: The plugin's `.h` source labels.
        objc_files: The plugin's `.m` and `.mm` source labels.
        includes: Public header search directories, package-relative.

    Returns:
        struct(all, public, private, search) of label lists.
    """
    if type(includes) != "list":
        return struct(all = headers, public = headers, private = [], search = [])
    roots = [_normalize_include(i) for i in includes]
    public = []
    private = []
    search = []
    for h in headers:
        path = _package_path(h)
        directory = None if path == None else _dir_of(path)
        if not roots or (directory != None and [r for r in roots if _is_under(directory, r)]):
            public.append(h)
        else:
            private.append(h)
        if directory == None or directory not in roots:
            search.append(h)
    if not roots and not _any_nested(headers + objc_files):
        search = []
    return struct(all = headers, public = public, private = private, search = search)

def _any_nested(labels):
    """Whether any label is outside the package root, or cannot be placed."""
    for label in labels:
        path = _package_path(label)
        if path == None or _dir_of(path) != "":
            return True
    return False

def _private_header_dirs_impl(ctx):
    """Publish the directory of every header as a quote include path."""
    dirs = depset([f.dirname or "." for f in ctx.files.hdrs])
    return [CcInfo(compilation_context = cc_common.create_compilation_context(quote_includes = dirs))]

_private_header_dirs = rule(
    implementation = _private_header_dirs_impl,
    attrs = {
        "hdrs": attr.label_list(
            allow_files = [".h"],
            doc = "Headers whose directories become quote include paths.",
        ),
    },
    doc = "Adds the directories of the given headers to the quote include path of a dependent compile.",
)

def emit_plugin_private_header_dirs(spec, search_headers, name = None):
    """Emit the target-private search path companion for the ObjC compile.

    Args:
        spec: Plugin spec struct (`name`, `internal_tags`, `target_compatible_with`).
        search_headers: Header labels whose directories need a search path.
        name: Optional target name override.

    Returns:
        The `implementation_deps` list: the companion label, or empty when none is needed.
    """
    if not search_headers:
        return []
    target = name or ("_%s__private_header_dirs" % spec.name)
    _private_header_dirs(
        name = target,
        hdrs = search_headers,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return [":" + target]
