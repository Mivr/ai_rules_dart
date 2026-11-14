"""The `link_modules` opt-in of `dart_binary`: its attributes and its validation.

`exe` and `aot-snapshot` binaries compile from sources by default. A binary
that sets `link_modules` takes the linked per-library kernel path instead (see
`binary_compile.bzl`). Per-library modules compile against the JIT platform,
and a module compile has no AOT target at SDK 3.13.5, so the two paths agree
only for a closure that never asks the one `dart.library.*` key that differs
(`dart.library.mirrors`: true on the JIT VM, false in AOT).

This validation refuses such a closure: one action reads every `.dart` file of
the dependency closure, other repositories' packages included, and fails the
build when one imports `dart:mirrors`, names `dart.library.mirrors` as an
`if` configuration key, or passes it to `bool.fromEnvironment`. It sits in the
`_validation` output group and is no input of any compile action.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:common.bzl", "collect_transitive_srcs")
load("//dart/private:dart_kernel.bzl", "kernel_tools_for")

visibility(["//dart/..."])

LINK_CHECK_TOOL = Label("//dart/private/tools:link_check")

_LINKED_MODES = ("exe", "aot-snapshot")

def _link_check_for_binary(compile_mode, link_modules):
    """The computed default of `_link_check`: the tool, only for an opted-in binary.

    Resolving it for every binary would make the tool, itself a `dart_binary`,
    depend on itself.

    Args:
      compile_mode: The `dart_binary`'s `compile_mode`.
      link_modules: The `dart_binary`'s `link_modules`.

    Returns:
      The tool's label, or `None`.
    """
    if link_modules and compile_mode in _LINKED_MODES:
        return LINK_CHECK_TOOL
    return None

def _vm_product_for_binary(link_modules):
    """The computed default of `_vm_product`: the build setting, only for an opted-in binary.

    A label attribute on every binary would change the repo-mapping manifest
    action key of each one; only an opted-in binary reads the setting.

    Args:
      link_modules: The `dart_binary`'s `link_modules`.

    Returns:
      The setting's label, or `None`.
    """
    return Label("//dart/private:vm_product") if link_modules else None

LINK_MODULES_ATTRS = {
    "link_modules": attr.bool(
        default = False,
        doc = """Whether `compile_mode` `exe` and `aot-snapshot` link per-library kernel modules instead of compiling from sources. Off by default.

On, an eligible target (the rules of `modular_kernel`: no `defines`, `dart_compile_flags` or \
`code_assets`, no package split, not the `dbg` compilation mode, `dart.vm.product` true) \
compiles each library to a module, links them, and runs the whole-program steps over the \
linked kernel with no `.dart` source as an input: a body edit recompiles one module. An \
ineligible target silently takes the source path, as `kernel` mode does.

Modules compile against the JIT platform and a module compile has no AOT target at SDK \
3.13.5. Of every `dart.library.*` key, only `dart.library.mirrors` differs (true on the JIT \
VM, false in AOT), so a linked binary would answer it wrongly. Building an opted-in `exe` or \
`aot-snapshot` target therefore runs one validation action over every `.dart` file of the \
dependency closure, other repositories' packages included. It fails with one \
`<path>:<line>: <what>` line per `import` or `export` of `dart:mirrors`, per \
`dart.library.mirrors` key of an `if (...)` configuration, and per `bool.fromEnvironment` call \
naming it; comments are skipped. A name built at run time is out of reach. Unset \
`link_modules` to compile such a closure from sources.""",
    ),
    "_link_check": attr.label(
        doc = "The tool that refuses a `dart:mirrors` use in an opted-in binary's closure. See `link_check.dart`. Resolved only when `link_modules` is set.",
        default = _link_check_for_binary,
        executable = True,
        cfg = "exec",
    ),
    "_vm_product": attr.label(
        doc = "The `//dart/private:vm_product` build setting: an opted-in binary links modules only while it is `True`, the `dart.vm.product` value the modules compiled with. Resolved only when `link_modules` is set.",
        default = _vm_product_for_binary,
        providers = [BuildSettingInfo],
    ),
}

def link_check_args(ctx, label, srcs, stamp):
    """The command line of the check tool over [srcs].

    Args:
      ctx: The rule context.
      label: The target's label, as the check names it.
      srcs: A depset of the closure's source Files.
      stamp: The stamp File the tool writes when the closure is clean.

    Returns:
      An `Args` with a multiline param file.
    """
    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add("--label", label)
    args.add_all(srcs, before_each = "--src", map_each = _dart_source)
    args.add("--output", stamp)
    return args

def link_modules_check(ctx):
    """Declares the `link_modules` validation of a binary, when it has one.

    Args:
      ctx: The `dart_binary` rule context, with the exec tools toolchain.

    Returns:
      A depset of the stamp for the `_validation` output group; empty unless
      `link_modules` is set and `compile_mode` is `exe` or `aot-snapshot`.
    """
    if not ctx.attr.link_modules or ctx.attr.compile_mode not in _LINKED_MODES:
        return depset()
    tools = kernel_tools_for(ctx)
    if tools == None:
        fail("%s: `link_modules` needs the exec tools toolchain (%s) to run its dart:mirrors check." % (
            ctx.label,
            Label("//dart:exec_tools_toolchain_type"),
        ))
    tool = ctx.executable._link_check
    srcs = depset(
        direct = [ctx.file.main] + ctx.files.srcs,
        transitive = [collect_transitive_srcs(ctx.attr.deps)],
    )
    label = "//%s:%s" % (ctx.label.package, ctx.label.name)
    stamp = ctx.actions.declare_file(ctx.label.name + ".link_check")
    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [tool.path, link_check_args(ctx, label, srcs, stamp)],
        inputs = depset(direct = [tool], transitive = [srcs]),
        outputs = [stamp],
        mnemonic = "DartLinkCheck",
        progress_message = "Checking %s for dart:mirrors before linking its modules" % label,
        use_default_shell_env = False,
        toolchain = "//dart:exec_tools_toolchain_type",
    )
    return depset([stamp])

def _dart_source(f):
    """The path of a Dart source file or source directory, else nothing.

    Args:
      f: A `File` from the closure's sources: a Dart file or a source directory.

    Returns:
      The path, or `None` for a file that is not Dart source.
    """
    if f.extension == "dart" or f.is_directory:
        return f.path
    return None
