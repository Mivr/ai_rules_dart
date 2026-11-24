"""The `dart_link_hook` rule.

Runs the `hook/link.dart` of every package in a `dart_library` closure over an
executable's recorded uses, and collects the data assets the hooks emit. This
is the Bazel counterpart of the link step `dart build` runs: there, each
package's link hook sees which of its `@RecordUse` definitions survived
tree-shaking and decides what to ship.

One action per package with a link hook (`DartLinkHook`), through the SDK's
own hook runner (`package:hooks_runner`, see `build_hooks.bzl`): the hook's
kernel is compiled once by the library that owns the package, and the action
reads only the package's own files, the recorded uses, and the outputs of
the closure's build hooks (the assets they route to it). It runs offline
unless the package opted into the network.

Bazel declares every output before anything runs, so the data assets a hook
will emit are named up front in `data_assets`, by asset id. A hook emitting
an asset that is not declared, or not emitting one that is, fails the action
and lists both sets.
"""

load("//dart:providers.bzl", "DartDataAssetInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:build_hooks.bzl", "HOOK_TARGET_ATTRS", "run_link_hook", "runner_launch")
load("//dart/private:common.bzl", "collect_packages", "package_link_hook", "package_native_assets")

visibility(["//dart/..."])

def parse_data_asset_ids(label, ids):
    """Splits declared data asset ids into package and name.

    Args:
      label: The rule's label, for messages.
      ids: The `data_assets` strings, each `package:<package>/<name>`.

    Returns:
      `(assets, error)`: a list of `struct(package, name, id)` in declaration
      order, and None; or None and an error string.
    """
    assets = []
    seen = {}
    for asset_id in ids:
        rest = asset_id[len("package:"):] if asset_id.startswith("package:") else ""
        package, _, name = rest.partition("/")
        segments = name.split("/")
        if not package or not name or "" in segments or "." in segments or ".." in segments:
            return None, ("%s: data asset id `%s` is not of the form " +
                          "`package:<package>/<name>`, with `<name>` a relative " +
                          "path.") % (label, asset_id)
        if asset_id in seen:
            return None, "%s: data asset id `%s` is declared twice." % (label, asset_id)
        seen[asset_id] = True
        assets.append(struct(package = package, name = name, id = asset_id))
    return assets, None

def recorded_uses_file_error(label, files):
    """Checks a `recorded_uses` target without `DartRecordedUsesInfo`.

    Args:
      label: The rule's label, for messages.
      files: The target's `DefaultInfo` files.

    Returns:
      An error string, or None when it is a single `.json` file.
    """
    if len(files) == 1 and files[0].extension == "json":
        return None
    return ("%s: `recorded_uses` must provide `DartRecordedUsesInfo` (a " +
            "`dart_binary` with `record_use = True`) or be a single `.json` " +
            "file; got %s.") % (label, [f.short_path for f in files])

def _recorded_uses(ctx):
    target = ctx.attr.recorded_uses
    if DartRecordedUsesInfo in target:
        return target[DartRecordedUsesInfo].file
    files = target[DefaultInfo].files.to_list()
    err = recorded_uses_file_error(ctx.label, files)
    if err != None:
        fail(err)
    return files[0]

def link_hook_runner_attr():
    """The private attribute a rule calling `dart_link_hook_actions` declares.

    Returns:
      A dict to merge into the rule's `attrs`; pass `ctx.executable.
      _link_hook_runner` as `runner`.
    """
    return {
        "_link_hook_runner": attr.label(
            doc = "The hook runner (`//dart/private/tools/hook_runner`), which runs each link hook through `package:hooks_runner`.",
            default = Label("//dart/private/tools/hook_runner"),
            executable = True,
            cfg = "exec",
        ),
    }

