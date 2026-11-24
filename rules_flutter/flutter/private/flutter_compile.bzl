"""Flutter kernel compilation action using the frontend_server.

Flutter compilation differs from vanilla Dart in that it uses:
- Flutter's patched SDK (platform_strong.dill) instead of the standard Dart SDK
- The frontend_server_aot.dart.snapshot instead of `dart compile kernel`
"""

load("//flutter:providers.bzl", "resolve_flutter_sdk_info")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "app_scheme_location", "in_place_roots", "validate_filesystem_roots")
load(
    "//flutter/private:flutter_compile_params.bzl",
    _flutter_kernel_dills = "flutter_kernel_dills",
    _flutter_kernel_options = "flutter_kernel_options",
    _flutter_kernel_outputs = "flutter_kernel_outputs",
    _flutter_kernel_sources = "flutter_kernel_sources",
)

visibility(["//flutter/..."])

# `vm_flags` entries analysis accepts, as flag names without the leading
# `--`. The Dart VM interprets every flag before the snapshot, so only flags
# with no file, network or compilation-semantics side effects are allowed:
#
# - heap and GC sizing, each spelled `--name=<bytes>` with a plain integer:
#   `old-gen-heap-size`, `new-gen-semi-initial-size`, `new-gen-semi-max-size`,
#   `new-gen-garbage-threshold`, `new-gen-growth-factor`;
# - side-effect-free diagnostics, spelled bare: `enable-asserts`,
#   `verbose-gc`, `concurrent-mark`, `concurrent-sweep`.
#
# Name matching ignores case and treats `-` and `_` as the same, the way the
# VM parses them. Everything else fails the build at analysis — notably
# `--packages`, `--platform`, `--*-dill`, `--native-assets`,
# `--timeline-recorder`, `--snapshot*`, `--observe`, `--dfe`,
# `--ignore-unrecognized-flags` and `--define`/`-D` (defines belong in
# `defines`): such flags rename the compile's inputs, smuggle undeclared
# bytes into the dill, or write host files outside the action's declared
# inputs and outputs.
_VM_FLAG_SIZES = [
    "old-gen-heap-size",
    "new-gen-semi-initial-size",
    "new-gen-semi-max-size",
    "new-gen-garbage-threshold",
    "new-gen-growth-factor",
]

_VM_FLAGS_BARE = [
    "enable-asserts",
    "verbose-gc",
    "concurrent-mark",
    "concurrent-sweep",
]

# `extra_flags` entries analysis accepts, as flag names without the leading
# dashes: only `frontend_server` boolean flags that read no file, write no
# file and cannot change which files the compile reads. Everything else —
# notably every flag naming a file the compile does not declare, and any
# unknown flag — fails the build at analysis, so a smuggled flag can widen
# neither the read set nor the dill. Name matching ignores case and treats
# `-` and `_` as the same, the way the VM parses them.
_EXTRA_FLAGS_ALLOWED = {
    # Deltas recompile only changed libraries; names no file.
    "incremental": True,
    # Emits widget-creation metadata into the dill; names no file.
    "track-widget-creation": True,
}

# `extra_flags` entries refused with the file-naming message, as flag names
# without leading dashes: `frontend_server` flags that name a file (or a host
# side effect) the action does not declare. The action passes its own inputs
# (`--packages`, `--platform`, `--filesystem-root`, `--source`,
# `--native-assets`, `--recorded-uses`, `--from-dill`, `--import-dill`,
# `--output-dill`) from Starlark `File` objects and records them in the
# `kernel_filter` manifest; a caller spelling any of them in `extra_flags`
# fails the build at analysis with this message instead of the generic
# allow-list one. Name matching ignores case and treats `-` and `_` as the
# same.
_EXTRA_FLAG_BLOCKED = [
    "packages",
    "package-config",
    "platform",
    "sdk-root",
    "filesystem-root",
    "filesystem-scheme",
    "source",
    "native-assets",
    "recorded-uses",
    "from-dill",
    "import-dill",
    "output-dill",
    "output-incremental-dill",
    "depfile",
    "timeline-recorder",
    "snapshot",
    "snapshot-kind",
    "save-debugging-info",
    "observe",
    "enable-vm-service",
    "dfe",
]

