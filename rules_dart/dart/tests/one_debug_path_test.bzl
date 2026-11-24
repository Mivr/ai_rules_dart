"""Analysis tests: a kernel executable compiles kernel modules and links them, or fails naming why.

- a `dart_test` with code assets: its entry module embeds the native-assets
  mapping (`--native-assets`) and one link builds the kernel;
- a `dart_binary(compile_mode = "kernel")` with a `-D` in `dart_compile_flags`:
  modular, and the entry compiles with the define;
- the same binary with a front-end flag no module compile takes: the build
  fails at analysis, naming the target and the flag;
- a `dart_library` with `srcs_dir`: its module compile names the directory
  (`--source-dir`), whose files the compiler finds when it runs;
- a `dart_library` under an SDK without a module compiler: analysis fails,
  naming the version;
- a kernel executable whose `main` a library in its `deps` lists: the entry
  module names `main` by the library's `package:` URI and compiles no file of
  it, so the library's module is the one definition of `main`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//dart/..."])

def _mnemonics(env, mnemonic):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _entry(env):
    """The target's own `DartKernel` action, its entry module."""
    entries = [a for a in _mnemonics(env, "DartKernel") if "--no-drop" in a.argv]
    asserts.equals(env, 1, len(entries), "one entry module compile")
    return entries[0] if entries else None

def _code_asset_impl(ctx):
    env = analysistest.begin(ctx)
    entry = _entry(env)
    asserts.equals(env, 1, len(_mnemonics(env, "DartKernelLink")), "one DartKernelLink")
    if entry:
        asserts.true(env, "--native-assets" in entry.argv, "the entry embeds the mapping: %s" % entry.argv)
        yamls = [f for f in entry.inputs.to_list() if f.basename.endswith(".native_assets.yaml")]
        asserts.equals(env, 1, len(yamls), "the mapping is an input of the entry")
    return analysistest.end(env)

modular_code_asset_test = analysistest.make(_code_asset_impl)

def _define_flag_impl(ctx):
    env = analysistest.begin(ctx)
    entry = _entry(env)
    asserts.equals(env, 1, len(_mnemonics(env, "DartKernelLink")), "one DartKernelLink")
    if entry:
        asserts.true(env, ctx.attr.define in entry.argv, "the entry compiles with %s: %s" % (ctx.attr.define, entry.argv))
    return analysistest.end(env)

modular_define_flag_test = analysistest.make(_define_flag_impl, attrs = {"define": attr.string()})

def _entry_from_library_impl(ctx):
    env = analysistest.begin(ctx)
    entry = _entry(env)
    asserts.equals(env, 1, len(_mnemonics(env, "DartKernelLink")), "one DartKernelLink")
    if entry:
        argv = entry.argv
        i = argv.index("--source") if "--source" in argv else -1
        asserts.true(env, i >= 0 and argv[i + 1] == ctx.attr.uri, "the entry point is %s: %s" % (ctx.attr.uri, argv))
        asserts.false(
            env,
            any([f.short_path == ctx.attr.main for f in entry.inputs.to_list()]),
            "the entry does not read %s: the library's module compiles it" % ctx.attr.main,
        )
    return analysistest.end(env)

modular_entry_from_library_test = analysistest.make(
    _entry_from_library_impl,
    attrs = {"main": attr.string(), "uri": attr.string()},
)

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    for message in ctx.attr.messages:
        asserts.expect_failure(env, message)
    return analysistest.end(env)

refused_kernel_test = analysistest.make(
    _refused_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
)

refused_unpinned_sdk_test = analysistest.make(
    _refused_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
    config_settings = {
        "//command_line_option:extra_toolchains": [
            str(Label("//dart/tests:synthetic_no_compiler_exec_toolchain")),
            str(Label("//dart/tests:synthetic_no_compiler_target_toolchain")),
        ],
    },
)

def _source_dir_impl(ctx):
    env = analysistest.begin(ctx)
    kernels = _mnemonics(env, "DartKernel")
    asserts.equals(env, 1, len(kernels), "the library compiles one module")
    for action in kernels:
        argv = action.argv
        asserts.true(env, "--source-dir" in argv, "the module names its source directory: %s" % argv)
        i = argv.index("--source-dir") if "--source-dir" in argv else -1
        if i >= 0:
            asserts.equals(env, ctx.attr.uri, argv[i + 1])
            asserts.true(env, argv[i + 2].endswith("/lib"), "the directory is the package's lib/: %s" % argv[i + 2])
    return analysistest.end(env)

source_dir_module_test = analysistest.make(_source_dir_impl, attrs = {"uri": attr.string()})
