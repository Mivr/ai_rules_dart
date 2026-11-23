"""A staged project described by a manifest and laid out at execution.

The `dart_analyze` aspect's actions read a project tree: the target's files,
what they resolve against, the options files, a package config and pubspec
stubs (see `project_staging.bzl` for the layout and why it has that shape).
Staging that tree at analysis time cost one declared file and one symlink
action per file of the closure, for every analyzed target, and a Starlark pass
over the flattened closure for the generated files.

Here the aspect writes one manifest per project instead. It is an `Args`
written to a file, so Bazel expands the closure's depsets into it at execution
and nothing is flattened in Starlark. The action that reads the project takes
the same depsets as inputs, a declared directory to lay the project out in,
and `--layout <manifest> --project <dir>/<name>.proj`; the runner builds the
tree there from the manifest before it reads anything
(`//dart/private/tools:project_layout.dart`), and removes it afterwards.
"""

visibility(["//dart/..."])

def _pkg_record(pkg):
    return "pkg\t%s\t%s\t%s\t%s\t%s" % (
        pkg.package_name,
        pkg.lib_root,
        getattr(pkg, "language_version", "") or "",
        getattr(pkg, "workspace_root", "") or "",
        getattr(pkg, "version", "") or "",
    )

def _file_record(f):
    return "file\t%s\t%s\t%s\t%s" % (
        f.path,
        f.short_path,
        f.owner.workspace_root if f.owner != None else "",
        "1" if f.is_directory else "0",
    )

def _own_record(f):
    return "own\t%s\t%s" % (f.path, f.short_path)

def _options_record(f):
    return "options\t%s\t%s" % (f.path, f.short_path)

def project_layout(ctx, config, packages, files, own, name, sdk_version, all_packages_named):
    """Writes the manifest of a project holding every options file `config` lists.

    The counterpart of `stage_config_project(..., copy_external = False)`:
    the same tree, laid out by the runner at execution.

    Args:
      ctx: The aspect context.
      config: The `DartAnalysisConfigInfo` to stage.
      packages: List of depsets or lists of `DartPackageInfo`, in order; the
        config's own packages follow them. The first record of a name wins;
        two that state different versions fail the action.
      files: List of depsets or lists of Files to stage, in order; the
        config's files and options files follow them.
      own: List of the Files being checked.
      name: Prefix of the project's `<name>.proj` and `<name>.extpkgs`.
      sdk_version: The toolchain SDK's version, the staged SDK constraint of a
        package that states no `language_version`.
      all_packages_named: Name every external package in the config, not
        only those with files staged.

    Returns:
      `struct(name, manifest, inputs)`: `inputs` is a depset of the manifest
      and every file it stages.
    """
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add("name\t" + name)
    args.add("sdk\t" + sdk_version)
    args.add("named\t" + ("1" if all_packages_named else "0"))
    # The runner refuses two records of one package that disagree, as
    # `merge_package_records` did, and names where each came from.
    args.add("origin\tthe dependencies of %s" % ctx.label)
    for pkgs in packages:
        args.add_all(pkgs, map_each = _pkg_record)
    args.add("origin\tthe analysis config %s" % ctx.attr._config.label)
    args.add_all(config.packages, map_each = _pkg_record)
    staged = files + [config.files, config.options_files]
    for group in staged:
        args.add_all(group, map_each = _file_record, expand_directories = False)
    args.add_all(own, map_each = _own_record, expand_directories = False)
    args.add_all(config.options_files, map_each = _options_record, expand_directories = False)

    manifest = ctx.actions.declare_file(name + ".layout")
    ctx.actions.write(output = manifest, content = args)

    direct = [manifest]
    transitive = []
    for group in staged:
        if type(group) == "depset":
            transitive.append(group)
        else:
            direct.extend(group)
    return struct(
        name = name,
        manifest = manifest,
        inputs = depset(direct = direct, transitive = transitive),
    )

def layout_directory(ctx, layout, action_name):
    """Declares the directory one action lays `layout` out in.

    Each action that reads a project lays out its own copy: two actions cannot
    share an output.

    Args:
      ctx: The aspect context.
      layout: A `project_layout` struct.
      action_name: Distinguishes this action's directory from the others'.

    Returns:
      `struct(dir, proj_path, inputs, manifest)`: the declared directory, the
      project path to pass as `--project`, and the layout's inputs and manifest.
    """
    d = ctx.actions.declare_directory("%s.%s.stage" % (layout.name, action_name))
    return struct(
        dir = d,
        proj_path = "%s/%s.proj" % (d.path, layout.name),
        inputs = layout.inputs,
        manifest = layout.manifest,
    )

def add_layout_args(args, staged):
    """Adds `--layout` and `--project` for a `layout_directory` to `args`."""
    args.add("--layout", staged.manifest)
    args.add("--project", staged.proj_path)