# `extra_flags` entries that would switch off the dependency report
# `kernel_filter` verifies after the compile. The report (`+file://` lines)
# is what turns an undeclared read into a loud build error; switching it off
# makes the check pass vacuously while the dill still embeds the undeclared
# bytes. The compile passes its own `--print-incremental-dependencies` after
# the caller's flags and fails closed on zero reads, but the spelling is
# refused at analysis too so the failure names the flag early. Name matching
# is the same as below (case-insensitive, `-` and `_` the same, one or two
# leading dashes).
_READ_SET_FLAGS = [
    "print-incremental-dependencies",
    "no-print-incremental-dependencies",
]

def _normalize_flag_name(name):
    return name.lower().replace("_", "-")

def _is_uint(value):
    if value == "":
        return False
    for c in value.elems():
        if c not in "0123456789":
            return False
    return True

def _reject_line_break(label, param, value):
    """Fails when an argv-bound caller string holds a line break.

    A line break in an argv entry splits into several argv elements once the
    argv passes through a `multiline` param file — a `_check_extra_flags`
    refusal the check never saw. Every caller-supplied string (flags,
    defines, roots, URIs, the target) must be single-line.

    Args:
        label: The calling target's label, for the message.
        param: The parameter name, for the message.
        value: The string to check.
    """
    if "\n" in value or "\r" in value:
        fail("%s: %s entry %r contains a line break: argv-bound strings must be single-line" % (label, param, value))

def _check_kernel_strings(label, defines, filesystem_roots, entrypoint_uri, registrant_uri, target):
    """Fails when an argv-bound caller string holds a line break.

    Args:
        label: The calling target's label, for the message.
        defines: The `defines` entries (each becomes a `-D` flag).
        filesystem_roots: The `filesystem_roots` entries (each becomes a
            `--filesystem-root` value).
        entrypoint_uri: The explicit `entrypoint_uri`, or None for the default.
        registrant_uri: The `dart_plugin_registrant_uri`, or None when absent.
        target: The frontend-server `--target` model.
    """
    for d in defines:
        _reject_line_break(label, "defines", d)
    for r in filesystem_roots:
        _reject_line_break(label, "filesystem_roots", r)
    if entrypoint_uri != None:
        _reject_line_break(label, "entrypoint_uri", entrypoint_uri)
    if registrant_uri != None:
        _reject_line_break(label, "dart_plugin_registrant_uri", registrant_uri)
    if target != None:
        _reject_line_break(label, "target", target)

def _check_vm_flags(label, vm_flags):
    for flag in vm_flags:
        _reject_line_break(label, "vm_flags", flag)
        if not flag.startswith("--") or flag == "--":
            fail("%s: vm_flags entries must be `--flag` passed to dartaotruntime, got %r" % (label, flag))
        name, eq, value = flag[2:].partition("=")
        norm = _normalize_flag_name(name)
        if norm in _VM_FLAGS_BARE:
            if eq:
                fail("%s: vm_flags %r takes no value: `%s` is a bare diagnostic flag" % (label, flag, flag))
        elif norm in _VM_FLAG_SIZES:
            if not eq or not _is_uint(value):
                fail("%s: vm_flags %r needs `--name=<bytes>` with a plain integer value" % (label, flag))
        else:
            sizes = ", ".join(["--" + f for f in _VM_FLAG_SIZES])
            bare = ", ".join(["--" + f for f in _VM_FLAGS_BARE])
            fail("%s: vm_flags %r is not allowed: only heap/GC sizing (%s) and bare diagnostics (%s) may precede the snapshot; flags naming files or side effects (`--packages`, `--*-dill`, `--platform`, `--native-assets`, `--timeline-recorder`, `--snapshot*` and similar) are refused" % (label, flag, sizes, bare))

