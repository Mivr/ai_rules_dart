"""The URI a native app's `main` is compiled under.

A `main` under its package's `lib/` has a `package:` URI that is the same in the
build's sandbox and the workspace. One outside it — `flutter run -t
test_driver/app.dart` — has no such URI, so it is named under the app scheme
instead. These tests pin the build's kernel compile.

The generated plugin registrant rides the same scheme, since a frontend_server
mounts one scheme at a time.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load(":action_content.bzl", "package_entry", "written_json")

visibility(["//flutter/tests/..."])

_PACKAGE = "ae_fixture"
_OUTSIDE_LIB_URI = "org-dartlang-app:///flutter/tests/web_fixture_main.dart"

def _kernel_action(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0] if kernels else None

def _flag_values(argv, flag):
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _assert_multi_root_and_package_config(env, action):
    """FlutterKernelCompile reads every input in place: generated roots, then the exec root.

    Sources and generated files are declared as themselves and read where they
    are. The output directories that hold the generated inputs are mounted
    first, so a generated file keeps precedence over a source at the same app
    path, then the exec root. No input is staged. Hermeticity rests on three
    layers rather than invisibility: the directive guard refuses disallowed
    directives before the compile, `kernel_filter` verifies the frontend's
    dependency report against the `--declared-inputs` manifest after it
    (failing closed on anything it cannot verify), and the sandbox — or
    remote execution — exposes only declared inputs.
    """
    argv = action.argv if action else []
    roots = _flag_values(argv, "--filesystem-root")
    input_paths = [f.path for f in action.inputs.to_list()] if action else []
    asserts.equals(env, [], [p for p in input_paths if ".stage/" in p], "no input is staged")
    generated_roots = {}
    for f in (action.inputs.to_list() if action else []):
        if not f.is_source and f.extension == "dart":
            generated_roots[f.root.path] = True
    asserts.equals(
        env,
        generated_roots.keys() + ["."],
        roots,
        "expected the generated inputs' output directories, then the exec root, got %r" % roots,
    )
    asserts.equals(env, ["org-dartlang-app"], _flag_values(argv, "--filesystem-scheme"))

    manifests = _flag_values(argv, "--declared-inputs")
    asserts.equals(env, 1, len(manifests), "expected --declared-inputs <manifest>, got %r" % argv)
    if action and len(manifests) == 1:
        input_paths = [f.path for f in action.inputs.to_list()]
        asserts.true(
            env,
            manifests[0] in input_paths,
            "the --declared-inputs manifest %r must be an action input" % manifests[0],
        )

    pkg_config = written_json(env, ".package_config.json")
    entry = package_entry(pkg_config, _PACKAGE)
    asserts.true(env, entry != None, "expected `%s` entry in .package_config.json" % _PACKAGE)
    if entry != None:
        asserts.equals(
            env,
            "org-dartlang-app:///flutter/tests",
            entry.get("rootUri"),
            "expected stable org-dartlang-app:/// rootUri",
        )

    copy_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartCopyTree"]
    asserts.equals(env, [], copy_actions, "FlutterKernelCompile must not emit DartCopyTree actions")

def _entry_module(env):
    """A debug app's entry module compile: the target's `DartKernel` action that may leave nothing out."""
    entries = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel" and "--no-drop" in a.argv]
    asserts.equals(env, 1, len(entries), "expected one entry module compile")
    return entries[0] if entries else None

def _outside_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _entry_module(env)
    argv = action.argv if action else []

    # The entry point. A `main` outside lib/ has no `package:` URI, so it
    # compiles under the app scheme by its workspace path.
    sources = _flag_values(argv, "--source")
    asserts.equals(env, _OUTSIDE_LIB_URI, sources[0] if sources else None)

    return analysistest.end(env)

def _in_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _entry_module(env)
    argv = action.argv if action else []
    sources = _flag_values(argv, "--source")
    asserts.equals(
        env,
        "package:%s/web_fixture_main.dart" % _PACKAGE,
        sources[0] if sources else None,
    )

    return analysistest.end(env)

def _opt_in_lib_test_impl(ctx):
    """Release builds read sources in place with only the exec root mounted."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []
    asserts.equals(
        env,
        "package:%s/web_fixture_main.dart" % _PACKAGE,
        argv[-1] if argv else None,
    )
    asserts.true(
        env,
        "--no-embed-source-text" in argv,
        "AOT FlutterKernelCompile must pass --no-embed-source-text, got %r" % argv,
    )
    _assert_multi_root_and_package_config(env, action)
    if action:
        asserts.equals(
            env,
            [],
            [f.path for f in action.inputs.to_list() if ".stage/" in f.path],
            "a compile with no generated inputs stages nothing",
        )
    return analysistest.end(env)

