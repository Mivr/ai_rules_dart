"""The `<name>.coverage_map.json` of a `dart_test`, and the origins it needs for `srcs_dir`.

The launcher turns the VM's coverage into LCOV with the map: a JSON object of the
source URIs the VM reports to the **exec path** of the file (`File.path`), which
is the form `COVERAGE_MANIFEST` and the report's `SF:` records use.

A directory source (a `dart_library(srcs_dir = ...)` over a `dart_source_set`)
holds files only the execution knows, so its entries come from an action. The
`dart_source_set` that assembled the directory records, for every staged file,
the exec path of the input it was copied from (`CoverageOriginInfo`), and the map
names that input, the file `COVERAGE_MANIFEST` lists.

This module loads nothing from the rest of `dart/private`: `source_set.bzl`
returns `CoverageOriginInfo`, so it must be loadable from there.
"""

_COPY_TOOLCHAIN_TYPE = Label("//dart:copy_toolchain_type")

# The toolchain that supplies `copy_tree`, which also completes a map for
# directory sources.
COVERAGE_MAP_TOOLCHAINS = [_COPY_TOOLCHAIN_TYPE]

CoverageOriginInfo = provider(
    doc = """Where the files of an assembled directory came from, for `bazel coverage`.

Private to rules_dart: `dart_source_set` returns it, `dart_library` forwards it across
`srcs_dir`, `deps` and `members`, and `dart_test` reads it. Not part of any public provider.""",
    fields = {
        "maps": "depset of JSON files, each an object of a staged file's path to the exec path of its input.",
    },
)

def forward_origins(targets, direct = []):
    """The `CoverageOriginInfo` a rule returns: `direct` maps plus those of `targets`.

    Args:
      targets: Targets whose origin maps are forwarded; those without any are skipped.
      direct: Origin map Files this rule writes itself.

    Returns:
      A `CoverageOriginInfo`.
    """
    return CoverageOriginInfo(maps = depset(
        direct = direct,
        transitive = [t[CoverageOriginInfo].maps for t in targets if CoverageOriginInfo in t],
    ))

def _dart_member_record(f):
    """The `--file` record for one file of an expanded directory; none for a non-Dart file."""
    if f.extension != "dart":
        return []
    return ["--file", f.path, f.short_path]

def _package_rooted_at(ctx, directory, packages):
    """The package whose `lib_root` is `directory`, or a failure naming the target."""
    for pkg in packages:
        if pkg.lib_root == directory.short_path:
            return pkg.package_name
    fail((
        "%s: the directory source `%s` is the root of no Dart package, so its " +
        "files cannot be mapped for `bazel coverage`. Pass it as a " +
        "`dart_library(srcs_dir = ...)`."
    ) % (ctx.label, directory.short_path))

def _expand_directories(ctx, out, static, directories, packages):
    """Runs the action that adds the files of `directories` to the static map."""
    maps = forward_origins(ctx.attr.deps).maps
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--coverage-map")
    args.add(out.path)
    args.add("--static")
    args.add(static.path)
    args.add_all(maps, before_each = "--origin-map")
    for d in directories:
        args.add("--dir")
        args.add(d.path)
        args.add(d.short_path)
        args.add(_package_rooted_at(ctx, d, packages))
    args.add_all(directories, map_each = _dart_member_record, expand_directories = True)
    copy_tc = ctx.toolchains[_COPY_TOOLCHAIN_TYPE]
    ctx.actions.run(
        executable = copy_tc.dart,
        arguments = [copy_tc.copy_tree.path, args],
        inputs = depset(
            direct = [copy_tc.copy_tree, static] + directories,
            transitive = [copy_tc.runtime_files, maps],
        ),
        outputs = [out],
        mnemonic = "DartCoverageMap",
        progress_message = "Mapping coverage sources of %{label}",
        toolchain = _COPY_TOOLCHAIN_TYPE,
    )

def write_coverage_map(ctx, entries, directories, packages):
    """Writes `<name>.coverage_map.json`.

    Without a directory source, the map is `entries`, written at analysis time.
    With one, an action completes `entries` with each directory's Dart files.

    Args:
      ctx: The `dart_test` rule context (with the copy toolchain when `directories` is set).
      entries: Dict of the URI the VM reports to the exec path of the file, for the
        sources known at analysis time.
      directories: Directory Files (tree artifacts) among the test's sources.
      packages: The `DartPackageInfo` records the compile resolves against.

    Returns:
      The `<name>.coverage_map.json` File.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".coverage_map.json")
    if not directories:
        ctx.actions.write(output = out, content = json.encode(entries))
        return out
    static = ctx.actions.declare_file(ctx.label.name + ".coverage_map.static.json")
    ctx.actions.write(output = static, content = json.encode(entries))
    _expand_directories(ctx, out, static, directories, packages)
    return out
