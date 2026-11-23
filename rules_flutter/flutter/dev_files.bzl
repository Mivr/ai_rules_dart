"""The aspect that requests the files the dev loop reads.

The dev tool reads build outputs off disk to drive a running app. Bazel
materializes an output when it belongs to a target named on the command line,
and a launchable target names only its bundle.

This cannot be an output group on that target: on Apple platforms it is
`rules_apple`'s `macos_application` / `ios_application`. Nor a sibling target:
those rules apply a split transition to their `deps`, so the
`flutter_application` the app was assembled from sits in a configuration
(`…-ST-<hash>`) nothing can name and no sibling re-derives. An aspect rides the
existing dep edges in the configuration they already have.

The group is the `flutter_application`'s own `DefaultInfo` rather than a
hand-listed subset, so the two cannot drift.

Two more groups serve `flutter_dev` (`tools/flutter_dev`), which hands the app
to the stock `flutter` tool and needs only what that tool and the IDE read:

- `flutter_stock_dev`: per application, its package config and a JSON file
  naming that config, the package and the Flutter version of the toolchain.
  Nothing else of the application, so a web session builds no kernel.
- `flutter_stock_dev_generated`: every generated Dart source of the main
  repository that a target lists in `srcs` (gen-l10n output, builder output),
  with a JSON file per such target mapping each source to the target that
  generates it, and a JSON file per `flutter_gen_l10n` target. The tool links
  each source into the source tree, where the stock generator would write it,
  and builds the generating targets in the top-level configuration, so that
  rebuilding one of them after an input edit updates what the link names.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")

visibility("public")

# The output group the dev tool requests. Named for what it is rather than for
# who wants it: a release build has no use for these, but they are not "debug"
# either — the release pipeline simply never asks.
DEV_FILES_GROUP = "flutter_dev_files"

# The groups `flutter_dev` requests (see the module docstring).
STOCK_DEV_GROUP = "flutter_stock_dev"
STOCK_DEV_GENERATED_GROUP = "flutter_stock_dev_generated"

_FLUTTER_TOOLCHAIN = "@rules_flutter//flutter:toolchain_type"

def _generated_dart_srcs(ctx):
    """The generated Dart files of the main repository this target lists in `srcs`."""
    srcs = getattr(ctx.rule.files, "srcs", None) or []
    return [
        f
        for f in srcs
        if not f.is_source and f.extension == "dart" and not f.short_path.startswith("../")
    ]

def _stock_dev_info(target, ctx):
    """Writes the JSON `flutter_dev` reads for one application."""
    toolchain = ctx.toolchains[_FLUTTER_TOOLCHAIN]
    sdk = getattr(toolchain, "flutter_sdk_info", None) if toolchain else None
    app = target[FlutterApplicationInfo]
    info = ctx.actions.declare_file(ctx.label.name + ".flutter_stock_dev.json")
    ctx.actions.write(info, json.encode({
        "debug": app.is_debug,
        "flutterVersion": sdk.version if sdk else None,
        "label": str(ctx.label),
        "package": getattr(ctx.rule.attr, "package_name", None),
        "packageConfig": app.package_config.path,
    }))
    return [info, app.package_config]

def _flutter_dev_files_aspect_impl(target, ctx):
    files = []
    stock = []
    generated = []

    # The application itself. Its DefaultInfo is the whole interface.
    if FlutterApplicationInfo in target:
        files.append(target[DefaultInfo].files)
        stock.append(depset(_stock_dev_info(target, ctx)))

    # Each generated source with the target that generates it, so the tool can rebuild that
    # target alone. A source two targets list is written twice, with the same content.
    own_generated = _generated_dart_srcs(ctx)
    if own_generated:
        generators = ctx.actions.declare_file(ctx.label.name + ".flutter_stock_dev_generated.json")
        ctx.actions.write(generators, json.encode({"sources": {f.short_path: str(f.owner) for f in own_generated}}))
        generated.append(depset(own_generated + [generators]))

    # The stock tool runs its own gen-l10n when the project has an `l10n.yaml`, into the same
    # paths: the tool must not link this target's outputs there then.
    if ctx.rule.kind == "flutter_gen_l10n":
        stock_generator = ctx.actions.declare_file(ctx.label.name + ".flutter_stock_dev_generated.json")
        ctx.actions.write(stock_generator, json.encode({"stockGenerator": "gen-l10n", "label": str(ctx.label)}))
        generated.append(depset([stock_generator]))

    # Anything below it. `attr_aspects = ["*"]` rather than a named edge list:
    # the path from a launchable target down to its `flutter_application` runs
    # through rules this project does not own (`macos_application` → its
    # `deps` → a generated runner), so naming the edges would encode another
    # project's attribute names and break silently when they change.
    for attr_name in dir(ctx.rule.attr):
        attr = getattr(ctx.rule.attr, attr_name)
        deps = attr if type(attr) == "list" else [attr]
        for dep in deps:
            if type(dep) == "Target" and OutputGroupInfo in dep:
                groups = dep[OutputGroupInfo]
                for name, into in [(DEV_FILES_GROUP, files), (STOCK_DEV_GROUP, stock), (STOCK_DEV_GENERATED_GROUP, generated)]:
                    group = getattr(groups, name, None)
                    if group != None:
                        into.append(group)

    return [OutputGroupInfo(**{
        DEV_FILES_GROUP: depset(transitive = files),
        STOCK_DEV_GROUP: depset(transitive = stock),
        STOCK_DEV_GENERATED_GROUP: depset(transitive = generated),
    })]

flutter_dev_files = aspect(
    implementation = _flutter_dev_files_aspect_impl,
    attr_aspects = ["*"],
    toolchains = [config_common.toolchain_type(_FLUTTER_TOOLCHAIN, mandatory = False)],
    doc = """Collects the `flutter_application` outputs the dev tool reads.

Applied by the dev tool, not by users:

    bazel build //:app \\
      --aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files \\
      --output_groups=+flutter_dev_files

Requesting the group is what makes those files top-level, so bazel writes them
to this machine even when a cache served the actions that produced them.
""",
)
