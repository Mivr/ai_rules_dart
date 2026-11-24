"""Builds the module compiler of one Dart SDK from its pinned source closure.

The module compiler (`//dart/private/tools:module_compiler.dart`) compiles
kernel modules and outlines on the SDK's own front end. It is built per SDK,
from the sources of that SDK's tag (`module_compiler_sources`, declared by the
repository `module_compiler_repo.bzl` fetches), with that SDK's own
`gen_kernel` and `gen_snapshot`, and run by its `dartaotruntime`.

`dart_module_compiler` is the target that builds it. It takes the SDK's files
by label, not through a toolchain, because the toolchain is what carries its
output (`DartSdkInfo.module_compiler`). `dart_toolchain` takes it in the exec
configuration, so one SDK builds one module compiler whatever configuration
the modules it compiles are in.
"""

visibility(["//dart/..."])

ModuleCompilerSourcesInfo = provider(
    doc = "The pinned source closure the module compiler of one Dart SDK version is built from.",
    fields = {
        "files": "depset[File]: every source file of the closure.",
        "packages": "list[struct]: one `struct(name, root, language_version)` per package; `root` is the package's exec-root-relative directory, whose `lib/` holds the sources.",
        "revision": "str: the SDK's commit, whose first 10 characters are the SDK hash its kernels carry.",
    },
)

# The scheme the tool's own build names its sources by, so neither the kernel
# nor the snapshot carries the absolute path of the machine that built it.
_SCHEME = "org-dartlang-root"

def _module_compiler_sources_impl(ctx):
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
        ModuleCompilerSourcesInfo(files = files, packages = packages, revision = ctx.attr.revision),
    ]

module_compiler_sources = rule(
    implementation = _module_compiler_sources_impl,
    doc = "The source closure the module compiler of one Dart SDK version is built from. Declared by the repository that fetches it.",
    attrs = {
        "srcs": attr.label_list(
            doc = "Every source file of the closure.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "packages": attr.string_dict(
            doc = "Each package's name, to `<directory>|<language version>`: its directory in this repository and the language version its pubspec states.",
            mandatory = True,
        ),
        "revision": attr.string(
            doc = "The SDK's commit.",
            mandatory = True,
        ),
    },
)

def _sdk_files(dart, compile_files):
    """Finds the SDK files that build and run the module compiler.

    Args:
      dart: The SDK's `dart` File.
      compile_files: The SDK's compile files.

    Returns:
      A dict with `dartaotruntime`, `gen_kernel`, `gen_snapshot` and
      `platform`, holding only those the SDK has.
    """
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

def _dart_module_compiler_impl(ctx):
    sdk = _sdk_files(ctx.file.dart, ctx.files.compile_files)
    if len(sdk) != 4:
        fail("%s: the Dart SDK %s at %s lacks %s, which the module compiler is built with." % (
            ctx.label,
            ctx.attr.version,
            ctx.file.dart.path,
            ", ".join([k for k in ("dartaotruntime", "gen_kernel", "gen_snapshot", "platform") if k not in sdk]),
        ))
    sources = ctx.attr.sources[ModuleCompilerSourcesInfo]
    tool_srcs = ctx.files._srcs
    main = [f for f in tool_srcs if f.basename == "module_compiler.dart"][0]

    # The tool's own sources are a package too, so the entry is a `package:`
    # URI and the snapshot names no file path.
    packages = [
        {
            "name": p.name,
            "rootUri": "%s:///%s" % (_SCHEME, p.root),
            "packageUri": "lib/",
            "languageVersion": p.language_version,
        }
        for p in sources.packages
    ] + [{"name": "rules_dart_tools", "rootUri": "%s:///%s" % (_SCHEME, main.dirname)}]
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
            # As the SDK builds its own tools: the hash every kernel carries.
            "-Dsdk_hash=" + sources.revision[:10],
            "--filesystem-root=.",
            "--filesystem-scheme=" + _SCHEME,
            "--packages=%s:///%s" % (_SCHEME, package_config.path),
            "-o",
            kernel.path,
            "package:rules_dart_tools/module_compiler.dart",
        ],
        inputs = depset(
            direct = [package_config, sdk["gen_kernel"], sdk["platform"]] + tool_srcs,
            transitive = [sources.files],
        ),
        outputs = [kernel],
        mnemonic = "DartModuleCompilerKernel",
        progress_message = "Compiling the Dart %s module compiler" % ctx.attr.version,
        # The files are this SDK's own, not a toolchain's.
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
        mnemonic = "DartModuleCompilerSnapshot",
        progress_message = "Building the Dart %s module compiler snapshot" % ctx.attr.version,
        toolchain = None,
    )
    return [DefaultInfo(files = depset([snapshot]))]

dart_module_compiler = rule(
    implementation = _dart_module_compiler_impl,
    doc = "Builds the module compiler of one Dart SDK: an AOT snapshot of `module_compiler.dart`, compiled against the SDK tag's own front end by the SDK's own `gen_kernel` and `gen_snapshot`. `declare_dart_sdk_toolchains` declares it beside the SDK's `dart_toolchain`.",
    attrs = {
        "sources": attr.label(
            doc = "The pinned source closure of the SDK's version (a `module_compiler_sources` target).",
            mandatory = True,
            providers = [ModuleCompilerSourcesInfo],
        ),
        "dart": attr.label(
            doc = "The SDK's `dart` executable, which locates the SDK's other files.",
            mandatory = True,
            allow_single_file = True,
        ),
        "compile_files": attr.label(
            doc = "The SDK's compile files: `dartaotruntime`, the `gen_kernel` snapshot, `gen_snapshot` and the product platform kernel are taken from them.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The SDK version, for messages.",
            mandatory = True,
        ),
        "_srcs": attr.label(
            doc = "The module compiler's own sources.",
            default = Label("//dart/private/tools:module_compiler_srcs"),
            allow_files = True,
        ),
    },
)
