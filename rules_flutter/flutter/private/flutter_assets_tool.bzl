"""Builds the asset tool of one Flutter release from its pinned source closure.

The asset tool (`//flutter/private/assets_tool:flutter_assets_tool.dart`) runs
the Flutter tool's own asset, licence, web bootstrap and gen-l10n code. It is
compiled against `packages/flutter_tools` of the release's tag
(`flutter_assets_tool_sources`, declared by the repository
`flutter_assets_tool_repo.bzl` stages), with the `gen_kernel` and
`gen_snapshot` of the Dart SDK bundled in that release, and run by its
`dartaotruntime`. The release's engine repository declares it beside its
`flutter_toolchain`, which carries it in exec configuration
(`FlutterSdkInfo.assets_tool`), as rules_dart builds its module compiler.
"""

visibility(["//flutter/..."])

FlutterAssetsToolSourcesInfo = provider(
    doc = "The pinned source closure the asset tool of one Flutter release is built from.",
    fields = {
        "files": "depset[File]: every Dart source of the closure.",
        "packages": "list[struct]: one `struct(name, root, language_version)` per package; `root` is its exec-root-relative directory, whose `lib/` holds the sources.",
        "framework_shaders": "list[File]: `packages/flutter/lib/src/*/shaders/*.frag`, which the tool bundles into every app.",
        "service_worker": "File: `flutter_service_worker.js`, the template the tool's web code reads under `FLUTTER_ROOT`.",
        "unsupported_version": "str: the Flutter version, when it has no pinned sources (the other fields are then empty); else empty.",
    },
)

FlutterAssetsToolInfo = provider(
    doc = "The asset tool of one Flutter release and the source files it reads at run time.",
    fields = {
        "snapshot": "File: the AOT snapshot, run by `runtime`.",
        "runtime": "File: the `dartaotruntime` of the Dart SDK bundled in the release, for the execution platform.",
        "framework_shaders": "list[File]: the framework's shaders, staged under the tool's Flutter root.",
        "service_worker": "File: the service worker template.",
        "unsupported_version": "str: the Flutter version, when it has no pinned sources and so no tool (the other fields are then None); else empty.",
    },
)

# The scheme the tool's own build names its sources by, so neither the kernel
# nor the snapshot carries the absolute path of the machine that built it.
_SCHEME = "org-dartlang-root"

def _sources_impl(ctx):
    if ctx.attr.unsupported_version:
        return [FlutterAssetsToolSourcesInfo(
            files = depset(),
            packages = [],
            framework_shaders = [],
            service_worker = None,
            unsupported_version = ctx.attr.unsupported_version,
        )]
    root = ctx.label.workspace_root
    packages = []
    for name in sorted(ctx.attr.packages):
        directory, _, language_version = ctx.attr.packages[name].partition("|")
        packages.append(struct(
            name = name,
            root = (root + "/" + directory) if root else directory,
            language_version = language_version,
        ))
    files = depset(ctx.files.srcs)
    return [
        DefaultInfo(files = files),
        FlutterAssetsToolSourcesInfo(
            files = files,
            packages = packages,
            framework_shaders = ctx.files.framework_shaders,
            service_worker = ctx.file.service_worker,
            unsupported_version = "",
        ),
    ]

flutter_assets_tool_sources = rule(
    implementation = _sources_impl,
    doc = "The source closure the asset tool of one Flutter release is built from. Declared by the repository that stages it.",
    attrs = {
        "srcs": attr.label_list(
            doc = "Every Dart source of the closure.",
            allow_files = [".dart"],
        ),
        "framework_shaders": attr.label_list(
            doc = "The framework's own shaders.",
            allow_files = [".frag"],
        ),
        "packages": attr.string_dict(
            doc = "Each package's name, to `<directory>|<language version>`.",
        ),
        "service_worker": attr.label(
            doc = "`flutter_tools`' service worker template.",
            allow_single_file = [".js"],
        ),
        "unsupported_version": attr.string(
            doc = "Set instead of the others for a Flutter version with no pinned sources: analysis fails naming it.",
        ),
    },
)

def _sdk_files(dart, compile_files):
    """The Dart SDK files that build the tool, by role, among `compile_files`."""
    sdk_root = dart.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if sdk_root.endswith(suffix):
            sdk_root = sdk_root[:-len(suffix)]
            break
    wanted = {
        sdk_root + "/bin/dartaotruntime": "dartaotruntime",
        sdk_root + "/bin/dartaotruntime.exe": "dartaotruntime",
        sdk_root + "/bin/snapshots/gen_kernel_aot.dart.snapshot": "gen_kernel",
        sdk_root + "/bin/utils/gen_snapshot": "gen_snapshot",
        sdk_root + "/bin/utils/gen_snapshot.exe": "gen_snapshot",
        sdk_root + "/lib/_internal/vm_platform_product.dill": "platform",
    }
    found = {}
    for f in compile_files:
        key = wanted.get(f.path)
        if key != None:
            found[key] = f
    return found

