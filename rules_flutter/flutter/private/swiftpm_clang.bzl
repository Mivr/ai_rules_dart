"""SwiftPM C-family (`clang`) target translation.

Decides, for one C-family target, which module every Swift importer sees
and which Bazel rules carry the target's sources: the caller supplies
`module_name` (the C99-mangled module name, SwiftPM's `c99name`);
`module_map` is the explicit `module.modulemap` (used as-written) when
the target ships one, else a generated umbrella map for the
`publicHeadersPath` and target-rooted (single-directory) layouts, and
None when the target has no public headers at all — such a target is
link-only and gets no interop hint. The
BUILD emitter (`swiftpm_translate.bzl`) renders the spec this file
computes; the repo rule (`swiftpm_package.bzl`) classifies the sources
and writes the generated map.

Errors are bare details: the caller wraps them with the package identity
(the manifest parser with its `Package.swift` line format, the emitter
with its hub format). Every detail names the target.
"""

load(":swiftpm_paths.bzl", "swiftpm_join_path", "swiftpm_normalize_relative_path")
load(":swiftpm_settings.bzl", "swiftpm_render_list_attr")

visibility(["//flutter/..."])

def _swiftpm_module_spec_failure(detail):
    """The `swiftpm_clang_module_spec` failure result."""
    return struct(
        ok = False,
        detail = detail,
        module_map = None,
        include_dir = None,
        umbrella_header = None,
    )

def swiftpm_clang_module_spec(target, module_name, target_dir, sources, public_headers, explicit_map):
    """Compute one C-family target's module spec.

    The module map search walks the target directory the way SwiftPM's
    `ClangTarget.moduleMapPath` does: an explicit `module.modulemap` at
    the target root wins, otherwise the one in the public-headers
    directory (`include/` by default, `publicHeadersPath` when set),
    used as-written. Without an explicit map the public-headers
    directory — `include/` unless `publicHeadersPath:` is set, when an
    explicit `""`/`"."` is the target root itself — gets a generated map:
    `<public>/<c99name>.h` is the umbrella header when present, else
    `<public>/<c99name>/<c99name>.h`, else the directory itself is the
    umbrella directory. A target with no public headers at all is
    link-only and gets no map. Any mix of C,
    C++, Objective-C and Objective-C++ sources translates to the one
    C-family library, the way SwiftPM builds such targets; only assembly
    sources have no Bazel translation, and the refusal names the file.

    Args:
        target: The parsed target struct (`name`, for messages,
            `public_headers_path` for the public-headers directory).
        module_name: The C99-mangled module name, for the umbrella
            header lookup.
        target_dir: The repo-relative target directory.
        sources: The repo-relative C-family source files.
        public_headers: The repo-relative public header files.
        explicit_map: The repo-relative explicit `module.modulemap`, or
            None.

    Returns:
        `struct(ok, detail, module_map, include_dir, umbrella_header)`:
        `module_map` is the repo-relative map (explicit or generated) or
        None; `include_dir` is the public-headers directory (for the
        search path) or None; `umbrella_header` is the umbrella header
        path relative to the public-headers directory, or None for the
        umbrella-directory form.
    """
    who = "target " + repr(target.name)
    for source in sources:
        if _swiftpm_clang_language(source) == "asm":
            return _swiftpm_module_spec_failure(
                "{who} has assembly source {file}, which has no Bazel translation".format(
                    who = who,
                    file = repr(source),
                ),
            )
    if explicit_map != None:
        return struct(ok = True, detail = "", module_map = explicit_map, include_dir = None, umbrella_header = None)
    if target.public_headers_path != None:
        normalized = swiftpm_normalize_relative_path(target.public_headers_path)
        if not normalized.ok:
            return _swiftpm_module_spec_failure(
                "{who} has a `publicHeadersPath:` escaping the target directory".format(who = who),
            )
        public_dir = swiftpm_join_path(target_dir, normalized.path)
    else:
        public_dir = swiftpm_join_path(target_dir, "include")
    if not public_headers:
        return struct(ok = True, detail = "", module_map = None, include_dir = None, umbrella_header = None)
    umbrella_header = None
    if swiftpm_join_path(public_dir, module_name + ".h") in public_headers:
        umbrella_header = module_name + ".h"
    elif swiftpm_join_path(public_dir, module_name + "/" + module_name + ".h") in public_headers:
        umbrella_header = module_name + "/" + module_name + ".h"
    return struct(
        ok = True,
        detail = "",
        module_map = swiftpm_join_path(public_dir, "module.modulemap"),
        include_dir = public_dir,
        umbrella_header = umbrella_header,
    )

def _swiftpm_clang_language(source):
    """Classify one source file by extension.

    Args:
        source: The repo-relative file path.

    Returns:
        `c`, `cxx`, `objc`, `objcxx`, `asm` or `other`.
    """
    for suffix in [".mm", ".M"]:
        if source.endswith(suffix):
            return "objcxx"
    for suffix in [".m"]:
        if source.endswith(suffix):
            return "objc"
    for suffix in [".cc", ".cpp", ".cxx", ".c++", ".C", ".cp"]:
        if source.endswith(suffix):
            return "cxx"
    for suffix in [".c"]:
        if source.endswith(suffix):
            return "c"
    for suffix in [".s", ".S", ".asm"]:
        if source.endswith(suffix):
            return "asm"
    return "other"

def swiftpm_clang_rule(sources):
    """Pick the Bazel rule carrying one target's sources.

    Args:
        sources: The repo-relative C-family source files.

    Returns:
        `"objc_library"` when any source is Objective-C (`.m`/`.mm`),
        else `"cc_library"`.
    """
    for source in sources:
        language = _swiftpm_clang_language(source)
        if language == "objc" or language == "objcxx":
            return "objc_library"
    return "cc_library"