def _check_extra_flags(label, extra_flags):
    for flag in extra_flags:
        _reject_line_break(label, "extra_flags", flag)
        if not flag.startswith("-") or flag == "-" or flag == "--":
            fail("%s: extra_flags entries must be frontend_server `--flag`s, got %r" % (label, flag))
        stripped = flag[2:] if flag.startswith("--") else flag[1:]
        name, eq, _value = stripped.partition("=")
        norm = _normalize_flag_name(name)
        if norm in _READ_SET_FLAGS:
            fail("%s: extra_flags %r controls the dependency report the compile verifies: the compile controls `--print-incremental-dependencies` itself, remove the flag" % (label, flag))
        if norm in _EXTRA_FLAG_BLOCKED:
            fail("%s: extra_flags %r names a file the compile does not declare: pass inputs through `srcs`/`deps`/`import_dill`/`from_dill`/`native_assets_manifest` instead" % (label, flag))
        if norm in _EXTRA_FLAGS_ALLOWED:
            if eq:
                fail("%s: extra_flags %r takes no value: `%s` is a bare flag" % (label, flag, flag))
        else:
            fail("%s: extra_flags %r is not allowed: only %s may be passed; flags naming files or side effects (`--packages`, `--*-dill`, `--platform`, `--filesystem-root`, `--initialize-from-dill`, `--far-manifest` and similar) are refused" % (label, flag, ", ".join(["--" + f for f in sorted(_EXTRA_FLAGS_ALLOWED.keys())])))

