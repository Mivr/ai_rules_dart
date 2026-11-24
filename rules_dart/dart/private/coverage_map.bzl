"""The `<name>.coverage_map.json` of a `dart_test`, and the origins it needs for `srcs_dir`.

The launcher turns the VM's coverage into LCOV with the map: a JSON object of the
source URIs the VM reports to the **exec path** of the file (`File.path`), which
is what `COVERAGE_MANIFEST` lists and the report's `SF:` records name.

The map is written by an action, only under `bazel coverage`. A directory source
(a `dart_library(srcs_dir = ...)` over a `dart_source_set`) holds files only the
execution knows, so its entries come from that action too. The
`dart_source_set` that assembled the directory records, for every staged file,
the exec path of the input it was copied from (`CoverageOriginInfo`), and the map
names that input, the file `COVERAGE_MANIFEST` lists.

This module loads only `dart_info.bzl` from the rest of `dart/private`:
`source_set.bzl` returns `CoverageOriginInfo`, so it must be loadable from there.
"""

load("//dart/private:dart_info.bzl", "package_lib_prefix")

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
        "generated": "depset of the generated Dart files that rules the instrumentation filter selects own.",
    },
)

def forward_origins(targets, direct = [], generated = []):
    """The `CoverageOriginInfo` a rule returns: its own maps and generated files plus those of `targets`.

    Args:
      targets: Targets whose origin maps and generated files are forwarded; those without any are skipped.
      direct: Origin map Files this rule writes itself.
      generated: The rule's own source Files; see `instrumented_generated`.

    Returns:
      A `CoverageOriginInfo`.
    """
    return CoverageOriginInfo(
        maps = depset(
            direct = direct,
            transitive = [t[CoverageOriginInfo].maps for t in targets if CoverageOriginInfo in t],
        ),
        generated = depset(
            direct = instrumented_generated(generated),
            transitive = [t[CoverageOriginInfo].generated for t in targets if CoverageOriginInfo in t],
        ),
    )

def instrumented_generated(files):
    """The generated Dart files among `files`.

    Bazel's `COVERAGE_MANIFEST` lists source files only, so the launcher is told
    these by name. A rule calls this for its own sources when the instrumentation
    filter selects it (`ctx.coverage_instrumented()`), and passes nothing otherwise.

    Args:
      files: Files a rule owns.

    Returns:
      The generated, non-directory `.dart` Files among them.
    """
    return [f for f in files if f.extension == "dart" and not f.is_source and not f.is_directory]

def write_generated_list(ctx, own_files, targets):
    """Writes `<name>.coverage_generated`: the exec paths of generated Dart files to instrument.

    Args:
      ctx: The `dart_test` rule context.
      own_files: The test's own source Files, listed only when the filter selects the test.
      targets: The `deps` whose generated files are listed.

    Returns:
      The File, one exec path per line.
    """
    generated = forward_origins(targets, [], own_files if ctx.coverage_instrumented() else []).generated
    out = ctx.actions.declare_file(ctx.label.name + ".coverage_generated")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add_all(generated, map_each = _exec_path_line)
    ctx.actions.write(output = out, content = args)
    return out

def _exec_path_line(f):
    """The exec path of `f` with `/` separators."""
    return f.path.replace("\\", "/")

def _file_record(f):
    """The `--file` record for one Dart file (a directory source is expanded to its files); none otherwise."""
    if f.extension != "dart":
        return []
    return ["--file", f.path, f.short_path]

def _dir_record(f):
    """The `--dir` record for a directory source; none for any other file."""
    if not f.is_directory:
        return []
    return ["--dir", f.path, f.short_path]

def _package_record(pkg):
    """The `--package` record for one `DartPackageInfo`."""
    return ["--package", pkg.package_name, package_lib_prefix(pkg.lib_root), pkg.lib_root]

def write_coverage_map(ctx, dep_srcs, own_files, packages):
    """Writes `<name>.coverage_map.json` with an action.

    The sources reach the action as lazily expanded records of a params file, so
    analysis never flattens the closure. The action maps each Dart file to its
    `org-dartlang-root:` and `package:` URIs, and a directory source to its files.

    Args:
      ctx: The `dart_test` rule context, with the copy toolchain.
      dep_srcs: Depset of the Files of the test's dependencies' transitive sources.
      own_files: The test's own source Files.
      packages: The `DartPackageInfo` records the compile resolves against.

    Returns:
      The `<name>.coverage_map.json` File.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".coverage_map.json")
    maps = forward_origins(ctx.attr.deps).maps
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--coverage-map")
    args.add(out.path)
    args.add_all(packages, map_each = _package_record)
    args.add_all(maps, before_each = "--origin-map")
    for srcs in [dep_srcs, own_files]:
        args.add_all(srcs, map_each = _dir_record, expand_directories = False)
        args.add_all(srcs, map_each = _file_record, expand_directories = True)
    copy_tc = ctx.toolchains[_COPY_TOOLCHAIN_TYPE]
    ctx.actions.run(
        executable = copy_tc.dart,
        arguments = [copy_tc.copy_tree.path, args],
        inputs = depset(
            direct = [copy_tc.copy_tree] + own_files,
            transitive = [copy_tc.runtime_files, maps, dep_srcs],
        ),
        outputs = [out],
        mnemonic = "DartCoverageMap",
        progress_message = "Mapping coverage sources of %{label}",
        toolchain = _COPY_TOOLCHAIN_TYPE,
    )
    return out
