"""How the compile wrapper (`app_jit_snapshot.dart`) is launched by compile actions.

The `exe` and `aot-snapshot` compiles and the `gen_kernel` step run the
wrapper (see `dart_compile.bzl`). Run from source, every action makes the VM
parse and JIT-compile the whole tool before it does any work. The `kernel_module`
tool avoids that cost by being an AOT snapshot run by `dartaotruntime`; the
wrapper does the same: `//dart/private/tools:compile_wrapper` is the
prebuilt AOT snapshot of the very same sources, compiled once (by the tool run
from source, so it cannot depend on itself), and the compile actions
run it under the SDK's `dartaotruntime`. Only the `jit-snapshot` training keeps
running the tool from source, since its job is to train a JIT snapshot.
"""

load("//dart/private:dart_import_check.bzl", "import_check_for_binary")

visibility(["//dart/..."])

_WRAPPER_LABEL = Label("//dart/private/tools:compile_wrapper")

_JIT_TOOL_ATTRS = {
    "_jit_tool": attr.label(
        doc = "Every source the JIT tool imports, staged beside its entry in the actions that run it from source.",
        default = "//dart/private/tools:jit_tool_srcs",
        allow_files = True,
    ),
    "_comma_patch": attr.label(
        doc = "The `comma_patch.dart` source staged beside the JIT tool's entry so comma-containing `-D` values survive the front end. Defaults to `//dart/private/tools:comma_patch.dart`.",
        default = "//dart/private/tools:comma_patch.dart",
        allow_single_file = True,
    ),
}

def _wrapper_default(use_compile_wrapper):
    """The computed default of `_compile_wrapper`: no wrapper for the wrapper itself.

    Args:
        use_compile_wrapper: The rule's `use_compile_wrapper` attribute.

    Returns:
        The wrapper label, or None when the target compiles without a wrapper.
    """
    return _WRAPPER_LABEL if use_compile_wrapper else None

# The attributes of `dart_binary`, which lets the wrapper opt out of itself.
COMPILE_WRAPPER_ATTRS = dict(_JIT_TOOL_ATTRS, **{
    "use_compile_wrapper": attr.bool(
        default = True,
        doc = "Whether the `exe`, `aot-snapshot` and `gen_kernel` actions run the prebuilt AOT snapshot of the compile wrapper. When off they run the wrapper from source, as the `jit-snapshot` mode always does. Only `//dart/private/tools:compile_wrapper`, the snapshot itself, turns it off, because it cannot be built by itself; it also skips the layering-check tool, itself compiled through the snapshot.",
    ),
    "_compile_wrapper": attr.label(
        doc = "The prebuilt AOT snapshot of the compile wrapper, run by `dartaotruntime` in the `exe`, `aot-snapshot` and `gen_kernel` actions.",
        default = _wrapper_default,
        executable = True,
        cfg = "exec",
    ),
})

def import_check_unless_wrapper(name, deps, use_compile_wrapper):
    """The computed default of `dart_binary`'s `_import_check` attribute.

    The compile wrapper's own build skips the layering check as well as the
    wrapper: the check tool is compiled through the wrapper, so naming it from
    the wrapper would be a dependency cycle.

    Args:
        name: The `dart_binary`'s `name`.
        deps: The `dart_binary`'s `deps`.
        use_compile_wrapper: The `dart_binary`'s `use_compile_wrapper`.

    Returns:
        The check tool's label, or None when this build must not depend on it.
    """
    if not use_compile_wrapper:
        return None
    return import_check_for_binary(name, deps)

def compile_wrapper_inputs(ctx):
    """The wrapper-related `cfg` fields of `dart_compile_action`.

    Args:
        ctx: The rule context of a `dart_binary`.

    Returns:
        `struct(jit_tool, comma_patch, compile_wrapper)`: the tool sources and
        the `comma_patch.dart` File, and the AOT snapshot File (None when the
        target runs the tool from source instead).
    """
    use_snapshot = getattr(ctx.attr, "use_compile_wrapper", True)
    return struct(
        jit_tool = ctx.files._jit_tool,
        comma_patch = ctx.file._comma_patch,
        compile_wrapper = ctx.executable._compile_wrapper if use_snapshot else None,
    )

def jit_tool_entry(jit_tool_files):
    """The entry source of the JIT tool bundle.

    The `_jit_tool` attribute carries every source the tool imports, and the
    actions stage them all beside each other so the entry's relative imports
    resolve; the entry itself is picked by basename.

    Args:
        jit_tool_files: Every source file of the `_jit_tool` bundle, in the order the attribute lists them.

    Returns:
        The `app_jit_snapshot.dart` entry File.
    """
    for f in jit_tool_files:
        if f.basename == "app_jit_snapshot.dart":
            return f
    fail("dart_compile_action: the `_jit_tool` bundle names no `app_jit_snapshot.dart` entry")

def wrapper_launch(ctx, st, source_exe, aotruntime):
    """How a compile action starts the wrapper.

    With `st.compile_wrapper` the action runs the AOT snapshot under
    `aotruntime` and needs nothing else of the tool. Without it (the
    `jit-snapshot` mode, or a caller that passes no snapshot) the VM runs the
    tool from source: `source_exe` runs the entry beside the rest of the bundle
    under a package config, as before.

    Args:
        ctx: The rule context.
        st: The threaded compile struct (see `dart_compile_action`).
        source_exe: The VM File that runs the tool from source.
        aotruntime: The `dartaotruntime` File that runs the snapshot.

    Returns:
        `struct(executable, args, inputs)`: the action's executable, the `Args`
        holding what precedes the wrapper's own arguments, and the Files the
        launch adds to the action inputs.
    """
    args = ctx.actions.args()
    if st.compile_wrapper != None:
        args.add(st.compile_wrapper)
        return struct(executable = aotruntime, args = args, inputs = [st.compile_wrapper])
    packages = st.package_config
    if packages == None:
        packages = ctx.actions.declare_file(st.output.basename + ".aot_package_config.json")
        ctx.actions.write(output = packages, content = "{\"configVersion\": 2, \"packages\": []}\n")
    args.add(packages, format = "--packages=%s")
    args.add(jit_tool_entry(st.jit_tool))
    inputs = st.jit_tool + [packages, source_exe]
    if st.comma_patch != None:
        inputs.append(st.comma_patch)
    return struct(executable = source_exe, args = args, inputs = inputs)