def _kernel_action_env(output, dartaotruntime):
    """The sandboxed environment for the `FlutterKernelCompile` action.

    Suppresses Dart/Flutter analytics (avoids writes to `$HOME/.dart` in the
    sandbox) and provides a writable `HOME` scoped to the action's output
    directory.
    """
    env = {"CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
    if dartaotruntime.basename.endswith(".exe"):
        env["USERPROFILE"] = output.dirname
        env["LOCALAPPDATA"] = output.dirname
    else:
        env["HOME"] = output.dirname
    return env

def _default_entrypoint_uri(entrypoint_uri, main):
    """The stable app-scheme URI frontend_server compiles as the root library.

    The default is the stable app-scheme URI, not `main`'s exec path:
    compiling the exec path keys the root library by a sandbox-specific
    `file://` URI, which poisons the whole dill with absolute host paths.
    """
    if entrypoint_uri == None:
        return app_scheme_location(main).uri
    return entrypoint_uri

def _run_kernel_action(ctx, run):
    """Runs the `FlutterKernelCompile` action, through `kernel_filter`.

    Args:
        ctx: The rule context.
        run: struct describing the action: `args` (the compiler argv), `manifest`
            (the declared-inputs manifest), `direct_inputs` and `outputs` (from
            `_kernel_action_inputs`), `env` (the sandboxed environment),
            `dartaotruntime`, `kernel_filter_tool` and `frontend_server` (the
            executables), `resource_set` (host-resource constraints, or None to
            keep byte-identical actions).
    """
    run_kwargs = dict(
        executable = run.kernel_filter_tool,
        arguments = ["--declared-inputs", run.manifest.path, run.args],
        inputs = depset(
            direct = run.direct_inputs + [run.dartaotruntime, run.kernel_filter_tool, run.manifest],
        ),
        outputs = run.outputs,
        mnemonic = "FlutterKernelCompile",
        progress_message = "Compiling Flutter kernel %s" % ctx.label,
        env = run.env,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    if run.resource_set != None:
        run_kwargs["resource_set"] = run.resource_set
    ctx.actions.run(**run_kwargs)

# Private tool labels a downstream rule merges into its own `attrs` to call
# `flutter_kernel_compile_action` — the Flutter half of what rules_dart
# publishes as `KERNEL_MODULE_ATTRS`. Carries no user-facing attrs: the
# caller's rule declares its own `main`, `srcs` and `deps`.
FLUTTER_KERNEL_COMPILE_ATTRS = {
    "_kernel_filter_tool": attr.label(
        doc = "The kernel-filter guard the compile runs through (checks " +
              "directives before, verifies the read set after).",
        default = Label("//flutter/private/tools:kernel_filter"),
        executable = True,
        cfg = "exec",
    ),
}

# Toolchains a downstream rule declares to call `flutter_kernel_compile_action`
# (via `flutter_kernel_compile_tools`) and `compile_package_config` — the
# Flutter half of what rules_dart publishes as `MODULAR_KERNEL_TOOLCHAINS`.
# The product-tools toolchain is optional: only `flutter_kernel_compile_tools`
# with `product = True` reads it.
FLUTTER_KERNEL_COMPILE_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
    "@rules_dart//dart:exec_tools_toolchain_type",
    config_common.toolchain_type("@rules_flutter//flutter:product_tools_toolchain_type", mandatory = False),
    Label("@rules_dart//dart:copy_toolchain_type"),
]

def flutter_kernel_compile_tools(ctx, product = False):
    """Resolves the tool Files a `flutter_kernel_compile_action` call needs.

    For a rule in another module composing over `@rules_flutter//flutter:utils.bzl`
    — the Flutter half of what rules_dart publishes as `find_kernel_module_tools`.
    The rule declares `FLUTTER_KERNEL_COMPILE_ATTRS` in its `attrs` and
    `FLUTTER_KERNEL_COMPILE_TOOLCHAINS` in its `toolchains`, then calls this
    and threads the struct into `flutter_kernel_compile_action`.

    Args:
        ctx: The caller rule's context.
        product: When True, `platform_dill` is the release
            `platform_strong_product.dill`; otherwise the debug
            `platform_strong.dill`. A True caller needs the product-tools
            sub-toolchain resolved (it is in `FLUTTER_KERNEL_COMPILE_TOOLCHAINS`).

    Returns:
        struct with `dartaotruntime`, `kernel_filter_tool`, `frontend_server`
        and `platform_dill`.
    """
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    platform_dill = flutter_sdk_info.platform_kernel_dill_product if product else flutter_sdk_info.platform_kernel_dill
    if platform_dill == None:
        fail(
            "%s: no %s platform dill: declare the product-tools sub-toolchain from FLUTTER_KERNEL_COMPILE_TOOLCHAINS." %
            (ctx.label, "product" if product else "debug"),
        )
    return struct(
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
    )

def _add_kernel_target_args(args, platform_dill, target, package_config, output):
    """Appends the target-model argv: SDK root, target, packages and output.

    `--sdk-root` points to the directory containing the platform dill;
    `--platform` names the exact file only when it is not the default
    `platform_strong.dill`. The compiler reports every file it reads as a
    `+file://` line unless told not to; `kernel_filter` verifies those lines
    against the declared inputs and drops them.
    """
    args.add("--sdk-root", platform_dill.dirname + "/")
    if platform_dill.basename != "platform_strong.dill":
        args.add("--platform", platform_dill.path)

    args.add("--target", target)
    args.add("--packages", package_config)
    args.add("--output-dill", output)
    args.add("--verbosity=error")

def _add_kernel_mode_args(ctx, args, aot, defines, define_flagfiles):
    """Appends the compilation-mode argv: AOT flags, asserts, defines and flagfiles."""
    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-source-text")

    # Compilation mode flags: enable assertions in `-c dbg` and in non-AOT
    # compiles (such as `flutter_test` fallback compiles).
    bazel_mode = ctx.var["COMPILATION_MODE"]
    if bazel_mode == "dbg" or not aot:
        args.add("--enable-asserts")

    # Flagfiles first, so a `-D` of the same key (the target's `defines`, the global flag) wins.
    for flagfile in define_flagfiles:
        args.add("@" + flagfile.path)
    for d in defines:
        args.add("-D" + d)

def _mount_kernel_sources(ctx, args, compile_sources, filesystem_roots):
    """Mounts the roots the compile reads its sources in place from.

    Every input is read where it is, under APP_SCHEME at its workspace path:
    the output directories that hold the generated inputs come first, so a
    generated file keeps precedence over a source at the same app path, then
    the exec root (`.`) for the sources (`in_place_roots`), then the caller's
    `filesystem_roots`. No file is staged, so every `org-dartlang-app:///` URI
    (package roots, the entrypoint, the registrant) names the same path it
    always did.

    Under local and worker strategies undeclared files are visible to the
    compiler through these roots. Hermeticity rests on three layers instead
    of invisibility: the directive guard refuses disallowed directives before
    the compile, `kernel_filter` verifies the frontend's dependency report
    against the declared-inputs manifest after it (failing closed on anything
    it cannot verify), and the sandbox — or remote execution — exposes only
    declared inputs.

    Args:
        ctx: The rule context.
        args: The compiler argv object to append to.
        compile_sources: The declared main and source `File`s.
        filesystem_roots: The caller's extra exec-root-relative roots.

    Returns:
        The exec-root-relative roots mounted via `--filesystem-root`.
    """
    mounted_roots = in_place_roots(ctx, compile_sources)
    for r in filesystem_roots:
        if r != None and r != "" and r != "." and r not in mounted_roots:
            mounted_roots.append(r)
    for root in mounted_roots:
        args.add("--filesystem-root", root)
    args.add("--filesystem-scheme", APP_SCHEME)
    return mounted_roots

def _add_kernel_input_args(args, inputs):
    """Appends the input argv: registrant, caller flags, manifests and entrypoint.

    Args:
        args: The compiler argv object to append to.
        inputs: struct with the compile inputs: `dart_plugin_registrant_uri`,
            `extra_flags`, `native_assets_manifest`, `recorded_uses`,
            `from_dill`, `import_dill`, `entrypoint_uri` and `main`.
    """
    if inputs.dart_plugin_registrant_uri:
        args.add("--source", inputs.dart_plugin_registrant_uri)
        args.add("--source", "package:flutter/src/dart_plugin_registrant.dart")
        args.add("-Dflutter.dart_plugin_registrant=" + inputs.dart_plugin_registrant_uri)

    args.add_all(inputs.extra_flags)

    if inputs.native_assets_manifest != None:
        args.add("--native-assets", inputs.native_assets_manifest.path)

    if inputs.recorded_uses != None:
        args.add("--recorded-uses", inputs.recorded_uses)

    if inputs.from_dill != None:
        args.add("--from-dill", inputs.from_dill.path)

    if inputs.import_dill != None:
        args.add("--import-dill=" + inputs.import_dill.path)

    if inputs.entrypoint_uri:
        args.add(inputs.entrypoint_uri)
    else:
        args.add(inputs.main)

def _kernel_action_inputs(inputs):
    """Assembles the action's declared inputs and outputs.

    Args:
        inputs: struct with the compile inputs: `main`, `package_config`,
            `frontend_server`, `platform_dill`, `srcs`, `from_dill`,
            `native_assets_manifest`, `import_dill`, `output` and
            `recorded_uses`.

    Returns `struct(direct_inputs, outputs)`.
    """
    if inputs.from_dill != None:
        direct_inputs = [
            inputs.main,
            inputs.package_config,
            inputs.frontend_server,
            inputs.platform_dill,
            inputs.from_dill,
        ]
    else:
        direct_inputs = [
            inputs.main,
            inputs.package_config,
            inputs.frontend_server,
            inputs.platform_dill,
        ] + inputs.srcs
    if inputs.native_assets_manifest != None:
        direct_inputs.append(inputs.native_assets_manifest)
    if inputs.import_dill != None:
        direct_inputs.append(inputs.import_dill)
    direct_inputs.extend(inputs.define_flagfiles)
    outputs = [inputs.output]
    if inputs.recorded_uses != None:
        outputs.append(inputs.recorded_uses)
    return struct(direct_inputs = direct_inputs, outputs = outputs)

def _write_kernel_manifest(ctx, manifest, inputs, mounted_roots):
    """Writes the declared-inputs manifest `kernel_filter` guards against.

    Args:
        ctx: The rule context.
        manifest: The manifest File to write.
        inputs: struct with the compile inputs: `compile_sources`, `main`,
            `package_config`, `platform_dill`, `from_dill`, `import_dill`,
            `native_assets_manifest` and `output`.
        mounted_roots: The `--filesystem-root` values from `_mount_kernel_sources`.

    The declared sources, then an empty `# staged` section (the compile reads
    every input in place, so no input has a second spelling), then every other
    file the compiler may read (the package config, the platform dill, the
    summary dills, the native-assets manifest), the mounted filesystem roots
    the directive guard resolves through, the entrypoint's exec path the
    report check requires the report to name, and the output dill the refusal
    path deletes. Every entry names a Starlark-declared
    `File` (or an action-constructed root/output string): `kernel_filter`
    derives nothing from the compile argv, so a flag smuggled into
    `vm_flags` or `extra_flags` cannot widen what the compile may read.
    Written by path so the tool reads the same files the compiler resolves
    through the mounted roots.
    """
    allowed_reads = [inputs.package_config, inputs.platform_dill]
    if inputs.from_dill != None:
        allowed_reads.append(inputs.from_dill)
    if inputs.import_dill != None:
        allowed_reads.append(inputs.import_dill)
    if inputs.native_assets_manifest != None:
        allowed_reads.append(inputs.native_assets_manifest)
    ctx.actions.write(
        output = manifest,
        content = "\n".join(
            [f.path for f in inputs.compile_sources if f != None] +
            ["# staged"] +
            ["# allowed-reads"] +
            [f.path for f in allowed_reads] +
            ["# filesystem-roots"] +
            mounted_roots +
            ["# entrypoint", inputs.main.path] +
            ["# output", inputs.output.path],
        ) + "\n",
    )

# The parameter objects `flutter_kernel_compile_action` takes, re-exported
# beside it so callers load the call and its constructors from one module.
# See `flutter_kernel_sources`, `flutter_kernel_outputs`,
# `flutter_kernel_options` and `flutter_kernel_dills` for the fields.
flutter_kernel_sources = _flutter_kernel_sources
flutter_kernel_outputs = _flutter_kernel_outputs
flutter_kernel_options = _flutter_kernel_options
flutter_kernel_dills = _flutter_kernel_dills

def _check_kernel_request(ctx, sources, options):
    """Fails the build at analysis when a kernel compile request is invalid.

    Runs every static check `flutter_kernel_compile_action` needs before it
    declares anything: the `vm_flags` and `extra_flags` allow-lists, the
    mounted filesystem roots, and the single-line argv-bound strings. One
    function so the call cannot run some checks and forget others.

    Args:
        ctx: The rule context, carrying the target label for error messages.
        sources: The struct from `flutter_kernel_sources`: what the compile
            reads and resolves.
        options: The struct from `flutter_kernel_options`: how the compile
            runs.
    """
    _check_vm_flags(ctx.label, options.vm_flags)
    _check_extra_flags(ctx.label, options.extra_flags)
    validate_filesystem_roots(ctx.label, sources.filesystem_roots)
    _check_kernel_strings(
        ctx.label,
        options.defines,
        sources.filesystem_roots,
        sources.entrypoint_uri,
        sources.dart_plugin_registrant_uri,
        options.target,
    )

def flutter_kernel_compile_action(ctx, tools, sources, outputs, options, dills, resource_set = None):
    """Creates a Flutter kernel compilation action.

    Invokes the frontend_server via dartaotruntime to compile Dart sources
    to a kernel .dill file using Flutter's patched platform SDK.

    Args:
        ctx: The rule context.
        tools: The struct from `flutter_kernel_compile_tools`: the
            `dartaotruntime` executable, the `kernel_filter` guard, the
            `frontend_server` snapshot and the platform dill to compile
            against.
        sources: The struct from `flutter_kernel_sources`: what the compile
            reads and resolves.
        outputs: The struct from `flutter_kernel_outputs`: what the compile
            produces.
        options: The struct from `flutter_kernel_options`: how the compile
            runs.
        dills: The struct from `flutter_kernel_dills`: the precompiled dills
            the compile builds on, if any.
        resource_set: Optional value passed to
            `ctx.actions.run(resource_set = ...)` constraining the compile
            action's host resources. Unset by default, so existing callers
            keep byte-identical actions.
    """
    _check_kernel_request(ctx, sources, options)

    # The default entrypoint is the stable app-scheme URI, not `main`'s
    # exec path: compiling the exec path keys the root library by a
    # sandbox-specific `file://` URI, which poisons the whole dill with
    # absolute host paths. A source `main` resolves through the mounted exec
    # root, a generated one through its output directory. Callers passing an
    # explicit URI — every stock rule — are unaffected.
    entrypoint_uri = _default_entrypoint_uri(
        entrypoint_uri = sources.entrypoint_uri,
        main = sources.main,
    )

    manifest = ctx.actions.declare_file(outputs.output.basename + ".flutter_inputs")
    args = ctx.actions.args()
    args.add("--")
    args.add(tools.dartaotruntime)
    args.add_all(options.vm_flags)
    args.add(tools.frontend_server)

    # The helpers below append contiguous argv runs in call order, so the
    # action's argv reads exactly as before the split.
    _add_kernel_target_args(
        args,
        tools.platform_dill,
        options.target,
        sources.package_config,
        outputs.output,
    )
    _add_kernel_mode_args(
        ctx,
        args,
        options.aot,
        options.defines,
        options.define_flagfiles,
    )

    compile_sources = [sources.main] if dills.from_dill != None else [sources.main] + sources.srcs
    mounted_roots = _mount_kernel_sources(
        ctx,
        args,
        compile_sources,
        sources.filesystem_roots,
    )
    inputs = struct(
        compile_sources = compile_sources,
        dart_plugin_registrant_uri = sources.dart_plugin_registrant_uri,
        define_flagfiles = options.define_flagfiles,
        entrypoint_uri = entrypoint_uri,
        extra_flags = options.extra_flags,
        from_dill = dills.from_dill,
        frontend_server = tools.frontend_server,
        import_dill = dills.import_dill,
        main = sources.main,
        native_assets_manifest = sources.native_assets_manifest,
        output = outputs.output,
        package_config = sources.package_config,
        platform_dill = tools.platform_dill,
        recorded_uses = outputs.recorded_uses,
        srcs = sources.srcs,
    )
    _add_kernel_input_args(args = args, inputs = inputs)

    env = _kernel_action_env(output = outputs.output, dartaotruntime = tools.dartaotruntime)

    action_io = _kernel_action_inputs(inputs = inputs)
    _write_kernel_manifest(ctx = ctx, manifest = manifest, inputs = inputs, mounted_roots = mounted_roots)

    _run_kernel_action(ctx = ctx, run = struct(
        args = args,
        manifest = manifest,
        direct_inputs = action_io.direct_inputs,
        outputs = action_io.outputs,
        env = env,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        resource_set = resource_set,
    ))