def _stale_bin_dir_seed_impl(ctx):
    """Materializes an invalid Dart file at `bazel-out/<cfg>/bin/flutter/tests/lib/web_fixture_main.dart` alongside a declared generated source."""
    stale_tmpl = ctx.actions.declare_file(ctx.label.name + "_stale.tmpl")
    ctx.actions.write(
        stale_tmpl,
        "THIS IS STALE GENERATED GARBAGE IN BAZEL-OUT THAT MUST NOT BE PICKED UP;\n",
    )
    seed_tmpl = ctx.actions.declare_file(ctx.label.name + "_seed.tmpl")
    ctx.actions.write(
        seed_tmpl,
        "const int staleProbeSeed = 1;\n",
    )

    # `stale_out` lands at `bazel-out/<cfg>/bin/flutter/tests/lib/web_fixture_main.dart`,
    # the exact bin_dir path corresponding to the source `lib/web_fixture_main.dart`.
    # Producing both outputs from one action guarantees `stale_out` exists on disk
    # in `bazel-out/<cfg>/bin` whenever a consumer builds `seed_out`, while only
    # `seed_out` is exposed in `DefaultInfo.files`.
    stale_out = ctx.actions.declare_file("lib/web_fixture_main.dart")
    seed_out = ctx.actions.declare_file("lib/stale_probe_seed.dart")
    ctx.actions.run_shell(
        command = 'cp "$1" "$2" && cp "$3" "$4"',
        toolchain = None,
        arguments = [stale_tmpl.path, stale_out.path, seed_tmpl.path, seed_out.path],
        inputs = [stale_tmpl, seed_tmpl],
        outputs = [stale_out, seed_out],
        mnemonic = "StaleBinDirSeed",
    )
    return [
        DefaultInfo(files = depset([seed_out])),
        OutputGroupInfo(stale = depset([stale_out])),
    ]

_stale_bin_dir_seed = rule(
    implementation = _stale_bin_dir_seed_impl,
)

def _other_cfg_transition_impl(settings, _attr):
    mode = settings["//command_line_option:compilation_mode"]
    return {
        "//command_line_option:compilation_mode": "dbg" if mode != "dbg" else "fastbuild",
    }

_other_cfg_transition = transition(
    implementation = _other_cfg_transition_impl,
    inputs = ["//command_line_option:compilation_mode"],
    outputs = ["//command_line_option:compilation_mode"],
)

def _transitioned_dart_src_impl(ctx):
    part_out = ctx.actions.declare_file("lib/transitioned_part.dart")
    ctx.actions.write(part_out, "const int transitionedValue = 7;\n")
    main_out = ctx.actions.declare_file("lib/transitioned_main.dart")
    ctx.actions.write(
        main_out,
        "import 'package:%s/transitioned_part.dart';\nvoid main() { if (transitionedValue != 7) throw StateError('bad'); }\n" % _PACKAGE,
    )
    return [DefaultInfo(files = depset([part_out, main_out]))]

_transitioned_dart_src = rule(
    implementation = _transitioned_dart_src_impl,
    cfg = _other_cfg_transition,
)

def _transitioned_main_only_impl(ctx):
    for f in ctx.files.src:
        if f.basename == "transitioned_main.dart":
            return [DefaultInfo(files = depset([f]))]
    fail("expected transitioned_main.dart")

_transitioned_main_only = rule(
    implementation = _transitioned_main_only_impl,
    attrs = {"src": attr.label(mandatory = True)},
)

def _declared_shadow_src_impl(ctx):
    # Generates `app_entrypoint_sibling.dart` at the same package-relative path
    # as the checked-in source `app_entrypoint_sibling.dart`, adding
    # `generatedShadowSymbol` which is absent from the source file.
    shadow_sibling = ctx.actions.declare_file("app_entrypoint_sibling.dart")
    ctx.actions.write(
        shadow_sibling,
        "const sibling = 'generated';\nconst int generatedShadowSymbol = 99;\n",
    )
    return [DefaultInfo(files = depset([shadow_sibling]))]

_declared_shadow_src = rule(
    implementation = _declared_shadow_src_impl,
)

def _shadow_consumer_main_impl(ctx):
    main_out = ctx.actions.declare_file("shadow_consumer_main.dart")
    ctx.actions.write(
        main_out,
        "import 'app_entrypoint_sibling.dart';\nvoid main() { if (generatedShadowSymbol != 99) throw StateError(sibling); }\n",
    )
    return [DefaultInfo(files = depset([main_out]))]

_shadow_consumer_main = rule(
    implementation = _shadow_consumer_main_impl,
)

