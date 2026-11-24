"""Build hooks: a package's own `hook/build.dart`, run through the SDK's hook runner.

A package that ships `hook/build.dart` builds its native code when an app is
built. `dart build` and `flutter build` run that hook through
`package:hooks_runner`; so do these rules, as two actions of the library that
owns the package:

  * `DartHookCompile` compiles the hook to kernel with the exec SDK, the step
    the runner would otherwise repeat in every cold run. It depends only on
    the hook's Dart closure, so neither the target nor the C toolchain
    reaches it.
  * `DartBuildHook` runs the hook through the runner (`hook_runner build`),
    offline, with no `HOME`, a `PATH` naming no tools, only the package's own
    files and its declared `hook_data`, and the C toolchain Bazel resolved for
    the target passed in the hook input. Its output is one directory: the
    runner's own result JSON (`assets.json`) and the files the hook produced.

An app's binary or test turns the directories of its closure into the
native-assets manifest the compiler embeds and the libraries it ships
(`hook_runner manifest`). A Dart edit in the app reaches none of these
actions; nor does a pubspec edit outside the package's own
`hooks.user_defines` slice.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

# rules_flutter loads this file. A package specification naming another
# repository (`@rules_flutter//flutter/...`) is refused by Bazel 9.0.0, the
# floor, so the file is public to the loader, as `dart/utils.bzl` is.
visibility("public")

def _hook_runner_default(hook_srcs):
    """Only a library whose build hook runs names the runner.

    The runner is a Dart program built from `dart_library` targets; naming it
    from every library would make each of those libraries depend on the
    runner, which depends on them. A library with a build hook lists the
    hook's files in `hook_srcs` (a label attribute that may be None cannot
    decide a computed default).
    """
    if hook_srcs:
        return Label("//dart/private/tools/hook_runner")
    return None

def _hook_cc_toolchain_default(hook_srcs):
    """Only a library whose build hook runs resolves a C toolchain."""
    if hook_srcs:
        return Label("//dart/private:hook_cc_toolchain")
    return None

def _hook_cc_toolchain_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    return [cc_toolchain] if cc_toolchain != None else []

# The target's C toolchain, or nothing when none is registered for it: a hook
# that compiles no C still runs there, and one that does fails in its own
# action, naming what it lacks.
hook_cc_toolchain = rule(
    implementation = _hook_cc_toolchain_impl,
    toolchains = use_cc_toolchain(mandatory = False),
    doc = "Forwards the target's `CcToolchainInfo` when one is resolved.",
)


BUILD_HOOK_FRAGMENTS = ["cpp"]

_BUILD_HOOK_OWN_ATTRS = {
    "build_hook": attr.label(
        doc = "The package's `hook/build.dart`. Set by `pub.from_lock()` for every pub package that ships one; set it on a hand-written library whose package has a build hook. The hook runs when an app or test that depends on this library is built for a target, through the Dart SDK's own hook runner, and its code assets reach that app as in `dart build`.",
        allow_single_file = [".dart"],
    ),
    "hook_srcs": attr.label_list(
        doc = "The package's files outside `lib/` that its hooks read: the hooks themselves and their sources, C sources, headers, prebuilt files. Required with `build_hook` (at least the hook). Inputs of the hook actions only, never of runfiles.",
        allow_files = True,
    ),
    "hook_data": attr.label_list(
        doc = "Files outside the package that the build hook reads, such as a source file a user define names. `pub.from_lock(hook_data = ...)` sets it for pub packages.",
        allow_files = True,
    ),
    "hook_user_defines": attr.string(
        doc = "The package's `hooks.user_defines.<package>` from the workspace `pubspec.yaml`, as a JSON object, or empty. `pub.from_lock()` sets it from the pubspec next to the lock, so only an edit of this slice reruns the hook.",
    ),
    "hook_pubspec": attr.string(
        doc = "Exec-root-relative path of the `pubspec.yaml` the user defines come from. The hook resolves relative paths in them against its directory, as in a stock build.",
    ),
    "hook_network": attr.bool(
        doc = "Let this package's build hook use the network. Off by default: a hook that downloads at build time fails with a message naming the package. `pub.from_lock(hook_network = [...])` sets it.",
        default = False,
    ),
    "_hook_runner": attr.label(
        default = _hook_runner_default,
        cfg = "exec",
        executable = True,
    ),
    "_hook_android_api": attr.label(
        default = Label("//dart:hook_android_api"),
    ),
    "_hook_cc_toolchain": attr.label(
        default = _hook_cc_toolchain_default,
    ),
}

# The target constraints a hook run reads (`hook_target`).
HOOK_TARGET_ATTRS = {
    "_hook_os_android": attr.label(default = "@platforms//os:android"),
    "_hook_os_ios": attr.label(default = "@platforms//os:ios"),
    "_hook_os_macos": attr.label(default = "@platforms//os:macos"),
    "_hook_os_linux": attr.label(default = "@platforms//os:linux"),
    "_hook_os_windows": attr.label(default = "@platforms//os:windows"),
    "_hook_cpu_arm64": attr.label(default = "@platforms//cpu:aarch64"),
    "_hook_cpu_x64": attr.label(default = "@platforms//cpu:x86_64"),
    "_hook_cpu_arm": attr.label(default = "@platforms//cpu:armv7"),
    "_hook_cpu_riscv64": attr.label(default = "@platforms//cpu:riscv64"),
    "_hook_cpu_x86_32": attr.label(default = "@platforms//cpu:x86_32"),
}

BUILD_HOOK_ATTRS = _BUILD_HOOK_OWN_ATTRS | HOOK_TARGET_ATTRS

def _consumer_hook_runner_default(code_assets_from_deps):
    """An executable reads its closure's hook outputs only when it takes them.

    The rule set's own tools, the hook runner among them, set
    `code_assets_from_deps = False`, so none of them depends on the runner.
    """
    if code_assets_from_deps:
        return Label("//dart/private/tools/hook_runner")
    return None

# What a Dart executable or test needs to turn its closure's hook outputs into
# the native-assets manifest (`native_assets_manifest`).
NATIVE_ASSETS_CONSUMER_ATTRS = {
    "_hook_runner": attr.label(
        doc = "The hook runner, which writes the native-assets manifest from the hook outputs of the closure. Unset when `code_assets_from_deps = False`.",
        default = _consumer_hook_runner_default,
        cfg = "exec",
        executable = True,
    ),
}

# The same for a rule that is never a dependency of the hook runner.
NATIVE_ASSETS_APP_ATTRS = {
    "_hook_runner": attr.label(
        doc = "The hook runner, which writes the native-assets manifest from the hook outputs of the closure.",
        default = Label("//dart/private/tools/hook_runner"),
        cfg = "exec",
        executable = True,
    ),
}

# flutter_tools' values (`targetIOSVersion`, `targetMacOSVersion`); the
# Android API level is the app's minSdk, a build setting.
_IOS_TARGET_VERSION = "15"
_MACOS_TARGET_VERSION = "13"

def _has(ctx, attr_name):
    return ctx.target_platform_has_constraint(getattr(ctx.attr, attr_name)[platform_common.ConstraintValueInfo])

def hook_target(ctx):
    """The hook's target OS and architecture, in `package:code_assets` names.

    Args:
      ctx: A rule context with `BUILD_HOOK_ATTRS`.

    Returns:
      `struct(os, arch)`, either empty when the platform names no OS or CPU
      the hook protocol knows.
    """
    os = ""
    for name in ("android", "ios", "macos", "linux", "windows"):
        if _has(ctx, "_hook_os_" + name):
            os = name
            break
    arch = ""
    for name, value in (("arm64", "arm64"), ("x64", "x64"), ("arm", "arm"), ("riscv64", "riscv64"), ("x86_32", "ia32")):
        if _has(ctx, "_hook_cpu_" + name):
            arch = value
            break
    return struct(os = os, arch = arch)

def _quote(flags):
    return " ".join(["'%s'" % f.replace("'", "'\\''") for f in flags])

def _wrapper(ctx, name, body):
    f = ctx.actions.declare_file("%s.hook_tools/%s" % (ctx.label.name, name))
    ctx.actions.write(f, "#!/bin/sh\n" + body, is_executable = True)
    return f

def _toolchain_tools(ctx, cc_toolchain, target):
    """The compiler, archiver and linker a hook gets in its input.

    `package:native_toolchain_c` recognises a tool by its file name (a
    compiler must end in `clang` or contain `-gcc`, an archiver end in `ar`, a
    linker in `ld`), and computes an Android sysroot from the compiler's own
    directory. So the NDK's `clang` is passed as it is, and any other
    toolchain gets three generated tools with those names that run the
    toolchain's own tools with its flags.

    Args:
      ctx: The rule context.
      cc_toolchain: The resolved `CcToolchainInfo`.
      target: The `hook_target` struct.

    Returns:
      `struct(cc, ar, ld, files)`: exec-root-relative paths and the Files the
      action needs besides the toolchain's own.
    """
    features = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    cc = cc_common.get_tool_for_action(feature_configuration = features, action_name = "c-compile")
    ar = cc_common.get_tool_for_action(feature_configuration = features, action_name = "c++-link-static-library")
    ld = cc_common.get_tool_for_action(feature_configuration = features, action_name = "c++-link-dynamic-library")
    if target.os == "android" and cc.endswith("/clang"):
        base = cc.rpartition("/")[0]
        return struct(cc = cc, ar = base + "/llvm-ar", ld = base + "/ld.lld", files = [])
    compile_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = features,
        action_name = "c-compile",
        variables = cc_common.create_compile_variables(
            feature_configuration = features,
            cc_toolchain = cc_toolchain,
        ),
    )
    link_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = features,
        action_name = "c++-link-dynamic-library",
        variables = cc_common.create_link_variables(
            feature_configuration = features,
            cc_toolchain = cc_toolchain,
            is_linking_dynamic_library = True,
        ),
    )

    # The toolchain's flags name exec-root-relative paths, and the hook runs in
    # its package root, so each tool runs from the exec root; every path a hook
    # passes is absolute.
    clang = _wrapper(ctx, "clang", """\
