"""Rule that compiles a standalone Dart tool to a `.dill` kernel using the Flutter SDK toolchain.

Used for build tools (such as `web_template`) whose compiled `.dill` is executed
by `flutter_sdk_info.dart` (from `@rules_flutter//flutter:toolchain_type`) so the
compiled kernel's SDK hash always matches the Flutter-bundled Dart VM that loads
it, regardless of whether `@rules_dart`'s standalone SDK toolchain was registered
ahead of `@flutter_toolchains`.
"""

load(
    "@rules_dart//dart:utils.bzl",
    "STABLE_SCHEME",
    "dart_analyzable_info",
    "stable_entry_path",
)

visibility(["//flutter/..."])

def _sdk_root_from_dart(dart_file):
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

def _find_flutter_sdk_gen_kernel_tools(flutter_sdk_info):
    sdk_root = _sdk_root_from_dart(flutter_sdk_info.dart)
    wanted = {
        "gen_kernel_snapshot": sdk_root + "/bin/snapshots/gen_kernel_aot.dart.snapshot",
        "platform_dill": sdk_root + "/lib/_internal/vm_platform_strong.dill",
    }
    found = {}
    compile_inputs = []
    for f in flutter_sdk_info.tool_files.to_list():
        if f.path.startswith(sdk_root + "/"):
            compile_inputs.append(f)
        for key, path in wanted.items():
            if f.path == path:
                found[key] = f
    if len(found) != len(wanted):
        fail(
            "Flutter toolchain is missing Dart SDK kernel compilation files under %s (expected %s, found %s)" %
            (sdk_root, sorted(wanted.values()), sorted([f.path for f in found.values()])),
        )
    return struct(
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        gen_kernel_snapshot = found["gen_kernel_snapshot"],
        platform_dill = found["platform_dill"],
        compile_inputs = compile_inputs,
    )

def _writable_home_env(dart, beside):
    # Beside the action's own output, never the shared /tmp: every user and
    # action on the host shares /tmp, so a compiler home there is shared
    # mutable state. The output's directory is the action's own, as the
    # Windows branch already did.
    if dart.basename.endswith(".exe"):
        return {"USERPROFILE": beside.dirname, "LOCALAPPDATA": beside.dirname}
    return {"HOME": beside.dirname}

def _flutter_sdk_kernel_binary_impl(ctx):
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    tools = _find_flutter_sdk_gen_kernel_tools(flutter_sdk_info)

    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = '{"configVersion": 2, "packages": []}\n',
    )

    # `main` staged alone under a per-target root, which is the only
    # `--filesystem-root` the compile mounts: gen_kernel resolves the entry's
    # stable URI against its filesystem roots, so mounting the exec root (as
    # rules_dart's `gen_kernel_args` does) lets an import of a file nobody
    # declared resolve under a non-sandboxed strategy. With only the staging
    # root mounted, such an import fails under every strategy, sandboxed or
    # not. The entry keeps its stable URI, so the dill stays free of absolute
    # paths and byte-identical across strategies.
    entry = stable_entry_path(ctx, ctx.file.main.path)
    staged = ctx.actions.declare_file(ctx.label.name + ".stage/" + entry)
    ctx.actions.symlink(output = staged, target_file = ctx.file.main)
    root = staged.path[:len(staged.path) - len(entry) - 1]

    args = ctx.actions.args()
    args.add(tools.gen_kernel_snapshot)
    args.add("--platform", tools.platform_dill)
    args.add("--packages", package_config)
    args.add("--filesystem-scheme", STABLE_SCHEME)
    args.add("--filesystem-root", root)
    args.add("-Ddart.vm.product=false")
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    args.add("-o", output)
    args.add(STABLE_SCHEME + ":///" + entry)

    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = [
                staged,
                package_config,
                tools.dartaotruntime,
                tools.gen_kernel_snapshot,
                tools.platform_dill,
            ] + tools.compile_inputs,
        ),
        outputs = [output],
        mnemonic = "FlutterToolKernel",
        progress_message = "Compiling Flutter tool kernel %s" % ctx.label,
        env = _writable_home_env(flutter_sdk_info.dart, output),
        toolchain = None,
    )

    return [
        DefaultInfo(
            files = depset([output]),
            executable = output,
        ),
        dart_analyzable_info(
            deps = [],
            srcs = [ctx.file.main],
        ),
    ]

flutter_sdk_kernel_binary = rule(
    implementation = _flutter_sdk_kernel_binary_impl,
    attrs = {
        "main": attr.label(
            doc = "The standalone Dart entrypoint file.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "Compiles a standalone Dart tool to a `.dill` kernel using `@rules_flutter//flutter:toolchain_type`.",
)
