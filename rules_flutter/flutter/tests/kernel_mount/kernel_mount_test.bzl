"""Analysis tests for the whole-program kernel mount.

Every `flutter_kernel_compile_action` — `flutter_test` fallbacks, app
kernels, integration tests, the public API — stages only its generated inputs
and mounts that stage before the exec root, so each source is declared once
and an extra consumer over the same closure adds symlinks only for its own
generated files. These tests pin that shape: single declaration with a
generated-only stage, no per-dependency symlinks across two compiles, and
stage-before-exec-root ordering so a generated file keeps precedence.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load("//flutter:utils.bzl", "FLUTTER_KERNEL_COMPILE_ATTRS", "FLUTTER_KERNEL_COMPILE_TOOLCHAINS", "compile_package_config", "flutter_kernel_compile_action", "flutter_kernel_compile_tools", "flutter_kernel_dills", "flutter_kernel_options", "flutter_kernel_outputs", "flutter_kernel_sources")

visibility(["//flutter/tests/..."])

def _mount_closure(ctx, extra_mains):
    """The compile closure: own `srcs`, transitive `deps` sources, and `extra_mains`."""
    return list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + extra_mains

def _emit_mount_kernel(ctx, kit, packaged, main, dill_name):
    """Declares one kernel dill compiled from `main` over the packaged closure."""
    dill = ctx.actions.declare_file(dill_name)
    flutter_kernel_compile_action(
        ctx,
        kit,
        flutter_kernel_sources(main = main, srcs = packaged.srcs, package_config = packaged.config_file),
        flutter_kernel_outputs(output = dill),
        flutter_kernel_options(),
        flutter_kernel_dills(),
    )
    return dill

def _mount_one_impl(ctx):
    """Compiles a single kernel from `main` over `srcs` plus `deps`."""
    packaged = compile_package_config(
        ctx,
        collect_packages(ctx.attr.deps),
        _mount_closure(ctx, [ctx.file.main]),
    )
    dill = _emit_mount_kernel(
        ctx,
        flutter_kernel_compile_tools(ctx),
        packaged,
        ctx.file.main,
        ctx.label.name + ".dill",
    )
    return [DefaultInfo(files = depset([dill]))]

_mount_one = rule(
    implementation = _mount_one_impl,
    doc = "Compiles one whole-program kernel, for the kernel-mount tests.",
    attrs = {
        "main": attr.label(
            doc = "The entrypoint Dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Own Dart sources, including generated ones.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo libraries in the compile closure.",
            providers = [DartInfo],
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def _mount_two_impl(ctx):
    """Compiles two kernels over one shared closure of `srcs` plus `deps`."""
    packaged = compile_package_config(
        ctx,
        collect_packages(ctx.attr.deps),
        _mount_closure(ctx, [ctx.file.main_a, ctx.file.main_b]),
    )
    kit = flutter_kernel_compile_tools(ctx)
    dills = [
        _emit_mount_kernel(ctx, kit, packaged, entry, ctx.label.name + "_" + stem + ".dill")
        for stem, entry in [("a", ctx.file.main_a), ("b", ctx.file.main_b)]
    ]
    return [DefaultInfo(files = depset(dills))]

_mount_two = rule(
    implementation = _mount_two_impl,
    doc = "Compiles two whole-program kernels over one closure, for the kernel-mount tests.",
    attrs = {
        "main_a": attr.label(
            doc = "The first entrypoint Dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "main_b": attr.label(
            doc = "The second entrypoint Dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Own Dart sources, including generated ones.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo libraries in the compile closure.",
            providers = [DartInfo],
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def _kernel_compiles(env):
    """Every `FlutterKernelCompile` action of the target under test."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]

def _input_paths(action):
    """The exec-root-relative input paths of `action`."""
    return [f.path for f in action.inputs.to_list()]