cd "$BAZEL_EXECROOT" || exit 1
# native_toolchain_c probes `clang --version` and wants exit 0; some
# toolchains' drivers (zig cc) print the version and exit 1.
if [ "$1" = "--version" ]; then '{cc}' --version 2>/dev/null; exit 0; fi
# Paths the hook passes are absolute and differ per sandbox: keep them out of
# the output, as the toolchain does for its own actions.
set -- -g0 -ffile-prefix-map="$BAZEL_EXECROOT"=. -ffile-prefix-map="$TMPDIR"=/tmp "$@"
for a in "$@"; do
  if [ "$a" = "-c" ] || [ "$a" = "-E" ] || [ "$a" = "-S" ]; then exec '{cc}' {cflags} "$@"; fi
done
# native_toolchain_c compiles and links a one-source library in one call.
# GNU ld ignores version-script names a library does not define; lld, which
# Bazel's toolchains link with, refuses them unless told otherwise.
exec '{cc}' {cflags} {lflags} "$@" -Wl,--undefined-version{strip}
""".format(
        cc = cc,
        cflags = _quote(compile_flags),
        lflags = _quote(link_flags),
        # `-g0` keeps debug info out of the hook's own objects, but a
        # toolchain's own can carry it: zig links glibc stubs it compiled in
        # whichever sandbox filled its cache, with debug info naming that
        # sandbox, so two clean builds differed in those bytes. ELF linkers
        # (lld, GNU ld) drop it with `-S`.
        strip = " -Wl,-S" if target.os in ("linux", "android") else "",
    ))
    ar_tool = _wrapper(ctx, "ar", "cd \"$BAZEL_EXECROOT\" || exit 1\nexec '%s' \"$@\"\n" % ar)
    ld_tool = _wrapper(ctx, "ld", "cd \"$BAZEL_EXECROOT\" || exit 1\nexec '%s' \"$@\"\n" % ld)
    return struct(cc = clang.path, ar = ar_tool.path, ld = ld_tool.path, files = [clang, ar_tool, ld_tool])

def _record_arg(pkg):
    return "%s|%s|%s" % (pkg.package_name, pkg.lib_root, getattr(pkg, "language_version", ""))

def exec_sdk(ctx):
    """The exec tools toolchain's `DartSdkInfo`, which runs hooks and the runner.

    Args:
      ctx: A rule context with the exec tools toolchain.

    Returns:
      The `DartSdkInfo`; fails naming the target when none is registered.
    """
    toolchain = ctx.toolchains[Label("//dart:exec_tools_toolchain_type")]
    if toolchain == None:
        fail("%s: a package with a build hook needs the Dart exec tools toolchain (register `@dart_toolchains//:all`)." % ctx.label)
    return toolchain.dart_sdk_info

def runner_launch(ctx, sdk, runner = None):
    """`dartaotruntime` and the runner snapshot.

    The toolchain names `dartaotruntime` once (`kernel_module_files`), so no
    library searches the SDK's files for it.

    Args:
      ctx: The rule context, for messages and `_hook_runner`.
      sdk: The exec tools `DartSdkInfo`.
      runner: The runner snapshot File; defaults to `ctx.executable._hook_runner`.

    Returns:
      `struct(executable, tool)`: `dartaotruntime` and the snapshot it runs.
    """
    named = getattr(sdk, "kernel_module_files", None)
    runtime = named.dartaotruntime if named != None else None
    if runtime == None:
        fail("%s: the Dart SDK %s names no `dartaotruntime`, which runs the build hook runner." % (ctx.label, sdk.version))
    return struct(executable = runtime, tool = runner or ctx.executable._hook_runner)

def declare_hooks(ctx, own_srcs, own_resources):
    """Declares what a library's hooks produce, before its `DartInfo` exists.

    The package record names the build hook's output, and the hook actions
    read the closure's records, so the outputs are declared first and the
    actions registered after (`register_hook_actions`).

    Args:
      ctx: A rule context with `BUILD_HOOK_ATTRS` and a `link_hook` attribute.
      own_srcs: The package's own Dart sources.
      own_resources: The package's own non-Dart files under `lib/`.

    Returns:
      None for a library without hooks, else `struct(build_output,
      build_kernel, record)`: the build hook's output directory and kernel
      (None without a build hook), and the `DartPackageInfo.hooks` value. A
      link hook is compiled and run where an app links
      (`dart_link_hook_actions`).
    """
    link_hook = getattr(ctx.file, "link_hook", None)
    if not ctx.file.build_hook and not link_hook:
        return None
    if ctx.file.build_hook and not ctx.files.hook_srcs:
        fail("%s: `build_hook` needs `hook_srcs`: the package's files its hook reads, at least `hook/build.dart` itself." % ctx.label)
    user_defines = None
    if ctx.attr.hook_user_defines:
        user_defines = ctx.actions.declare_file(ctx.label.name + ".hook_user_defines.json")
        ctx.actions.write(user_defines, ctx.attr.hook_user_defines)
    hook_files = [f for f in (ctx.file.build_hook, link_hook) if f != None]
    inputs = tuple(own_srcs + own_resources + hook_files + ctx.files.hook_srcs + ctx.files.hook_data)
    return struct(
        build_output = ctx.actions.declare_directory(ctx.label.name + ".hook") if ctx.file.build_hook else None,
        build_kernel = ctx.actions.declare_file(ctx.label.name + ".hook_build.dill") if ctx.file.build_hook else None,
        record = struct(
            inputs = inputs,
            user_defines = user_defines,
            pubspec = ctx.attr.hook_pubspec,
            network = ctx.attr.hook_network,
        ),
    )

def _compile_hook(ctx, launch, sdk, records, dart_closure, script, kernel, package_name):
    args = ctx.actions.args()
    args.add("--dart", sdk.dart)
    args.add_all(records, map_each = _record_arg, before_each = "--record")
    args.add("--script", script)
    args.add("--out", kernel)
    ctx.actions.run(
        executable = launch.executable,
        arguments = [launch.tool.path, "compile", args],
        inputs = depset([launch.tool, script], transitive = [dart_closure, sdk.compile_files]),
        tools = [launch.executable],
        outputs = [kernel],
        mnemonic = "DartHookCompile",
        progress_message = "Compiling %s of %s" % (script.short_path.rpartition("/")[2], package_name),
        toolchain = Label("//dart:exec_tools_toolchain_type"),
    )

def add_target_args(ctx, args, target):
    """Adds the target flags of a hook run (`--target-os`, the API levels).

    Args:
      ctx: A rule context with `BUILD_HOOK_ATTRS`.
      args: The `Args` of the run.
      target: The `hook_target` struct.
    """
    args.add("--target-os", target.os)
    args.add("--target-arch", target.arch)
    if target.os == "android":
        args.add("--android-api", str(ctx.attr._hook_android_api[BuildSettingInfo].value))
    elif target.os == "ios":
        args.add("--ios-sdk", "iphonesimulator" if target.arch == "x64" else "iphoneos")
        args.add("--ios-version", _IOS_TARGET_VERSION)
    elif target.os == "macos":
        args.add("--macos-version", _MACOS_TARGET_VERSION)

def add_hook_common_args(args, sdk, package, record_hooks, records):
    """Adds what every hook run of a package names: the SDK, the package, its user defines.

    Args:
      args: The `Args` of the run.
      sdk: The exec tools `DartSdkInfo`, whose `dart` runs the hook.
      package: The package name.
      record_hooks: The package record's `hooks` struct.
      records: depset of the closure's package records, for the package config.
    """
    args.add("--dart", sdk.dart)
    args.add("--package", package)
    args.add_all(records, map_each = _record_arg, before_each = "--record")
    if record_hooks.user_defines != None:
        args.add("--user-defines", record_hooks.user_defines)
        args.add("--pubspec", record_hooks.pubspec or "pubspec.yaml")
    if record_hooks.network:
        args.add("--network")

def hook_execution_requirements(network):
    """No network for a hook run unless its package opted in.

    Args:
      network: Whether the package opted into the network (`hook_network`).

    Returns:
      The action's `execution_requirements`.
    """
    return {"requires-network": "1"} if network else {"block-network": "1"}

# The OSes build hooks do not run for yet; goes when they are proven on macOS CI.
APPLE_HOOK_OSES = ("macos", "ios")

def apple_hook_refusal(label, package_name, hook, target_os):
    """The message a hook action on an Apple OS fails with.

    Args:
      label: The target that owns the hook.
      package_name: The name of the package whose hook is refused.
      hook: `build` or `link`.
      target_os: The hook protocol's OS name.

    Returns:
      The message string.
    """
    return ("%s: the %s hook of package:%s does not run for %s: build hooks are not yet supported on " +
            "Apple targets (macOS, iOS) in rules_dart and rules_flutter. Only sqlite3, webcrypto and " +
            "objective_c have a Bazel replacement there; another package with a hook cannot be built " +
            "for Apple targets yet.") % (label, hook, package_name, target_os)

def _refuse_hook(ctx, outputs, message):
    """Declares `outputs` as the outputs of an action that fails with `message`."""
    ctx.actions.run_shell(
        outputs = outputs,
        command = "echo \"$1\" >&2; exit 1",
        arguments = [message],
        mnemonic = "DartBuildHook",
        toolchain = None,
    )

def register_hook_actions(ctx, hooks, package, dep_infos):
    """Registers the build hook compile and run of one package.

    Args:
      ctx: A rule context with `BUILD_HOOK_ATTRS`, the
        exec tools toolchain and `BUILD_HOOK_FRAGMENTS`.
      hooks: What `declare_hooks` returned, or None.
      package: This package's `DartPackageInfo` record.
      dep_infos: The `DartInfo` of each dependency.
    """
    if hooks == None or hooks.build_output == None:
        return
    target = hook_target(ctx)
    if target.os in APPLE_HOOK_OSES:
        # Not run on Apple OSes until build hooks are proven on macOS CI: a
        # consumer that reaches the package fails with this message. sqlite3,
        # webcrypto and (in rules_flutter) objective_c keep their Bazel
        # replacements there instead (`apple_hook_replacements.bzl`).
        _refuse_hook(ctx, [hooks.build_output, hooks.build_kernel], apple_hook_refusal(ctx.label, package.package_name, "build", target.os))
        return
    sdk = exec_sdk(ctx)
    launch = runner_launch(ctx, sdk)
    records = depset([package], transitive = [info.transitive_packages for info in dep_infos])
    dart_closure = depset(
        [f for f in hooks.record.inputs if f.extension == "dart"],
        transitive = [info.transitive_srcs for info in dep_infos],
    )
    _compile_hook(ctx, launch, sdk, records, dart_closure, ctx.file.build_hook, hooks.build_kernel, package.package_name)

    out = hooks.build_output
    if not target.os or not target.arch:
        # No hook can build for this platform; a consumer that reaches the
        # package fails with this message when it asks for the output.
        _refuse_hook(ctx, [out], "%s: the build hook of package:%s cannot run for this target platform: the hook protocol knows no OS or CPU of it." % (ctx.label, package.package_name))
        return

    cc_target = ctx.attr._hook_cc_toolchain
    cc_toolchain = cc_target[cc_common.CcToolchainInfo] if cc_target != None and cc_common.CcToolchainInfo in cc_target else None
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    add_hook_common_args(args, sdk, package.package_name, hooks.record, records)
    args.add("--hook-kernel", hooks.build_kernel)
    add_target_args(ctx, args, target)
    tool_files = []
    toolchain_files = []
    if cc_toolchain != None:
        tools = _toolchain_tools(ctx, cc_toolchain, target)
        args.add("--cc", tools.cc)
        args.add("--ar", tools.ar)
        args.add("--ld", tools.ld)
        tool_files = tools.files
        toolchain_files = [cc_toolchain.all_files]
    if target.os in ("ios", "macos"):
        # `native_toolchain_c` finds the Apple SDK with `xcrun` itself.
        args.add("--path", "/usr/bin")
    args.add("--out", out.path)

    ctx.actions.run(
        executable = launch.executable,
        arguments = [launch.tool.path, "build", args],
        inputs = depset(
            [launch.tool, hooks.build_kernel] + list(hooks.record.inputs) + tool_files +
            ([hooks.record.user_defines] if hooks.record.user_defines != None else []),
            transitive = [sdk.runtime_files] + toolchain_files,
        ),
        tools = [launch.executable],
        outputs = [out],
        mnemonic = "DartBuildHook",
        progress_message = "Running the build hook of %s" % package.package_name,
        execution_requirements = hook_execution_requirements(hooks.record.network),
        toolchain = Label("//dart:exec_tools_toolchain_type"),
    )

def _asset_index(f):
    # A build hook's output directory, or a `dart_code_asset`'s index; not the
    # library the index names.
    if f.is_directory or f.basename.endswith(".assets.json"):
        return f.path
    return None

def native_assets_manifest(ctx, assets, target, name, style = "relative", relative_to = None, lib_dir = "", runfiles_prefix = "", bundle = True, bundle_path = None, format = "dart"):
    """Writes an app's native-assets manifest and bundles its libraries.

    One action (`DartNativeAssets`) reads the code assets of every hook
    output and `dart_code_asset` in `assets` and writes the mapping the
    compiler embeds (`native_assets.yaml`, through `package:hooks_runner`'s
    own `KernelAssets`), and copies each bundled library into one directory.

    Args:
      ctx: A rule context with `_hook_runner` and the exec tools toolchain.
      assets: depset of the closure's native-asset Files
        (`DartInfo.transitive_native_assets`).
      target: The `<os>_<arch>` the app runs on.
      name: Prefix of the declared outputs.
      style: How the manifest names a bundled library: `relative` (to
        `relative_to`), `basename` (the loader finds it by name, as a Flutter
        app's are), `runfiles` (`runfiles_prefix` + its path in the bundle) or
        `framework` (an Apple framework).
      relative_to: Directory (exec path) a `relative` path starts from.
      lib_dir: Subdirectory of the bundle the libraries go to.
      runfiles_prefix: Prefix of a `runfiles` path.
      bundle: Whether to copy the libraries (into `<name>.native_assets/`).
      bundle_path: Where to declare the bundle directory instead, relative
        to the package.
      format: `dart` (`native_assets.yaml`, as `dart build` writes it) or
        `flutter` (`native_assets.json`, compact JSON as the Flutter tool
        writes it: a Flutter app's bundle carries it as
        `NativeAssetsManifest.json`).

    Returns:
      `struct(manifest, bundle)`: the manifest File and the bundle directory
      (None when `bundle` is false).
    """
    sdk = exec_sdk(ctx)
    launch = runner_launch(ctx, sdk)
    manifest = ctx.actions.declare_file(name + (".native_assets.json" if format == "flutter" else ".native_assets.yaml"))
    outputs = [manifest]
    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add("--target", target)
    args.add_all(assets, map_each = _asset_index, before_each = "--assets", expand_directories = False, uniquify = True)
    args.add("--manifest", manifest)
    args.add("--style", style)
    args.add("--format", format)
    if lib_dir:
        args.add("--lib-dir", lib_dir)
    if relative_to != None:
        args.add("--relative-to", relative_to)
    if runfiles_prefix:
        args.add("--runfiles-prefix", runfiles_prefix)
    bundle_dir = None
    if bundle:
        bundle_dir = ctx.actions.declare_directory(bundle_path or name + ".native_assets")
        args.add("--bundle", bundle_dir.path)
        outputs.append(bundle_dir)
    ctx.actions.run(
        executable = launch.executable,
        arguments = [launch.tool.path, "manifest", args],
        inputs = depset([launch.tool], transitive = [assets]),
        tools = [launch.executable],
        outputs = outputs,
        mnemonic = "DartNativeAssets",
        progress_message = "Writing the native assets manifest of %{label}",
        toolchain = Label("//dart:exec_tools_toolchain_type"),
    )
    return struct(manifest = manifest, bundle = bundle_dir)

def run_link_hook(ctx, launch, sdk, package, records, dart_closure, build_outputs, recorded_uses, declared, name):
    """Runs one package's link hook through the hook runner (`DartLinkHook`).

    Args:
      ctx: A rule context with the exec tools toolchain.
      launch: What `runner_launch` returns: the runtime and the runner snapshot.
      sdk: The exec tools `DartSdkInfo`.
      package: The package's `DartPackageInfo` record, with `link_hook` and
        `hooks`.
      records: depset of the closure's package records.
      dart_closure: depset of the closure's Dart sources, which the hook
        compiles against (`DartHookCompile`).
      build_outputs: depset of the closure's build hook output directories,
        whose assets for linking the hook receives.
      recorded_uses: The recorded-uses JSON File, or None.
      declared: List of `struct(name, file)`: the data assets the hook must
        emit, each copied to its declared File.
      name: Prefix of the declared outputs.

    Returns:
      The hook's output directory.
    """
    hooks = package.hooks
    out = ctx.actions.declare_directory("%s/%s.link" % (name, package.package_name))
    target_os = hook_target(ctx).os if hasattr(ctx.attr, "_hook_os_macos") else ""
    if target_os in APPLE_HOOK_OSES:
        # As for build hooks: not run on Apple OSes until proven on macOS CI.
        ctx.actions.run_shell(
            outputs = [out] + [asset.file for asset in declared],
            command = "echo \"$1\" >&2; exit 1",
            arguments = [apple_hook_refusal(ctx.label, package.package_name, "link", target_os)],
            mnemonic = "DartLinkHook",
            toolchain = None,
        )
        return out
    kernel = ctx.actions.declare_file("%s/%s.link.dill" % (name, package.package_name))
    _compile_hook(ctx, launch, sdk, records, dart_closure, package.link_hook, kernel, package.package_name)
    args = ctx.actions.args()
    add_hook_common_args(args, sdk, package.package_name, hooks, records)
    args.add("--hook-kernel", kernel)
    args.add_all(build_outputs, before_each = "--build-assets", expand_directories = False)
    if recorded_uses != None:
        args.add("--recorded-uses", recorded_uses)
    for asset in declared:
        args.add("--declare", "%s=%s" % (asset.name, asset.file.path))
    args.add("--out", out.path)
    ctx.actions.run(
        executable = launch.executable,
        arguments = [launch.tool.path, "link", args],
        inputs = depset(
            [launch.tool, kernel] + list(hooks.inputs) +
            ([hooks.user_defines] if hooks.user_defines != None else []) +
            ([recorded_uses] if recorded_uses != None else []),
            transitive = [sdk.runtime_files, build_outputs],
        ),
        tools = [launch.executable],
        outputs = [out] + [asset.file for asset in declared],
        mnemonic = "DartLinkHook",
        progress_message = "Running the link hook of %s for %%{label}" % package.package_name,
        execution_requirements = hook_execution_requirements(hooks.network),
        toolchain = Label("//dart:exec_tools_toolchain_type"),
    )
    return out