def dart_link_hook_actions(ctx, runner, sdk, recorded_uses, deps, data_asset_ids, name):
    """Registers the link-hook actions for a closure; what `dart_link_hook` runs.

    For a rule that compiles its own kernel and so cannot depend on a
    `dart_link_hook` target without a cycle. The caller's rule needs the
    `//dart:exec_tools_toolchain_type` toolchain and `link_hook_runner_attr()`
    in its `attrs`.

    Args:
      ctx: The rule context.
      runner: The hook runner (`ctx.executable._link_hook_runner`).
      sdk: The exec toolchain's `dart_sdk_info`.
      recorded_uses: The recorded-uses JSON File.
      deps: Targets providing `DartInfo`; their closure is linked.
      data_asset_ids: The declared ids, each `package:<package>/<name>`.
      name: Prefix for declared outputs, unique within the package.

    Returns:
      A struct: `assets` (a list of `struct(package, name, file, id)`, the
      content of `DartDataAssetInfo`), and `validation_outputs` (Files to
      put in an `_validation` output group, so every hook runs whenever the
      target builds even if it emits no asset).
    """
    declared, err = parse_data_asset_ids(ctx.label, data_asset_ids)
    if err != None:
        fail(err)

    # The rule is terminal: it reads the closure's records once.
    packages = collect_packages(deps)
    hooked = {}
    for pkg in packages:
        if package_link_hook(pkg) != None and getattr(pkg, "hooks", None) != None and pkg.package_name not in hooked:
            hooked[pkg.package_name] = pkg
    for asset in declared:
        if asset.package not in hooked:
            fail(("%s: data asset `%s` is declared for package `%s`, which has " +
                  "no link hook in `deps`. Packages with one: %s.") %
                 (ctx.label, asset.id, asset.package, sorted(hooked.keys()) or "none"))
    if not hooked:
        return struct(assets = [], validation_outputs = [])

    launch = runner_launch(ctx, sdk, runner)
    records = depset(transitive = [dep[DartInfo].transitive_packages for dep in deps])
    dart_closure = depset(transitive = [dep[DartInfo].transitive_srcs for dep in deps])
    build_outputs = depset([
        f
        for pkg in packages
        for f in package_native_assets(pkg)
        if f.is_directory
    ])
    asset_infos = []
    outputs = []
    for package_name in sorted(hooked.keys()):
        files = []
        for asset in declared:
            if asset.package != package_name:
                continue
            f = ctx.actions.declare_file("%s/%s/%s" % (name, package_name, asset.name))
            files.append(struct(name = asset.name, file = f))
            asset_infos.append(struct(package = asset.package, name = asset.name, file = f, id = asset.id))
        outputs.append(run_link_hook(
            ctx,
            launch,
            sdk,
            hooked[package_name],
            records,
            dart_closure,
            build_outputs,
            recorded_uses,
            files,
            name,
        ))
    return struct(assets = asset_infos, validation_outputs = outputs)

def _dart_link_hook_impl(ctx):
    result = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        sdk = ctx.toolchains["//dart:exec_tools_toolchain_type"].dart_sdk_info,
        recorded_uses = _recorded_uses(ctx),
        deps = ctx.attr.deps,
        data_asset_ids = ctx.attr.data_assets,
        name = ctx.label.name,
    )
    return [
        DefaultInfo(files = depset([a.file for a in result.assets])),
        DartDataAssetInfo(assets = depset(result.assets)),
        # A hook whose package declares no data assets has only its link
        # output, which nothing else asks for. As a validation output it still
        # runs whenever this target is built, so a hook that refuses the
        # program's uses fails the build either way.
        OutputGroupInfo(_validation = depset(result.validation_outputs)),
    ]

dart_link_hook = rule(
    implementation = _dart_link_hook_impl,
    attrs = {
        "recorded_uses": attr.label(
            doc = """The uses the hooks see as `LinkInput.recordedUses`: a `dart_binary` with \
`record_use = True` (anything providing `DartRecordedUsesInfo`), or a single `.json` file in the \
format the Dart compiler writes.""",
            mandatory = True,
            # Not `[".json"]`: that would reject a `dart_binary`, whose files
            # are its executable. `recorded_uses_file_error` checks the rest.
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = """`dart_library` targets whose closure is linked. Every package in it with a \
`link_hook` has its hook run; packages without one are skipped. Usually the same `deps` as the \
`dart_binary` named in `recorded_uses`.""",
            providers = [DartInfo],
        ),
        "data_assets": attr.string_list(
            doc = """The ids (`package:<package>/<name>`) of the data assets the hooks emit. \
Bazel needs every output named before the hooks run, so each one is declared here; the build \
fails if a hook emits an asset not listed, or does not emit one that is. Each lands at \
`<target>/<package>/<name>` and is provided through `DartDataAssetInfo`.""",
        ),
    } | link_hook_runner_attr() | HOOK_TARGET_ATTRS,
    provides = [DartDataAssetInfo],
    toolchains = ["//dart:exec_tools_toolchain_type"],
    doc = "Runs the `hook/link.dart` of each package in `deps` over an executable's recorded uses and collects the data assets they emit.",
)