def _flutter_assets_tool_impl(ctx):
    sources = ctx.attr.sources[FlutterAssetsToolSourcesInfo]
    if sources.unsupported_version:
        # The toolchain carries the tool to every Flutter build; only one that
        # bundles assets fails, naming the version (`flutter_assets_tool_of`).
        return [FlutterAssetsToolInfo(
            snapshot = None,
            runtime = None,
            framework_shaders = [],
            service_worker = None,
            unsupported_version = sources.unsupported_version,
        )]
    sdk = _sdk_files(ctx.file.dart, ctx.files.compile_files)
    if len(sdk) != 4:
        fail("%s: the Dart SDK at %s lacks %s, which the asset tool is built with." % (
            ctx.label,
            ctx.file.dart.path,
            ", ".join([k for k in ("dartaotruntime", "gen_kernel", "gen_snapshot", "platform") if k not in sdk]),
        ))
    main = ctx.file._main
    packages = [
        {
            "name": p.name,
            "rootUri": "%s:///%s" % (_SCHEME, p.root),
            "packageUri": "lib/",
            "languageVersion": p.language_version,
        }
        for p in sources.packages
    ]
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(package_config, json.encode_indent({"configVersion": 2, "packages": packages}))

    kernel = ctx.actions.declare_file(ctx.label.name + ".dill")
    ctx.actions.run(
        executable = sdk["dartaotruntime"],
        arguments = [
            sdk["gen_kernel"].path,
            "--platform=" + sdk["platform"].path,
            "--aot",
            "--tfa",
            "--no-embed-sources",
            "-Ddart.vm.product=true",
            "--filesystem-root=.",
            "--filesystem-scheme=" + _SCHEME,
            "--packages=%s:///%s" % (_SCHEME, package_config.path),
            "-o",
            kernel.path,
            "%s:///%s" % (_SCHEME, main.path),
        ],
        inputs = depset(
            direct = [package_config, sdk["gen_kernel"], sdk["platform"], main],
            transitive = [sources.files],
        ),
        outputs = [kernel],
        mnemonic = "FlutterAssetsToolKernel",
        progress_message = "Compiling the Flutter %s asset tool" % ctx.attr.version,
        toolchain = None,
    )
    snapshot = ctx.actions.declare_file(ctx.label.name + ".aot")
    ctx.actions.run(
        executable = sdk["gen_snapshot"],
        arguments = [
            "--deterministic",
            "--snapshot_kind=app-aot-elf",
            "--elf=" + snapshot.path,
            kernel.path,
        ],
        inputs = [kernel],
        outputs = [snapshot],
        mnemonic = "FlutterAssetsToolSnapshot",
        progress_message = "Building the Flutter %s asset tool snapshot" % ctx.attr.version,
        toolchain = None,
    )
    return [
        DefaultInfo(files = depset([snapshot])),
        FlutterAssetsToolInfo(
            snapshot = snapshot,
            runtime = sdk["dartaotruntime"],
            framework_shaders = sources.framework_shaders,
            service_worker = sources.service_worker,
            unsupported_version = "",
        ),
    ]

flutter_assets_tool = rule(
    implementation = _flutter_assets_tool_impl,
    doc = "Builds the asset tool of one Flutter release: an AOT snapshot of `flutter_assets_tool.dart`, compiled against the release's own `flutter_tools` by the `gen_kernel` and `gen_snapshot` of the Dart SDK it bundles. The release's engine repository declares it beside its `flutter_toolchain`.",
    attrs = {
        "sources": attr.label(
            doc = "The pinned source closure of the release (a `flutter_assets_tool_sources` target).",
            mandatory = True,
            providers = [FlutterAssetsToolSourcesInfo],
        ),
        "dart": attr.label(
            doc = "The bundled Dart SDK's `dart` executable, which locates its other files.",
            mandatory = True,
            allow_single_file = True,
        ),
        "compile_files": attr.label(
            doc = "The bundled Dart SDK's compile files: `dartaotruntime`, the `gen_kernel` snapshot, `gen_snapshot` and the product platform kernel are taken from them.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The Flutter version, for messages.",
            mandatory = True,
        ),
        "_main": attr.label(
            doc = "The tool's own source.",
            default = Label("//flutter/private/assets_tool:flutter_assets_tool.dart"),
            allow_single_file = True,
        ),
    },
)

def flutter_assets_tool_of(flutter_sdk_info, label):
    """The asset tool of a Flutter toolchain, failing when it has none.

    Args:
      flutter_sdk_info: The resolved `FlutterSdkInfo`.
      label: The target that needs the tool, for the message.

    Returns:
      The `FlutterAssetsToolInfo`.
    """
    tool = getattr(flutter_sdk_info, "assets_tool", None)
    if tool == None:
        fail("%s: the Flutter %s toolchain names no asset tool, so no asset bundle can be built." % (label, flutter_sdk_info.version))
    if tool.unsupported_version:
        fail((
            "%s: Flutter %s has no pinned asset tool sources, so its asset bundle cannot be built. " +
            "Add the version to FLUTTER_ASSETS_TOOL_SOURCES in " +
            "@rules_flutter//flutter/private:flutter_assets_tool_versions.bzl."
        ) % (label, tool.unsupported_version))
    return tool
