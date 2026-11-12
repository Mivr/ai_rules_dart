"""The package list a `dart_test` launcher builds its runtime package config from."""

visibility(["//dart/..."])

def _root_line(package):
    """One `<name>\\t<lib_root>` line, or `None` for a record with no single package.

    Args:
      package: A `DartPackageInfo` record.

    Returns:
      The line, or `None`.
    """
    if not package.package_name:
        return None
    return "%s\t%s" % (package.package_name, package.lib_root)

def write_package_roots(ctx, packages):
    """Writes the packages a test's launcher maps to their runfiles `lib/` directory.

    The launcher keeps a package only when files were staged under its `lib/`
    in runfiles, so this lists every package the test reaches and leaves that
    decision to run time, where it can see what was staged.

    Args:
      ctx: The `dart_test` rule context.
      packages: The `DartPackageInfo` records the test's compile resolves against.

    Returns:
      The `<name>.package_roots` File, one `<name>\\t<lib_root>` line per package.
    """
    roots = ctx.actions.declare_file(ctx.label.name + ".package_roots")
    lines = ctx.actions.args()
    lines.set_param_file_format("multiline")
    lines.add_all(packages, map_each = _root_line)
    ctx.actions.write(output = roots, content = lines)
    return roots
