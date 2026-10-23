"""Unit tests for the pure decisions of modular kernel compilation.

`dart/private/dart_kernel.bzl` decides, without building anything, the URI each
source is compiled under, the package config a module names its packages with,
and whether an executable may compile modularly at all. Each of those is a
function of plain values, so each is tested here by calling it. The actions that
use them are exercised by the rules' own test targets.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_binary")
load("//dart:providers.bzl", "DartKernelInfo")
load(
    "//dart:utils.bzl",
    "STABLE_SCHEME",
    "dart_kernel_module_aspect",
    "duplicated_source",
    "entry_source_uri",
    "entry_sources",
    "first_per_package",
    "generate_stable_package_config",
    "has_cross_pkg_cycle",
    "kernel_compile_settings",
    "kernel_link_action",
    "kernel_module_action",
    "kernel_module_inputs",
    "kernel_module_options",
    "kernel_module_outputs",
    "kernel_package_config",
    "kernel_packages_consistent",
    "library_source_uri",
    "modular_executable_kernel",
    "modular_kernel_conditions",
    "modular_kernel_eligible",
    "modular_kernel_mode",
    "multi_root_uri",
    "no_kernel_module",
    "package_of_source",
    "stable_entry_path",
    "stable_path",
)
load("//dart/private:dart_test_runner.bzl", "dart_test_runner_main")
load(":pruned_inputs.bzl", "pruned_inputs_settings")
load(":small_suite.bzl", "small_unittest_suite")

def _pkg(package_name, lib_root, language_version = ""):
    """A stand-in for `DartPackageInfo`, carrying the fields these functions read."""
    return struct(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
    )

def _root_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg/a", stable_path("pkg/a"), "a main-repo path is unchanged")
    asserts.equals(env, "external/repo", stable_path("../repo"), "an external repo maps under external/")
    asserts.equals(env, "external/repo/sub", stable_path("../repo/sub"), "an external sub-package maps under external/")
    asserts.equals(env, "", stable_path(""), "the root package stays empty")
    return unittest.end(env)

def _multi_root_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "org-dartlang-root:///pkg/a",
        multi_root_uri("pkg/a"),
        "a main-repo package root",
    )
    asserts.equals(
        env,
        "org-dartlang-root:///",
        multi_root_uri(""),
        "the root package is the bare scheme root",
    )
    asserts.equals(
        env,
        "org-dartlang-root:///external/repo",
        multi_root_uri("../repo"),
        "an external package root",
    )
    asserts.equals(
        env,
        "org-dartlang-root:///external/repo/sub",
        multi_root_uri("../repo/sub"),
        "an external sub-package root",
    )
    return unittest.end(env)

def _multi_root_uri_custom_scheme_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "org-dartlang-root", STABLE_SCHEME)
    asserts.equals(
        env,
        "org-dartlang-app:///pkg/a",
        multi_root_uri("pkg/a", scheme = "org-dartlang-app"),
        "a main-repo package root under a custom scheme",
    )
    asserts.equals(
        env,
        "org-dartlang-app:///",
        multi_root_uri("", scheme = "org-dartlang-app"),
        "the root package under a custom scheme",
    )
    asserts.equals(
        env,
        "org-dartlang-app:///external/repo/sub",
        multi_root_uri("../repo/sub", scheme = "org-dartlang-app"),
        "an external sub-package root under a custom scheme",
    )
    return unittest.end(env)

def _entry_source_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "org-dartlang-root:///pkg/test/x_test.dart",
        entry_source_uri("pkg/test/x_test.dart"),
        "a test in the main repo",
    )
    asserts.equals(
        env,
        "org-dartlang-root:///pkg/x.vm_test.dart",
        entry_source_uri("pkg/x.vm_test.dart"),
        "a generated bootstrap, which sits beside the test in the output tree",
    )
    asserts.equals(
        env,
        "org-dartlang-root:///external/repo/test/x_test.dart",
        entry_source_uri("../repo/test/x_test.dart"),
        "a test from an external repo",
    )
    return unittest.end(env)

def _entry_source_uri_custom_scheme_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "org-dartlang-app:///pkg/test/x_test.dart",
        entry_source_uri("pkg/test/x_test.dart", scheme = "org-dartlang-app"),
        "a test in the main repo under a custom scheme",
    )
    asserts.equals(
        env,
        "org-dartlang-app:///external/repo/test/x_test.dart",
        entry_source_uri("../repo/test/x_test.dart", scheme = "org-dartlang-app"),
        "an external test under a custom scheme",
    )
    fake_file = struct(short_path = "../repo/test/x_test.dart", path = "external/repo/test/x_test.dart")
    fake_ctx = struct(bin_dir = struct(path = "bazel-out/k8-fastbuild/bin"))
    asserts.equals(
        env,
        "pkg/x.vm_test.dart",
        stable_entry_path(fake_ctx, "bazel-out/k8-fastbuild/bin/pkg/x.vm_test.dart"),
        "stable_entry_path strips bin_dir prefix",
    )
    entries = entry_sources([fake_file], scheme = "org-dartlang-app")
    asserts.equals(env, 1, len(entries))
    asserts.equals(env, "org-dartlang-app:///external/repo/test/x_test.dart", entries[0].uri)
    asserts.equals(env, fake_file, entries[0].file)
    return unittest.end(env)

def _library_source_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:a/src/x.dart",
        library_source_uri("a", "pkg/a", "pkg/a/lib/src/x.dart"),
        "a file under a package's lib/ is named by its package: path",
    )
    asserts.equals(
        env,
        "package:a/x.dart",
        library_source_uri("a", "", "lib/x.dart"),
        "the root package strips lib/ alone",
    )
    asserts.equals(
        env,
        "package:a/x.dart",
        library_source_uri("a", "../repo", "../repo/lib/x.dart"),
        "an external package strips its lib_root and lib/",
    )
    return unittest.end(env)

def _package_config_test_impl(ctx):
    env = unittest.begin(ctx)
    config = kernel_package_config([
        _pkg("a", "pkg/a", "3.9"),
        _pkg("root", ""),
        _pkg("ext", "../repo/sub"),
    ])
    expected = (
        "{\n" +
        '  "configVersion": 2,\n' +
        '  "packages": [\n' +
        '    {"name": "a", "rootUri": "org-dartlang-root:///pkg/a", "packageUri": "lib/", "languageVersion": "3.9"},\n' +
        '    {"name": "root", "rootUri": "org-dartlang-root:///", "packageUri": "lib/"},\n' +
        '    {"name": "ext", "rootUri": "org-dartlang-root:///external/repo/sub", "packageUri": "lib/"}\n' +
        "  ]\n" +
        "}\n"
    )
    asserts.equals(env, expected, config, "one entry per package, with its multi-root rootUri")
    return unittest.end(env)

def _package_config_custom_scheme_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        _pkg("a", "pkg/a", "3.9"),
        _pkg("root", ""),
        _pkg("ext", "../repo/sub"),
    ]
    config = kernel_package_config(pkgs, scheme = "org-dartlang-app")
    expected = (
        "{\n" +
        '  "configVersion": 2,\n' +
        '  "packages": [\n' +
        '    {"name": "a", "rootUri": "org-dartlang-app:///pkg/a", "packageUri": "lib/", "languageVersion": "3.9"},\n' +
        '    {"name": "root", "rootUri": "org-dartlang-app:///", "packageUri": "lib/"},\n' +
        '    {"name": "ext", "rootUri": "org-dartlang-app:///external/repo/sub", "packageUri": "lib/"}\n' +
        "  ]\n" +
        "}\n"
    )
    asserts.equals(env, expected, config, "kernel_package_config uses the custom scheme")

    stable_cfg = generate_stable_package_config(
        pkgs,
        [],
        roots = {"a": "pkg/a", "ext": "external/repo/sub"},
        scheme = "org-dartlang-app",
    )
    asserts.equals(env, expected, stable_cfg, "generate_stable_package_config uses the custom scheme")
    return unittest.end(env)

def _packages_consistent_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(
        env,
        kernel_packages_consistent([_pkg("a", "pkg/a"), _pkg("a", "pkg/a"), _pkg("b", "pkg/b")]),
        "a name repeated at one root is one package",
    )
    asserts.false(
        env,
        kernel_packages_consistent([_pkg("a", "pkg/a"), _pkg("a", "other/a")]),
        "a name at two roots cannot be one rootUri",
    )
    asserts.false(
        env,
        kernel_packages_consistent([_pkg("a", ""), _pkg("b", "")]),
        "two root packages would share the bare scheme root",
    )
    asserts.true(
        env,
        kernel_packages_consistent([_pkg("a", ""), _pkg("b", "pkg/b")]),
        "one root package beside others is fine",
    )
    return unittest.end(env)

def _first_per_package_test_impl(ctx):
    env = unittest.begin(ctx)
    kept = first_per_package([_pkg("a", "pkg/a", "3.9"), _pkg("b", "pkg/b"), _pkg("a", "pkg/a", "")])
    asserts.equals(env, ["a", "b"], [p.package_name for p in kept], "one record per name, in order")
    asserts.equals(env, "3.9", kept[0].language_version, "the first record wins")
    return unittest.end(env)

def _duplicated_source_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        duplicated_source([], [], []),
        "nothing to repeat",
    )
    asserts.equals(
        env,
        None,
        duplicated_source(["t.dart"], [("//x:a", "a.dart"), ("//x:b", "b.dart")], []),
        "distinct sources",
    )
    asserts.equals(
        env,
        "a.dart",
        duplicated_source(["a.dart"], [("//x:a", "a.dart")], []),
        "the executable's own source is also a library's",
    )
    asserts.equals(
        env,
        None,
        duplicated_source([], [("//x:a", "a.dart"), ("//x:a", "a.dart")], []),
        "one library reached by two paths is one library",
    )
    asserts.equals(
        env,
        None,
        duplicated_source(
            [],
            [("//x:base", "s.dart"), ("//x:top", "s.dart")],
            [("//x:top", "//x:base")],
        ),
        "a library and a dependency that both list the source",
    )
    asserts.equals(
        env,
        None,
        duplicated_source(
            [],
            [("//x:a", "s.dart"), ("//x:b", "s.dart"), ("//x:c", "s.dart")],
            [("//x:b", "//x:a"), ("//x:c", "//x:b")],
        ),
        "a chain of libraries, each depending on the last",
    )
    asserts.equals(
        env,
        "s.dart",
        duplicated_source(
            [],
            [("//x:a", "s.dart"), ("//x:b", "s.dart")],
            [],
        ),
        "two libraries with no dependency between them",
    )
    asserts.equals(
        env,
        "s.dart",
        duplicated_source(
            [],
            [("//x:left", "s.dart"), ("//x:right", "s.dart"), ("//x:base", "b.dart")],
            [("//x:left", "//x:base"), ("//x:right", "//x:base")],
        ),
        "two siblings that share a dependency are still unrelated",
    )
    asserts.equals(
        env,
        None,
        duplicated_source(
            [],
            [("//x:a", "s.dart"), ("//x:b", "s.dart"), ("//x:c", "other.dart")],
            [("//x:b", "//x:a"), ("//x:c", "//x:a")],
        ),
        "a source shared by a dependent and its dependency alone",
    )
    return unittest.end(env)

def _conditions(
        mode = None,
        dep_modular = True,
        packages_consistent = True,
        has_code_assets = False,
        has_own_defines = False,
        has_compile_flags = False,
        has_duplicate_source = False,
        same_sdk = True):
    """The all-eligible `modular_kernel_conditions`, with per-fact overrides."""
    return modular_kernel_conditions(
        mode if mode != None else modular_kernel_mode(True, True),
        dep_modular,
        packages_consistent,
        has_code_assets,
        has_own_defines,
        has_compile_flags,
        has_duplicate_source,
        same_sdk,
    )

def _eligible_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, modular_kernel_eligible(_conditions()), "every condition met")

    # Each override is a reason to fall back to whole-program compilation.
    fallbacks = {
        "flag is off": _conditions(mode = modular_kernel_mode(False, True)),
        "not a kernel": _conditions(mode = modular_kernel_mode(True, False)),
        "a dependency is not modular": _conditions(dep_modular = False),
        "the closure has a package at two roots": _conditions(packages_consistent = False),
        "code assets are embedded": _conditions(has_code_assets = True),
        "the test sets its own `defines`": _conditions(has_own_defines = True),
        "dart_compile_flags are set": _conditions(has_compile_flags = True),
        "a source is compiled twice": _conditions(has_duplicate_source = True),
        "the exec and target SDKs differ": _conditions(same_sdk = False),
    }
    for reason, conditions in fallbacks.items():
        asserts.false(env, modular_kernel_eligible(conditions), reason)
    return unittest.end(env)

def _custom_kernel_module_fixture_impl(ctx):
    dartaotruntime = ctx.actions.declare_file(ctx.label.name + "_dartaotruntime")
    kernel_worker = ctx.actions.declare_file(ctx.label.name + "_kernel_worker.snapshot")
    patched_kernel_worker = ctx.actions.declare_file(ctx.label.name + "_kernel_worker_nocomma.snapshot")
    default_platform_dill = ctx.actions.declare_file(ctx.label.name + "_vm_platform_strong.dill")
    default_libraries_json = ctx.actions.declare_file(ctx.label.name + "_default_libraries.json")
    custom_platform_dill = ctx.actions.declare_file(ctx.label.name + "_flutter_platform_strong.dill")
    custom_libraries_json = ctx.actions.declare_file(ctx.label.name + "_flutter_libraries.json")
    src_file = ctx.actions.declare_file(ctx.label.name + "_widget.dart")
    for f in [
        dartaotruntime,
        kernel_worker,
        patched_kernel_worker,
        default_platform_dill,
        default_libraries_json,
        custom_platform_dill,
        custom_libraries_json,
        src_file,
    ]:
        ctx.actions.write(output = f, content = "")

    tools = struct(
        dartaotruntime = dartaotruntime,
        kernel_worker = kernel_worker,
        platform_dill = default_platform_dill,
        libraries_json = default_libraries_json,
        version = "3.11.0",
        patched_kernel_worker = patched_kernel_worker,
    )
    kmod = ctx.actions.declare_directory(ctx.label.name + ".kmod")
    koutline = ctx.actions.declare_directory(ctx.label.name + ".koutline")
    excluded = kernel_module_action(
        ctx = ctx,
        tools = tools,
        inputs = kernel_module_inputs(
            sources = [struct(uri = "package:a/widget.dart", file = src_file)],
            packages = [_pkg("a", "pkg/a", "3.9")],
            dep_kmods = depset(order = "postorder"),
        ),
        outputs = kernel_module_outputs(output = kmod, koutline = koutline),
        options = kernel_module_options(
            defines = ["FLUTTER_WEB=false", "COMMA_VAL=a,b"],
            exclude_non_sources = True,
            droppable = True,
        ),
        compile = kernel_compile_settings(
            target = "flutter",
            platform_dill = custom_platform_dill,
            libraries_json = custom_libraries_json,
            libraries_platform = "flutter",
            extra_libraries = ["ui", "nativewrappers"],
            scheme = "org-dartlang-app",
            extra_frontend_flags = ["--track-widget-creation"],
        ),
    )
    linked_dill = ctx.actions.declare_file(ctx.label.name + "_linked.dill")
    kernel_link_action(
        ctx = ctx,
        dep_kmods = depset(order = "postorder"),
        entry = kmod,
        output = linked_dill,
        platform_dill = custom_platform_dill,
    )
    info = no_kernel_module()
    return [
        DefaultInfo(files = depset([kmod, koutline, excluded, linked_dill])),
        DartKernelInfo(
            kmod = kmod,
            koutline = koutline,
            transitive_kmods = info.transitive_kmods,
            transitive_koutlines = info.transitive_koutlines,
            modular = True,
            closure_excluded = depset([excluded]),
            cross_pkg_srcs = info.cross_pkg_srcs,
            owned = info.owned,
            edges = info.edges,
            base_dill = info.base_dill,
            base_keys = info.base_keys,
            base_kmods = info.base_kmods,
            unseeded_base_kmods = info.unseeded_base_kmods,
        ),
    ]

_custom_kernel_module_fixture = rule(
    implementation = _custom_kernel_module_fixture_impl,
    attrs = {
        "_kernel_module": attr.label(
            default = Label("//dart:kernel_module"),
            executable = True,
            cfg = "exec",
        ),
        "_kernel_link": attr.label(
            default = Label("//dart:kernel_link"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _kernel_module_action_custom_params_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, DartKernelInfo in target, "fixture provides Public DartKernelInfo")
    asserts.true(env, target[DartKernelInfo].modular)

    actions = analysistest.target_actions(env)
    pkg_cfg_writes = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(".package_config.json")
    ]
    asserts.equals(env, 1, len(pkg_cfg_writes), "writes one package_config.json")
    asserts.true(
        env,
        "org-dartlang-app:///pkg/a" in pkg_cfg_writes[0].content,
        "package_config.json uses the custom scheme",
    )

    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "registers one DartKernel action")
    kernel_action = kernel_actions[0]
    argv = kernel_action.argv

    asserts.true(env, "--target" in argv and "flutter" in argv, "--target flutter passed")
    asserts.true(
        env,
        "--libraries-platform" in argv and "flutter" in argv,
        "--libraries-platform flutter passed",
    )
    asserts.true(
        env,
        "--extra-library" in argv and "ui" in argv and "nativewrappers" in argv,
        "--extra-library flags passed",
    )
    asserts.true(
        env,
        "--multi-root-scheme" in argv and "org-dartlang-app" in argv,
        "--multi-root-scheme org-dartlang-app passed",
    )
    multi_roots = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--multi-root"]
    asserts.equals(env, 2, len(multi_roots), "two --multi-root flags passed")
    asserts.equals(env, ".", multi_roots[0], "first --multi-root is '.' so stale generated files do not shadow source files")
    asserts.true(env, multi_roots[1].endswith("/bin"), "second --multi-root is ctx.bin_dir.path")
    asserts.true(
        env,
        "--track-widget-creation" in argv,
        "extra_frontend_flags forwarded",
    )
    asserts.true(
        env,
        "--output-outline" in argv,
        "--output-outline passed when koutline is given",
    )
    asserts.true(
        env,
        "-DFLUTTER_WEB=false" in argv,
        "non-comma define is forwarded to kernel_module",
    )
    asserts.true(
        env,
        "-DCOMMA_VAL=a,b" in argv,
        "comma-containing define is forwarded to kernel_module",
    )
    asserts.true(
        env,
        "--comma-patched-snapshot" in argv,
        "comma defines pass the patched-snapshot marker as a startup argument",
    )
    snapshot_argv = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--kernel-worker"]
    asserts.equals(env, 1, len(snapshot_argv), "one --kernel-worker startup argument")
    asserts.true(
        env,
        snapshot_argv[0].endswith("_kernel_worker_nocomma.snapshot"),
        "comma defines run the patched worker snapshot, not the pristine one: %s" % snapshot_argv,
    )
    kernel_input_basenames = [f.basename for f in kernel_action.inputs.to_list()]
    asserts.true(
        env,
        any([b.endswith("_kernel_worker_nocomma.snapshot") for b in kernel_input_basenames]),
        "the patched worker snapshot is an action input: %s" % kernel_input_basenames,
    )

    input_basenames = [f.basename for f in kernel_action.inputs.to_list()]
    asserts.true(
        env,
        any([b.endswith("_flutter_platform_strong.dill") for b in input_basenames]),
        "custom platform_dill is in action inputs",
    )
    asserts.false(
        env,
        any([b.endswith("_vm_platform_strong.dill") for b in input_basenames]),
        "default platform_dill is replaced when custom platform_dill is given",
    )
    asserts.true(
        env,
        any([b.endswith("_flutter_libraries.json") for b in input_basenames]),
        "custom libraries_json is in action inputs",
    )
    asserts.false(
        env,
        any([b.endswith("_default_libraries.json") for b in input_basenames]),
        "default libraries_json is replaced when custom libraries_json is given",
    )

    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(link_actions), "registers one DartKernelLink action")
    link_action = link_actions[0]
    asserts.true(
        env,
        "--platform" in link_action.argv,
        "--platform passed to DartKernelLink when platform_dill is provided",
    )
    link_input_basenames = [f.basename for f in link_action.inputs.to_list()]
    asserts.true(
        env,
        any([b.endswith("_flutter_platform_strong.dill") for b in link_input_basenames]),
        "platform_dill is included in DartKernelLink inputs",
    )
    return analysistest.end(env)

_kernel_module_action_custom_params_test = analysistest.make(
    _kernel_module_action_custom_params_test_impl,
    config_settings = pruned_inputs_settings(),
)

def _dummy_dart_source_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.write(output = out, content = "void main() {}\n")
    return [DefaultInfo(files = depset([out]))]

_dummy_dart_source = rule(
    implementation = _dummy_dart_source_impl,
)

def _modular_kernel_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "modular kernel binary registers one DartKernel entry action")
    kernel_out_basenames = [f.basename for f in kernel_actions[0].outputs.to_list()]
    asserts.true(
        env,
        target.label.name + ".entry.kmod" in kernel_out_basenames,
        "DartKernel action produces <name>.entry.kmod",
    )
    asserts.true(
        env,
        "-Ddart.vm.product=true" in kernel_actions[0].argv,
        "modular DartKernel entry action passes -Ddart.vm.product=true",
    )
    asserts.true(
        env,
        "org-dartlang-root" in kernel_actions[0].argv,
        "modular DartKernel entry action uses org-dartlang-root scheme",
    )
    mod_argv = kernel_actions[0].argv
    mod_roots = [mod_argv[i + 1] for i in range(len(mod_argv) - 1) if mod_argv[i] == "--multi-root"]
    asserts.equals(env, 2, len(mod_roots), "modular DartKernel entry action passes two --multi-root flags")
    asserts.equals(env, ".", mod_roots[0], "modular DartKernel entry action passes '.' before bin_dir")
    asserts.true(env, mod_roots[1].endswith("/bin"), "modular DartKernel entry action passes bin_dir second")

    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(link_actions), "modular kernel binary registers one DartKernelLink action")
    link_out_basenames = [f.basename for f in link_actions[0].outputs.to_list()]
    asserts.true(
        env,
        target.label.name + ".dill" in link_out_basenames,
        "DartKernelLink action produces <name>.dill",
    )

    compile_actions = [a for a in actions if a.mnemonic == "DartCompile"]
    asserts.equals(env, 0, len(compile_actions), "modular kernel binary registers no whole-program DartCompile action")
    return analysistest.end(env) + [
        OutputGroupInfo(
            _validation = target[DefaultInfo].files,
            dart_analyze = target[DefaultInfo].files,
        ),
    ]

_modular_kernel_binary_test = analysistest.make(_modular_kernel_binary_test_impl)

def _non_modular_kernel_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 0, len(link_actions), "modular_kernel = False binary registers no DartKernelLink action")
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "modular_kernel = False binary runs one whole-program DartKernel action")
    kernel_out_basenames = [f.basename for f in kernel_actions[0].outputs.to_list()]
    asserts.equals(
        env,
        [target.label.name + ".dill"],
        kernel_out_basenames,
        "whole-program DartKernel produces <name>.dill directly without .entry.kmod",
    )
    asserts.true(
        env,
        "-Ddart.vm.product=true" in kernel_actions[0].argv,
        "whole-program DartKernel action passes -Ddart.vm.product=true",
    )
    asserts.true(
        env,
        "org-dartlang-root" in kernel_actions[0].argv,
        "whole-program DartKernel action uses org-dartlang-root scheme",
    )
    whole_argv = kernel_actions[0].argv
    fs_roots = [whole_argv[i + 1] for i in range(len(whole_argv) - 1) if whole_argv[i] == "--filesystem-root"]
    asserts.equals(env, 2, len(fs_roots), "whole-program DartKernel action passes two --filesystem-root flags")
    asserts.equals(env, ".", fs_roots[0], "whole-program DartKernel action passes '.' before bin_dir")
    asserts.true(env, fs_roots[1].endswith("/bin"), "whole-program DartKernel action passes bin_dir second")
    return analysistest.end(env)

_non_modular_kernel_binary_test = analysistest.make(_non_modular_kernel_binary_test_impl)

def _comma_defines_modular_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "modular kernel binary with comma defines registers one DartKernel entry action")
    asserts.true(
        env,
        "-DCOMMA_FLAG=a,b" in kernel_actions[0].argv,
        "comma-containing define is passed to modular DartKernel action",
    )
    asserts.true(
        env,
        "--comma-patched-snapshot" in kernel_actions[0].argv,
        "modular comma compile passes the patched-snapshot marker",
    )
    entry_inputs = [f.basename for f in kernel_actions[0].inputs.to_list()]
    asserts.true(
        env,
        "kernel_worker_nocomma.snapshot" in entry_inputs,
        "the toolchain's patched worker snapshot is an input of the modular DartKernel action: %s" % entry_inputs,
    )
    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(link_actions), "modular kernel binary with comma defines registers one DartKernelLink action")
    return analysistest.end(env)

_comma_defines_modular_binary_test = analysistest.make(
    _comma_defines_modular_binary_test_impl,
    config_settings = pruned_inputs_settings({
        str(Label("//dart:extra_dart_defines")): ["COMMA_FLAG=a,b"],
    }),
)

def _unseeded_base_kmods_fixture_impl(ctx):
    dartaotruntime = ctx.actions.declare_file(ctx.label.name + "_dartaotruntime")
    kernel_worker = ctx.actions.declare_file(ctx.label.name + "_kernel_worker.snapshot")
    platform_dill = ctx.actions.declare_file(ctx.label.name + "_vm_platform_strong.dill")
    libraries_json = ctx.actions.declare_file(ctx.label.name + "_libraries.json")
    src_file = ctx.actions.declare_file(ctx.label.name + "_main_test.dart")
    base_dill = ctx.actions.declare_file(ctx.label.name + ".base.dill")
    base_keys = ctx.actions.declare_file(ctx.label.name + ".base.keys")
    for f in [dartaotruntime, kernel_worker, platform_dill, libraries_json, src_file, base_dill, base_keys]:
        ctx.actions.write(output = f, content = "")

    base_kmod = ctx.actions.declare_directory(ctx.label.name + "_matcher.kmod")
    crypto_kmod = ctx.actions.declare_directory(ctx.label.name + "_crypto.kmod")
    shelf_kmod = ctx.actions.declare_directory(ctx.label.name + "_shelf.kmod")
    base_koutline = ctx.actions.declare_directory(ctx.label.name + "_matcher.koutline")
    crypto_koutline = ctx.actions.declare_directory(ctx.label.name + "_crypto.koutline")
    shelf_koutline = ctx.actions.declare_directory(ctx.label.name + "_shelf.koutline")
    for d in [base_kmod, crypto_kmod, shelf_kmod, base_koutline, crypto_koutline, shelf_koutline]:
        ctx.actions.run_shell(outputs = [d], command = "mkdir -p " + d.path)

    all_kmods = depset([base_kmod, crypto_kmod, shelf_kmod], order = "postorder")
    all_koutlines = depset([base_koutline, crypto_koutline, shelf_koutline], order = "postorder")

    # dep_a did not use crypto (crypto_kmod and shelf_kmod both in unseeded_base_kmods)
    dep_a = DartKernelInfo(
        kmod = base_kmod,
        koutline = base_koutline,
        transitive_kmods = all_kmods,
        transitive_koutlines = all_koutlines,
        modular = True,
        closure_excluded = depset(),
        cross_pkg_srcs = depset(),
        owned = depset(),
        edges = depset(),
        base_dill = base_dill,
        base_keys = base_keys,
        base_kmods = depset([base_kmod]),
        unseeded_base_kmods = depset([crypto_kmod, shelf_kmod]),
    )

    # dep_b used crypto (so crypto_kmod was removed from dep_b.unseeded_base_kmods)
    dep_b = DartKernelInfo(
        kmod = crypto_kmod,
        koutline = crypto_koutline,
        transitive_kmods = all_kmods,
        transitive_koutlines = all_koutlines,
        modular = True,
        closure_excluded = depset(),
        cross_pkg_srcs = depset(),
        owned = depset(),
        edges = depset(),
        base_dill = base_dill,
        base_keys = base_keys,
        base_kmods = depset([base_kmod]),
        unseeded_base_kmods = depset([shelf_kmod]),
    )

    tools = struct(
        dartaotruntime = dartaotruntime,
        kernel_worker = kernel_worker,
        platform_dill = platform_dill,
        libraries_json = libraries_json,
        version = "3.11.0",
    )
    out_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    modular_executable_kernel(
        ctx = ctx,
        tools = tools,
        sources = [struct(uri = "org-dartlang-root:///pkg/test/main_test.dart", file = src_file)],
        packages = [_pkg("pkg", "pkg", "3.9")],
        dep_kernels = [dep_a, dep_b],
        output = out_dill,
        compile = kernel_compile_settings(),
        use_base_dill = True,
    )
    return [DefaultInfo(files = depset([out_dill]))]

_unseeded_base_kmods_fixture = rule(
    implementation = _unseeded_base_kmods_fixture_impl,
    attrs = {
        "_extra_dart_defines": attr.label(
            default = Label("//dart:extra_dart_defines"),
        ),
        "_kernel_module": attr.label(
            default = Label("//dart:kernel_module"),
            executable = True,
            cfg = "exec",
        ),
        "_kernel_link": attr.label(
            default = Label("//dart:kernel_link"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _unseeded_base_kmods_intersection_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(link_actions), "registers one DartKernelLink action")
    link_input_basenames = [f.basename for f in link_actions[0].inputs.to_list()]
    asserts.true(
        env,
        any([b.endswith("_crypto.kmod") for b in link_input_basenames]),
        "crypto.kmod used by second base_dill helper is retained in DartKernelLink inputs",
    )
    asserts.true(
        env,
        any([b.endswith("_shelf.kmod") for b in link_input_basenames]),
        "shelf.kmod not seeded into base_dill is retained in DartKernelLink inputs",
    )
    asserts.false(
        env,
        any([b.endswith("_matcher.kmod") for b in link_input_basenames]),
        "matcher.kmod in base_kmods is pruned from DartKernelLink inputs",
    )
    return analysistest.end(env)

_unseeded_base_kmods_intersection_test = analysistest.make(
    _unseeded_base_kmods_intersection_test_impl,
)

def _user_test_runner_embeds_sources_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "user binary named test_runner runs one DartKernel action")
    asserts.false(
        env,
        "--no-embed-sources" in kernel_actions[0].argv,
        "user dart_binary named test_runner retains embedded sources",
    )
    return analysistest.end(env)

_user_test_runner_embeds_sources_test = analysistest.make(
    _user_test_runner_embeds_sources_test_impl,
)

def _generated_test_runner_omits_sources_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "generated test runner binary runs one DartKernel action")
    asserts.true(
        env,
        "--no-embed-sources" in kernel_actions[0].argv,
        "dart_binary with dart_test_runner_main passes --no-embed-sources",
    )
    return analysistest.end(env)

_generated_test_runner_omits_sources_test = analysistest.make(
    _generated_test_runner_omits_sources_test_impl,
)

def _has_cross_pkg_cycle_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        _pkg("a", "pkg/a"),
        _pkg("b", "pkg/b"),
        _pkg("leaf", "pkg/leaf"),
    ]
    asserts.equals(
        env,
        "a",
        package_of_source("pkg/a/lib/src/x.dart", pkgs),
        "package_of_source matches package lib/ prefix",
    )
    asserts.equals(
        env,
        None,
        package_of_source("other/lib/x.dart", pkgs),
        "package_of_source returns None when no package matches",
    )
    asserts.false(
        env,
        has_cross_pkg_cycle(
            "a",
            [_pkg("b", "pkg/b"), _pkg("leaf", "pkg/leaf")],
            owned = [
                ("//pkg/a:a", "pkg/a/lib/a.dart"),
                ("//pkg/b:b", "pkg/b/lib/b.dart"),
                ("//pkg/leaf:leaf", "pkg/leaf/lib/leaf.dart"),
            ],
            edges = [
                ("//pkg/a:a", "//pkg/b:b"),
                ("//pkg/b:b", "//pkg/leaf:leaf"),
            ],
            packages = pkgs,
        ),
        "a linear chain of distinct packages has no cross-package cycle",
    )
    asserts.true(
        env,
        has_cross_pkg_cycle(
            "a",
            [_pkg("a", "pkg/a"), _pkg("b", "pkg/b")],
            owned = [
                ("//pkg/a:a_base", "pkg/a/lib/a_base.dart"),
                ("//pkg/b:b", "pkg/b/lib/b.dart"),
                ("//pkg/a:a_top", "pkg/a/lib/a_top.dart"),
            ],
            edges = [
                ("//pkg/b:b", "//pkg/a:a_base"),
                ("//pkg/a:a_top", "//pkg/b:b"),
                ("//pkg/a:a_top", "//pkg/a:a_base"),
            ],
            packages = pkgs,
        ),
        "a package split across a_base <- b <- a_top has a cross-package cycle",
    )
    asserts.true(
        env,
        has_cross_pkg_cycle(
            "c",
            [_pkg("a", "pkg/a"), _pkg("c", "pkg/c")],
            owned = [
                ("//pkg/a:sib1", "pkg/a/lib/s1.dart"),
                ("//pkg/a:sib2", "pkg/a/lib/s2.dart"),
                ("//pkg/c:c", "pkg/c/lib/c.dart"),
            ],
            edges = [
                ("//pkg/c:c", "//pkg/a:sib1"),
                ("//pkg/c:c", "//pkg/a:sib2"),
            ],
            packages = [_pkg("a", "pkg/a"), _pkg("c", "pkg/c")],
        ),
        "two sibling targets sharing one package name in the closure trigger cross-package handling",
    )
    asserts.true(
        env,
        has_cross_pkg_cycle(
            "b",
            [_pkg("a", "pkg/a")],
            non_standalone = True,
        ),
        "a target with no-dart-analyze (non_standalone) triggers cross-package handling",
    )
    asserts.false(
        env,
        has_cross_pkg_cycle(
            "a",
            [_pkg("a", "pkg/a")],
            owned = [("//pkg/a:a", "pkg/a/lib/a.dart")],
            edges = [],
            packages = [_pkg("a", "pkg/a")],
            is_executable = True,
        ),
        "an executable in package a depending on a single library in package a is not a cycle",
    )
    asserts.true(
        env,
        has_cross_pkg_cycle(
            "a",
            [_pkg("a", "pkg/a"), _pkg("b", "pkg/b")],
            owned = [
                ("//pkg/a:a_base", "pkg/a/lib/a_base.dart"),
                ("//pkg/b:b", "pkg/b/lib/b.dart"),
            ],
            edges = [("//pkg/b:b", "//pkg/a:a_base")],
            packages = pkgs,
            is_executable = True,
        ),
        "an executable with own_package a whose dependency b depends on a_base closes a cycle",
    )
    return unittest.end(env)

def _cross_pkg_cycle_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "registers one DartKernel entry action")
    entry_action = kernel_actions[0]
    input_short_paths = [f.short_path for f in entry_action.inputs.to_list()]
    asserts.true(
        env,
        "dart/tests/cross_pkg_cycle_fixture/pkg_a/lib/a_base.dart" in input_short_paths,
        "a_base.dart is a declared input of the entry module action",
    )
    asserts.true(
        env,
        "dart/tests/cross_pkg_cycle_fixture/pkg_b/lib/b.dart" in input_short_paths,
        "b.dart is a declared input of the entry module action",
    )
    asserts.true(
        env,
        "dart/tests/cross_pkg_cycle_fixture/pkg_a/lib/a_top.dart" in input_short_paths,
        "a_top.dart is a declared input of the entry module action",
    )
    asserts.false(
        env,
        "dart/tests/cross_pkg_cycle_fixture/pkg_leaf/lib/leaf.dart" in input_short_paths,
        "non-cyclic leaf.dart is not an input of the entry module action",
    )
    asserts.true(
        env,
        "--input-source" in entry_action.argv,
        "--input-source is passed to kernel_module for cross_pkg_srcs",
    )
    return analysistest.end(env)

_cross_pkg_cycle_inputs_test = analysistest.make(
    _cross_pkg_cycle_inputs_test_impl,
    config_settings = pruned_inputs_settings(),
)

def _part_sources_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartKernelInfo]
    asserts.true(env, info.modular, "part_lib builds a modular kernel")
    asserts.true(env, info.kmod != None, "part_lib declares a .kmod directory")
    cross_short_paths = [f.short_path for f in info.cross_pkg_srcs.to_list()]
    asserts.true(
        env,
        "dart/tests/part_sources_fixture/same_pkg/lib/parent.dart" in cross_short_paths,
        "parent.dart from dependency target in the same package is in part_lib's cross_pkg_srcs",
    )
    asserts.true(
        env,
        "dart/tests/part_sources_fixture/same_pkg/lib/uri_part.dart" in cross_short_paths,
        "uri_part.dart is in part_lib's cross_pkg_srcs",
    )
    return analysistest.end(env)

_part_sources_inputs_test = analysistest.make(
    _part_sources_inputs_test_impl,
    extra_target_under_test_aspects = [dart_kernel_module_aspect],
)

def _worker_execution_requirements_test_impl(ctx):
    env = unittest.begin(ctx)
    runs = []

    def _declare_file(name):
        return struct(basename = name, path = "out/" + name, short_path = name)

    def _args():
        return struct(
            use_param_file = lambda *_a, **_kw: None,
            set_param_file_format = lambda *_a, **_kw: None,
            add = lambda *_a, **_kw: None,
            add_all = lambda *_a, **_kw: None,
        )

    fake_actions = struct(
        declare_file = _declare_file,
        write = lambda **_kw: None,
        args = _args,
        run = lambda **kw: runs.append(kw),
    )
    fake_ctx = struct(
        label = struct(name = "manual_target", package = "flutter/tests/foo"),
        attr = struct(tags = ["manual"], _kernel_module = None, _kernel_link = None),
        rule = struct(attr = struct(tags = ["manual"])),
        bin_dir = struct(path = "bazel-out/k8-fastbuild/bin"),
        executable = struct(
            _kernel_module = _declare_file("kernel_module.dill"),
            _kernel_link = _declare_file("kernel_link.dill"),
        ),
        toolchains = {},
        actions = fake_actions,
    )
    fake_tools = struct(
        dartaotruntime = _declare_file("dartaotruntime"),
        kernel_worker = _declare_file("kernel_worker.snapshot"),
        platform_dill = _declare_file("vm_platform_strong.dill"),
        libraries_json = _declare_file("libraries.json"),
        version = "3.11.0",
    )
    kmod = _declare_file("manual_target.kmod")
    kernel_module_action(
        ctx = fake_ctx,
        tools = fake_tools,
        inputs = kernel_module_inputs(
            sources = [struct(uri = "package:a/a.dart", file = _declare_file("a.dart"))],
            packages = [_pkg("a", "pkg/a", "3.9")],
            dep_kmods = depset(),
        ),
        outputs = kernel_module_outputs(output = kmod),
        options = kernel_module_options(
            defines = [],
            exclude_non_sources = False,
            droppable = False,
        ),
        compile = kernel_compile_settings(),
    )
    kernel_link_action(
        ctx = fake_ctx,
        dep_kmods = depset(),
        entry = kmod,
        output = _declare_file("manual_target.dill"),
    )
    asserts.equals(env, 2, len(runs), "registers DartKernel and DartKernelLink actions")
    expected_reqs = {
        "supports-workers": "1",
        "requires-worker-protocol": "proto",
    }
    asserts.equals(
        env,
        expected_reqs,
        runs[0]["execution_requirements"],
        "DartKernel sets worker execution_requirements even for manual target in flutter/tests",
    )
    asserts.equals(
        env,
        expected_reqs,
        runs[1]["execution_requirements"],
        "DartKernelLink sets worker execution_requirements even for manual target in flutter/tests",
    )
    return unittest.end(env)

def _unused_inputs_wiring_test_impl(ctx):
    env = unittest.begin(ctx)
    runs = []
    added = []

    def _declare_file(name):
        return struct(basename = name, path = "out/" + name, short_path = name)

    def _args():
        return struct(
            use_param_file = lambda *_a, **_kw: None,
            set_param_file_format = lambda *_a, **_kw: None,
            add = lambda *_a: added.append(_a),
            add_all = lambda *_a, **_kw: None,
        )

    fake_actions = struct(
        declare_file = _declare_file,
        write = lambda **_kw: None,
        args = _args,
        run = lambda **kw: runs.append(kw),
    )
    fake_ctx = struct(
        label = struct(name = "manual_target", package = "flutter/tests/foo"),
        attr = struct(tags = ["manual"], _kernel_module = None, _kernel_link = None),
        rule = struct(attr = struct(tags = ["manual"])),
        bin_dir = struct(path = "bazel-out/k8-fastbuild/bin"),
        executable = struct(
            _kernel_module = _declare_file("kernel_module.dill"),
            _kernel_link = _declare_file("kernel_link.dill"),
        ),
        toolchains = {},
        actions = fake_actions,
    )
    fake_tools = struct(
        dartaotruntime = _declare_file("dartaotruntime"),
        kernel_worker = _declare_file("kernel_worker.snapshot"),
        platform_dill = _declare_file("vm_platform_strong.dill"),
        libraries_json = _declare_file("libraries.json"),
        version = "3.11.0",
    )

    def _compile(unused_inputs = False):
        kernel_module_action(
            ctx = fake_ctx,
            tools = fake_tools,
            inputs = kernel_module_inputs(
                sources = [struct(uri = "package:a/a.dart", file = _declare_file("a.dart"))],
                packages = [_pkg("a", "pkg/a", "3.9")],
                dep_kmods = depset(),
            ),
            outputs = kernel_module_outputs(
                output = _declare_file("manual_target.kmod"),
                unused_inputs = unused_inputs,
            ),
            options = kernel_module_options(
                defines = [],
                exclude_non_sources = False,
                droppable = False,
            ),
            compile = kernel_compile_settings(),
        )

    _compile(unused_inputs = True)
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] != None,
        "unused_inputs = True passes unused_inputs_list to the action",
    )
    asserts.equals(
        env,
        "manual_target.kmod.unused_inputs",
        runs[0]["unused_inputs_list"].basename,
        "the list file sits next to the module output",
    )
    flags = [a[0] for a in added]
    asserts.true(
        env,
        "--unused-inputs-list" in flags,
        "unused_inputs = True forwards --unused-inputs-list to kernel_module",
    )
    asserts.true(
        env,
        "--own-source-file" in flags,
        "unused_inputs = True reports own sources for the used-input check",
    )

    runs.clear()
    added.clear()
    _compile()
    asserts.equals(env, 1, len(runs), "registers one DartKernel action by default")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] == None,
        "the default registers the historical action with no list",
    )
    flags = [a[0] for a in added]
    asserts.true(
        env,
        "--unused-inputs-list" not in flags,
        "the default passes no --unused-inputs-list to kernel_module",
    )
    return unittest.end(env)

def _entry_unused_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "modular kernel binary registers one DartKernel entry action")
    kernel_out_basenames = [f.basename for f in kernel_actions[0].outputs.to_list()]
    asserts.true(
        env,
        target.label.name + ".entry.kmod.unused_inputs" in kernel_out_basenames,
        "DartKernel entry action declares the unused-inputs list",
    )
    return analysistest.end(env)

_entry_unused_inputs_test = analysistest.make(_entry_unused_inputs_test_impl)

def _library_unused_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "dart_library registers one DartKernel module action")
    kernel_out_basenames = [f.basename for f in kernel_actions[0].outputs.to_list()]
    asserts.true(
        env,
        target.label.name + ".kmod.unused_inputs" in kernel_out_basenames,
        "DartKernel module action declares the unused-inputs list",
    )
    return analysistest.end(env)

_library_unused_inputs_test = analysistest.make(_library_unused_inputs_test_impl)

_root_path_test = unittest.make(_root_path_test_impl)
_multi_root_uri_test = unittest.make(_multi_root_uri_test_impl)
_multi_root_uri_custom_scheme_test = unittest.make(_multi_root_uri_custom_scheme_test_impl)
_entry_source_uri_test = unittest.make(_entry_source_uri_test_impl)
_entry_source_uri_custom_scheme_test = unittest.make(_entry_source_uri_custom_scheme_test_impl)
_library_source_uri_test = unittest.make(_library_source_uri_test_impl)
_package_config_test = unittest.make(_package_config_test_impl)
_package_config_custom_scheme_test = unittest.make(_package_config_custom_scheme_test_impl)
_packages_consistent_test = unittest.make(_packages_consistent_test_impl)
_first_per_package_test = unittest.make(_first_per_package_test_impl)
_duplicated_source_test = unittest.make(_duplicated_source_test_impl)
_eligible_test = unittest.make(_eligible_test_impl)
_has_cross_pkg_cycle_test = unittest.make(_has_cross_pkg_cycle_test_impl)
_unused_inputs_wiring_test = unittest.make(_unused_inputs_wiring_test_impl)
_worker_execution_requirements_test = unittest.make(_worker_execution_requirements_test_impl)

def kernel_test_suite(name):
    """Declares the modular kernel unit tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    _custom_kernel_module_fixture(
        name = name + "_custom_module_fixture",
        tags = ["manual"],
    )
    _kernel_module_action_custom_params_test(
        name = name + "_custom_module_action_test",
        target_under_test = ":" + name + "_custom_module_fixture",
        size = "small",
    )
    _dummy_dart_source(
        name = name + "_binary_main",
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_modular_binary_fixture",
        compile_mode = "kernel",
        main = ":" + name + "_binary_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _modular_kernel_binary_test(
        name = name + "_modular_binary_test",
        target_under_test = ":" + name + "_modular_binary_fixture",
        size = "small",
    )
    dart_binary(
        name = name + "_non_modular_binary_fixture",
        compile_mode = "kernel",
        modular_kernel = False,
        main = ":" + name + "_binary_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _non_modular_kernel_binary_test(
        name = name + "_non_modular_binary_test",
        target_under_test = ":" + name + "_non_modular_binary_fixture",
        size = "small",
    )
    _comma_defines_modular_binary_test(
        name = name + "_comma_defines_modular_binary_test",
        target_under_test = ":" + name + "_modular_binary_fixture",
        size = "small",
    )
    dart_binary(
        name = "test_runner",
        compile_mode = "kernel",
        modular_kernel = False,
        main = ":" + name + "_binary_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _user_test_runner_embeds_sources_test(
        name = name + "_user_test_runner_embeds_sources_test",
        target_under_test = ":test_runner",
        size = "small",
    )
    dart_test_runner_main(
        name = name + "_generated_runner_main",
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_generated_runner_binary",
        compile_mode = "kernel",
        modular_kernel = False,
        main = ":" + name + "_generated_runner_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _generated_test_runner_omits_sources_test(
        name = name + "_generated_test_runner_omits_sources_test",
        target_under_test = ":" + name + "_generated_runner_binary",
        size = "small",
    )
    dart_binary(
        name = "kernel_module",
        compile_mode = "kernel",
        main = ":" + name + "_binary_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _modular_kernel_binary_test(
        name = name + "_user_kernel_module_modular_test",
        target_under_test = ":kernel_module",
        size = "small",
    )
    dart_binary(
        name = "kernel_link",
        compile_mode = "kernel",
        main = ":" + name + "_binary_main",
        deps = ["//dart/tests/shape_fixture:shape_fixture_lib"],
        tags = ["manual"],
    )
    _modular_kernel_binary_test(
        name = name + "_user_kernel_link_modular_test",
        target_under_test = ":kernel_link",
        size = "small",
    )
    _unseeded_base_kmods_fixture(
        name = name + "_unseeded_base_kmods_fixture",
        tags = ["manual"],
    )
    _unseeded_base_kmods_intersection_test(
        name = name + "_unseeded_base_kmods_intersection_test",
        target_under_test = ":" + name + "_unseeded_base_kmods_fixture",
        size = "small",
    )
    _cross_pkg_cycle_inputs_test(
        name = name + "_cross_pkg_cycle_inputs_test",
        target_under_test = "//dart/tests/cross_pkg_cycle_fixture:app_modular",
        size = "small",
    )
    _entry_unused_inputs_test(
        name = name + "_entry_unused_inputs_test",
        target_under_test = ":" + name + "_modular_binary_fixture",
        size = "small",
    )
    _library_unused_inputs_test(
        name = name + "_library_unused_inputs_test",
        target_under_test = "//dart/tests/shape_fixture:shape_fixture_lib",
        size = "small",
    )
    _part_sources_inputs_test(
        name = name + "_part_sources_inputs_test",
        target_under_test = "//dart/tests/part_sources_fixture/same_pkg:part_lib",
        size = "small",
    )
    small_unittest_suite(
        name + "_unit",
        _root_path_test,
        _multi_root_uri_test,
        _multi_root_uri_custom_scheme_test,
        _entry_source_uri_test,
        _entry_source_uri_custom_scheme_test,
        _library_source_uri_test,
        _package_config_test,
        _package_config_custom_scheme_test,
        _packages_consistent_test,
        _first_per_package_test,
        _duplicated_source_test,
        _eligible_test,
        _has_cross_pkg_cycle_test,
        _unused_inputs_wiring_test,
        _worker_execution_requirements_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_custom_module_action_test",
            ":" + name + "_modular_binary_test",
            ":" + name + "_non_modular_binary_test",
            ":" + name + "_comma_defines_modular_binary_test",
            ":" + name + "_user_test_runner_embeds_sources_test",
            ":" + name + "_generated_test_runner_omits_sources_test",
            ":" + name + "_user_kernel_module_modular_test",
            ":" + name + "_user_kernel_link_modular_test",
            ":" + name + "_unseeded_base_kmods_intersection_test",
            ":" + name + "_cross_pkg_cycle_inputs_test",
            ":" + name + "_entry_unused_inputs_test",
            ":" + name + "_library_unused_inputs_test",
            ":" + name + "_part_sources_inputs_test",
            "//dart/tests/cross_pkg_cycle_fixture:cross_pkg_cycle_test",
            "//dart/tests/legacy_mixin_fixture:legacy_mixin_test",
            "//dart/tests/defines_fixture:test_defines_test",
            "//dart/tests/defines_fixture:modular_comma_defines_test",
            "//dart/tests/part_sources_fixture:part_sources_test",
        ],
    )