def swiftpm_generated_modulemap_content(module_name, umbrella_header, public_dir, public_headers):
    """Render a generated umbrella module map's contents.

    Every path resolves relative to the directory the map file lives
    in (the public-headers directory): an `umbrella header` line names
    the umbrella header there, else `umbrella "."` names that same
    directory and each `header` line names a public header relative to
    it.

    Args:
        module_name: The C99-mangled module name.
        umbrella_header: The umbrella header path relative to the
            public-headers directory, or None for the umbrella-directory
            form.
        public_dir: The repo-relative public-headers directory, for
            header paths.
        public_headers: The repo-relative public header files, all under
            `public_dir`.

    Returns:
        The `module.modulemap` text.
    """
    lines = ["module {name} {{".format(name = module_name)]
    if umbrella_header:
        lines.append("    umbrella header \"{path}\"".format(path = umbrella_header))
    else:
        lines.append("    umbrella \".\"")
        for header in public_headers:
            lines.append("    header \"{path}\"".format(path = header[len(public_dir) + 1:]))
    lines.append("    export *")
    lines.append("}")
    return "\n".join(lines) + "\n"

def swiftpm_render_clang_library(lib):
    """Render one C-family target's `cc_library`/`objc_library`.

    The library carries the public headers in `hdrs` and the private
    ones in `srcs`: they compile with the target's own sources but stay
    invisible to dependents. The public header search paths go in
    `includes` (hermetic in the spoke repository, where a `-I` in `copts`
    would not rebase). A `.headerSearchPath` from `cSettings`/
    `cxxSettings` is target-local in SwiftPM: its paths go on a separate
    header-only library that the target reaches through
    `implementation_deps`, so dependents never see them. The module name
    — plus the module map, explicit or generated, so the one map Swift
    and clang use is SwiftPM's — goes in `aspect_hints` via a separate
    `swift_interop_hint` target (a rule, so it needs its own `name`) so
    Swift importers see the same module SwiftPM computes. A target with
    no public headers gets no hint: it is link-only. Lists render through
    `swiftpm_render_list_attr`, so `.when(platforms:)`-gated settings and
    dependencies become `select()`s on the target platform's OS.

    Args:
        lib: `struct(library_name, rule, srcs, public_headers,
            private_headers, module_name, module_map, explicit_map,
            c_only, cxx, linkopts, includes, private_includes, deps,
            tags)`: the Bazel library name; `"cc_library"` or
            `"objc_library"`; the unconditional source labels; the
            unconditional public and private header labels; the
            C99-mangled module name ("" for link-only); the module map
            label — the explicit `module.modulemap` when the target ships
            one, else the generated `<public>/module.modulemap` the repo
            rule writes — or None for link-only; whether `module_map` is
            an explicit map (informational: both forms reach the hint the
            same way); `struct(text, platforms)` C-family, C++, link option,
            public include, target-local include and dependency entries;
            the manual-tag list.

    Returns:
        The rule text (the caller loads `swift_interop_hint` when the
        library has a hint).
    """
    lines = ["{rule}(".format(rule = lib.rule), '    name = "{name}",'.format(name = lib.library_name)]
    lines.append("    srcs = [")
    for src in lib.srcs + lib.private_headers:
        lines.append("        {item},".format(item = repr(src)))
    lines.append("    ],")
    lines.append("    hdrs = [")
    for header in lib.public_headers:
        lines.append("        {item},".format(item = repr(header)))
    lines.append("    ],")
    lists = swiftpm_render_list_attr("copts", [], lib.c_only)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("cxxopts", [], lib.cxx)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("includes", [], lib.includes)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("linkopts", [], lib.linkopts)
    if lists:
        lines.append(lists)
    if lib.module_name:
        lines.append("    aspect_hints = [\":{name}_interop_hint\"],".format(name = lib.library_name))
    if lib.private_includes:
        lines.append("    implementation_deps = [\":{name}_private_headers\"],".format(name = lib.library_name))
    lists = swiftpm_render_list_attr("deps", [], lib.deps)
    if lists:
        lines.append(lists)
    lines.append("    tags = [{tags}],".format(tags = ", ".join([repr(tag) for tag in lib.tags])))
    lines.append(")")
    if lib.private_includes:
        lines.append("")
        lines.extend(_swiftpm_render_private_headers_library(lib))
    if lib.module_name:
        lines.append("")
        lines.append("swift_interop_hint(")
        lines.append("    name = \"{name}_interop_hint\",".format(name = lib.library_name))
        lines.append("    module_name = {name},".format(name = repr(lib.module_name)))
        if lib.module_map != None:
            lines.append("    module_map = {map},".format(map = repr(lib.module_map)))
        lines.append(")")
    return "\n".join(lines)

def _swiftpm_render_private_headers_library(lib):
    """Render the target-local helper carrying `headerSearchPath` paths.

    The helper holds the target's private headers and the search paths
    from `cSettings`/`cxxSettings`. Its only dependent is the target
    itself, through `implementation_deps`, so neither the headers nor the
    paths reach another library or the app.

    Args:
        lib: The library struct described in `swiftpm_render_clang_library`.

    Returns:
        The helper rule's text lines.
    """
    lines = ["{rule}(".format(rule = lib.rule)]
    lines.append("    name = \"{name}_private_headers\",".format(name = lib.library_name))
    lines.append("    hdrs = [")
    for header in lib.private_headers:
        lines.append("        {item},".format(item = repr(header)))
    lines.append("    ],")
    lists = swiftpm_render_list_attr("includes", [], lib.private_includes)
    if lists:
        lines.append(lists)
    lines.append("    tags = [{tags}],".format(tags = ", ".join([repr(tag) for tag in lib.tags])))
    lines.append(")")
    return lines