def _stale_probe_analysis_test_impl(ctx):
    """Generated inputs and sources are read in place; undeclared bazel-out files stay out."""
    env = analysistest.begin(ctx)
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    if kernels:
        action = kernels[0]
        _assert_multi_root_and_package_config(env, action)
        input_paths = [f.path for f in action.inputs.to_list()]
        seed = [p for p in input_paths if p.endswith("/bin/flutter/tests/lib/stale_probe_seed.dart")]
        asserts.equals(
            env,
            1,
            len(seed),
            "expected the declared generated file as an input, read in place, got %r" % input_paths,
        )

        # The declared main is a source: it is an input exactly once, as
        # itself.
        unstaged_main = [p for p in input_paths if p.endswith("flutter/tests/lib/web_fixture_main.dart") and ".stage/" not in p and "/bin/" not in p]
        asserts.equals(
            env,
            ["flutter/tests/lib/web_fixture_main.dart"],
            unstaged_main,
            "expected the declared main as itself exactly once, got %r" % input_paths,
        )

        # The stale sibling in bazel-out is in no output group the compile
        # declares, so it is no input. The seed resolves the generated import
        # through its output directory, and the declared main resolves in
        # place through the mounted exec root — the
        # accompanying build test only passes when the main resolves to the
        # declared source. The stale file holds no valid Dart, and it is not
        # a declared input, so the sandbox exposes it nowhere; anywhere else
        # the dependency report would refuse the undeclared read.
        unstaged = [p for p in input_paths if p.endswith("bin/flutter/tests/lib/web_fixture_main.dart")]
        asserts.equals(
            env,
            [],
            unstaged,
            "undeclared stale file in bazel-out must not be an action input: %r" % unstaged,
        )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}

_outside_lib_test = analysistest.make(_outside_lib_test_impl, config_settings = _DBG)
_in_lib_test = analysistest.make(_in_lib_test_impl, config_settings = _DBG)
_opt_in_lib_test = analysistest.make(_opt_in_lib_test_impl, config_settings = _OPT)
_stale_probe_analysis_test = analysistest.make(_stale_probe_analysis_test_impl, config_settings = _OPT)

def app_entrypoint_test_suite(name):
    """Fixtures and tests for where a native app's `main` is compiled from.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_ae_outside_lib",
        srcs = [
            "app_entrypoint_sibling.dart",
            # Under `lib/`, so keyed by its `package:` URI and not listed.
            "lib/web_fixture_main.dart",
        ],
        package_name = _PACKAGE,
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_ae_in_lib",
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    _stale_bin_dir_seed(
        name = "_ae_stale_bin_dir_seed",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_stale_probe_aot",
        srcs = [":_ae_stale_bin_dir_seed"],
        aot = True,
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_stale_probe_modular",
        srcs = [":_ae_stale_bin_dir_seed"],
        aot = False,
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    _transitioned_dart_src(
        name = "_ae_transitioned_srcs",
        tags = ["manual"],
    )
    _transitioned_main_only(
        name = "_ae_transitioned_main",
        src = ":_ae_transitioned_srcs",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_transitioned_probe_aot",
        srcs = [":_ae_transitioned_srcs"],
        aot = True,
        package_name = _PACKAGE,
        main = ":_ae_transitioned_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_transitioned_probe_modular",
        srcs = [":_ae_transitioned_srcs"],
        aot = False,
        package_name = _PACKAGE,
        main = ":_ae_transitioned_main",
        tags = ["manual"],
    )
    _declared_shadow_src(
        name = "_ae_declared_shadow_src",
        tags = ["manual"],
    )
    _shadow_consumer_main(
        name = "_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_shadow_probe_aot",
        srcs = [
            "app_entrypoint_sibling.dart",
            ":_ae_declared_shadow_src",
        ],
        aot = True,
        package_name = _PACKAGE,
        main = ":_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_shadow_probe_modular",
        srcs = [
            "app_entrypoint_sibling.dart",
            ":_ae_declared_shadow_src",
        ],
        aot = False,
        package_name = _PACKAGE,
        main = ":_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    _outside_lib_test(
        name = name + "_outside_lib",
        target_under_test = ":_ae_outside_lib",
    )
    _in_lib_test(
        name = name + "_in_lib",
        target_under_test = ":_ae_in_lib",
    )
    _opt_in_lib_test(
        name = name + "_opt_in_lib",
        target_under_test = ":_ae_in_lib",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _stale_probe_analysis_test(
        name = name + "_stale_probe_analysis",
        target_under_test = ":_ae_stale_probe_aot",
        target_compatible_with = HOST_COMPATIBLE,
    )
    build_test(
        name = name + "_stale_generated_build_test",
        targets = [
            ":_ae_stale_probe_aot",
            ":_ae_stale_probe_modular",
            ":_ae_transitioned_probe_aot",
            ":_ae_transitioned_probe_modular",
            ":_ae_shadow_probe_aot",
            ":_ae_shadow_probe_modular",
        ],
        target_compatible_with = HOST_COMPATIBLE,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_outside_lib",
            ":" + name + "_in_lib",
            ":" + name + "_opt_in_lib",
            ":" + name + "_stale_probe_analysis",
            ":" + name + "_stale_generated_build_test",
        ],
    )