def _mounted_roots(argv):
    """The `--filesystem-root` values of a kernel compile argv."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--filesystem-root"]

def _declared_once_test_impl(ctx):
    """Each source is declared exactly once; the stage holds only the generated file."""
    env = analysistest.begin(ctx)
    compiles = _kernel_compiles(env)
    asserts.equals(env, 1, len(compiles), "expected one FlutterKernelCompile, got %d" % len(compiles))
    if len(compiles) == 1:
        paths = _input_paths(compiles[0])
        for name in ctx.attr.source_names:
            hits = [p for p in paths if p.endswith("/" + name)]
            asserts.equals(env, 1, len(hits), "source %s must be declared exactly once, got %r" % (name, hits))
        staged = [p for p in paths if ".stage/" in p]
        asserts.true(env, len(staged) > 0, "expected staged symlinks for the generated file")
        for p in staged:
            asserts.true(env, p.endswith("/" + ctx.attr.generated_name), "the stage holds only the generated file, got %s" % p)
    return analysistest.end(env)

def _shared_closure_test_impl(ctx):
    """Two compiles over one closure stage no symlink per dependency source."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(
        env,
        2,
        len([a for a in actions if a.mnemonic == "FlutterKernelCompile"]),
        "expected two FlutterKernelCompile actions",
    )
    staged = [f.path for a in actions if a.mnemonic == "Symlink" for f in a.outputs.to_list()]
    for name in ctx.attr.source_names:
        asserts.equals(
            env,
            [],
            [p for p in staged if p.endswith("/" + name)],
            "no symlink may stage dependency source %s" % name,
        )
    asserts.equals(env, 2, len(staged), "each compile stages only the shared generated file, got %r" % (staged,))
    for p in staged:
        asserts.true(env, p.endswith("/" + ctx.attr.generated_name), "the stages hold only the generated file, got %s" % p)
    return analysistest.end(env)

def _precedence_test_impl(ctx):
    """The generated-only stage mounts before the exec root."""
    env = analysistest.begin(ctx)
    compiles = _kernel_compiles(env)
    asserts.equals(env, 1, len(compiles), "expected one FlutterKernelCompile, got %d" % len(compiles))
    if len(compiles) == 1:
        roots = _mounted_roots(compiles[0].argv)
        asserts.true(env, len(roots) >= 2, "expected the stage plus the exec root, got %r" % (roots,))
        if len(roots) >= 2:
            asserts.true(env, roots[0].endswith(".stage"), "the generated-only stage mounts first, got %r" % (roots,))
            asserts.true(env, "." in roots[1:], "the exec root mounts after the stage, got %r" % (roots,))
    return analysistest.end(env)

_declared_once_test = analysistest.make(
    _declared_once_test_impl,
    attrs = {
        "source_names": attr.string_list(
            doc = "Source basenames each declared exactly once.",
        ),
        "generated_name": attr.string(
            doc = "Generated basename staged alone.",
        ),
    },
)
_shared_closure_test = analysistest.make(
    _shared_closure_test_impl,
    attrs = {
        "source_names": attr.string_list(
            doc = "Source basenames with no staging symlink.",
        ),
        "generated_name": attr.string(
            doc = "Generated basename staged once per compile.",
        ),
    },
)
_precedence_test = analysistest.make(_precedence_test_impl)

def kernel_mount_test_suite(name):
    """Declares the kernel-mount fixtures and analysis tests.

    Args:
        name: The test_suite target name.
    """
    dart_library(
        name = "_mount_dep",
        package_name = "mount_dep",
        srcs = ["lib/mount_dep_a.dart", "lib/mount_dep_b.dart"],
        tags = ["manual"],
    )
    native.genrule(
        name = "_mount_gen",
        outs = ["mount_gen.dart"],
        cmd = "echo 'int get generated => 7;' > $@",
        tags = ["manual"],
    )
    _mount_one(
        name = "_mount_single",
        main = "lib/mount_single_main.dart",
        srcs = ["lib/mount_own_a.dart", "lib/mount_own_b.dart", ":_mount_gen"],
        deps = [":_mount_dep"],
        tags = ["manual"],
    )
    _mount_two(
        name = "_mount_pair",
        main_a = "lib/mount_pair_a.dart",
        main_b = "lib/mount_pair_b.dart",
        srcs = ["lib/mount_own_a.dart", "lib/mount_own_b.dart", ":_mount_gen"],
        deps = [":_mount_dep"],
        tags = ["manual"],
    )

    _declared_once_test(
        name = name + "_declared_once",
        target_under_test = ":_mount_single",
        source_names = [
            "mount_single_main.dart",
            "mount_own_a.dart",
            "mount_own_b.dart",
            "mount_dep_a.dart",
            "mount_dep_b.dart",
        ],
        generated_name = "mount_gen.dart",
    )
    _shared_closure_test(
        name = name + "_shared_closure",
        target_under_test = ":_mount_pair",
        source_names = [
            "mount_pair_a.dart",
            "mount_pair_b.dart",
            "mount_own_a.dart",
            "mount_own_b.dart",
            "mount_dep_a.dart",
            "mount_dep_b.dart",
        ],
        generated_name = "mount_gen.dart",
    )
    _precedence_test(
        name = name + "_precedence",
        target_under_test = ":_mount_single",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_declared_once",
            ":" + name + "_shared_closure",
            ":" + name + "_precedence",
        ],
    )
