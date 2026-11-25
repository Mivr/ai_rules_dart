"""Analysis tests for trimmed SDK action inputs and test runfiles.

Asserts that `flutter_test` runfiles and Flutter build actions (`FlutterAotElf`,
`FlutterAotMacho`, `FlutterAssets`, `FlutterDart2Wasm`, `FlutterDart2JS`)
stage only the SDK files their executables actually open, rather than the full
bundled `dart-sdk/` and `patched-sdk/` trees.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:analyze.bzl", "dart_analyze")
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("@rules_dart//dart:toolchain.bzl", "DartSdkInfo")
load("//flutter:defs.bzl", "flutter_library", "flutter_plugin", "flutter_test")
load("//flutter:toolchain.bzl", "flutter_font_subset_toolchain")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")
load(":flutter_line_probe.bzl", "FLUTTER_LINE_ATTR", "flutter_line")
load(":kernel_target_modular_test.bzl", "assert_kernel_target_dbg_modular")

visibility(["//flutter/tests/..."])

_PACKAGE = "inputs_fixture"
_MAIN = "lib/language_version_main.dart"

def _find_action(env, mnemonics):
    found = [a for a in analysistest.target_actions(env) if a.mnemonic in mnemonics]
    asserts.equals(
        env,
        1,
        len(found),
        "expected exactly one action in %s, got %s" % (mnemonics, [a.mnemonic for a in found]),
    )
    return found[0] if found else None

def _input_paths(action):
    return [f.path for f in action.inputs.to_list()] if action else []

def _assert_no_path_contains(env, paths, forbidden_substrings, context):
    for sub in forbidden_substrings:
        matches = [p for p in paths if sub in p]
        asserts.equals(
            env,
            [],
            matches[:5],
            "%s must not stage %r (found %d matching files, e.g. %s)" %
            (context, sub, len(matches), matches[:3]),
        )

def _assert_some_path_contains(env, paths, required_substrings, context):
    for sub in required_substrings:
        matches = [p for p in paths if sub in p]
        asserts.true(
            env,
            len(matches) > 0,
            "%s must stage %r" % (context, sub),
        )

def _flutter_test_runfiles_test_impl(ctx):
    """`flutter_test` runfiles carry `flutter_tester` and ICU data, not the SDK."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runfile_paths = [f.path for f in target[DefaultInfo].default_runfiles.files.to_list()]

    _assert_some_path_contains(
        env,
        runfile_paths,
        ["flutter_tester", "icudtl.dat"],
        "flutter_test runfiles",
    )
    _assert_no_path_contains(
        env,
        runfile_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "flutter_test runfiles",
    )

    # By default (`modular_kernel = True`), `flutter_test` compiles its entry module
    # with `DartKernel` against upstream `.flutter.koutline` summaries (without
    # staging upstream `.flutter.kmod` or transitive `.dart` sources) and links
    # with `DartKernelLink` against `.flutter.kmod`, emitting no whole-program
    # `FlutterKernelCompile`.
    kernel_action = _find_action(env, ["DartKernel"])
    kernel_inputs = _input_paths(kernel_action)
    _assert_some_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.koutline"],
        "flutter_test DartKernel inputs",
    )
    _assert_no_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.kmod/", "fake_test_api/lib/backend.dart"],
        "flutter_test DartKernel inputs",
    )
    link_action = _find_action(env, ["DartKernelLink"])
    _assert_some_path_contains(
        env,
        _input_paths(link_action),
        ["fake_test_api.flutter.kmod"],
        "flutter_test DartKernelLink inputs",
    )
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "modular flutter_test must not run FlutterKernelCompile")
    return analysistest.end(env)

def _flutter_test_defines_modular_test_impl(ctx):
    """A `flutter_test` with its own `defines` stays modular: its `deps` compile with them, and so does its entry."""
    env = analysistest.begin(ctx)
    entry = _find_action(env, ["DartKernel"])
    asserts.true(env, "-DFOO=1" in entry.argv, "expected -DFOO=1 in the entry compile, got %s" % entry.argv)
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(modular_links), "a flutter_test with own defines must link modularly")
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "a flutter_test with own defines must not run FlutterKernelCompile")
    return analysistest.end(env)

def _flutter_test_comma_modular_test_impl(ctx):
    """A comma in a global define changes nothing for a `flutter_test`: it links modularly."""
    env = analysistest.begin(ctx)
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(modular_links), "a flutter_test with a comma define must link modularly")
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "a flutter_test with a comma define must not run FlutterKernelCompile")
    return analysistest.end(env)

def _comma_defines_fallback_test_impl(ctx):
    """A whole-program compile (a release kernel target) takes a global define with a comma intact."""
    env = analysistest.begin(ctx)
    compile_action = _find_action(env, ["FlutterKernelCompile"])
    asserts.true(
        env,
        "-DFOO=a,b" in compile_action.argv,
        "expected -DFOO=a,b in FlutterKernelCompile argv, got %s" % compile_action.argv,
    )
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, [], modular_links, "comma-containing extra_dart_defines must fall back from DartKernelLink")
    return analysistest.end(env)

def _dart_extra_defines_ignored_test_impl(ctx):
    """`@rules_dart//dart:extra_dart_defines` does not change a Flutter kernel action's command line."""
    env = analysistest.begin(ctx)
    kernel_action = _find_action(env, ["FlutterKernelCompile", "DartKernel"])
    argv_joined = " ".join(kernel_action.argv)
    asserts.false(
        env,
        "FROM_DART=1" in argv_joined,
        "@rules_dart//dart:extra_dart_defines must not be forwarded to Flutter kernel action, got %s" % kernel_action.argv,
    )
    asserts.false(
        env,
        "dart.vm.product=true" in argv_joined,
        "@rules_dart//dart:extra_dart_defines must not flip debug Flutter kernel action to product mode, got %s" % kernel_action.argv,
    )
    return analysistest.end(env)

def _application_opt_inputs_test_impl(ctx):
    """In `-c opt`, AOT takes no SDK tree."""
    env = analysistest.begin(ctx)

    aot_action = _find_action(env, ["FlutterAotElf", "FlutterAotMacho"])
    aot_paths = _input_paths(aot_action)
    _assert_some_path_contains(env, aot_paths, ["gen_snapshot", ".dill"], "AOT action")
    _assert_no_path_contains(
        env,
        aot_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "AOT action",
    )
    return analysistest.end(env)

def _application_opt_bundle_inputs_test_impl(ctx):
    """In `-c opt` the bundle shakes icons, so it reads what its line's shaker reads and the font tool.

    On a line whose shaker reads the compilers' recorded uses, what the AOT
    compile recorded of the app's uses; on one whose shaker runs
    `const_finder`, the app's kernel and `const_finder`.
    """
    env = analysistest.begin(ctx)
    if flutter_line(ctx).icon_tree_shaker == "const_finder":
        expected = [".dill", "const_finder", "font-subset"]
    else:
        expected = ["recorded_uses.json", "font-subset"]
    _assert_some_path_contains(
        env,
        _input_paths(_find_action(env, ["FlutterAssets"])),
        expected,
        "release FlutterAssets",
    )
    return analysistest.end(env)

def _application_dbg_bundle_inputs_test_impl(ctx):
    """In `-c dbg` the bundle never reads the app's kernel or recorded uses, so a Dart edit does not rerun it."""
    env = analysistest.begin(ctx)
    _assert_no_path_contains(
        env,
        _input_paths(_find_action(env, ["FlutterAssets"])),
        [".dill", "recorded_uses.json", "const_finder", "font-subset"],
        "debug FlutterAssets",
    )
    return analysistest.end(env)

def _application_no_tree_shake_icons_test_impl(ctx):
    """When `tree_shake_icons = False`, the bundle reads neither the recorded uses nor the font tool."""
    env = analysistest.begin(ctx)
    _assert_no_path_contains(
        env,
        _input_paths(_find_action(env, ["FlutterAssets"])),
        [".dill", "recorded_uses.json", "const_finder", "font-subset"],
        "tree_shake_icons=False FlutterAssets",
    )
    return analysistest.end(env)

def _aot_target_inputs_test_impl(ctx):
    """`flutter_aot_target` passes only the kernel dill and `gen_snapshot`."""
    env = analysistest.begin(ctx)
    aot_action = _find_action(env, ["FlutterAotElf", "FlutterAotMacho"])
    aot_paths = _input_paths(aot_action)
    _assert_some_path_contains(env, aot_paths, ["gen_snapshot", ".dill"], "flutter_aot_target")
    _assert_no_path_contains(
        env,
        aot_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "flutter_aot_target",
    )
    return analysistest.end(env)

def _aot_target_dbg_inputs_test_impl(ctx):
    """In `-c dbg`, `flutter_aot_target` skips `gen_snapshot` and returns the linked kernel `.dill`."""
    env = analysistest.begin(ctx)
    compile_action = _find_action(env, ["DartKernel"])
    aot_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic in ("FlutterAotElf", "FlutterAotMacho")
    ]
    asserts.equals(env, [], aot_actions, "debug flutter_aot_target must not run gen_snapshot")

    # The debug kernel is the entry module, which compiles the app's own
    # sources against its dependencies' outlines, linked with their modules.
    entry_inputs = _input_paths(compile_action)
    _assert_some_path_contains(
        env,
        entry_inputs,
        ["language_version_main.dart"],
        "debug flutter_aot_target entry module",
    )
    asserts.equals(
        env,
        [],
        [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"],
        "debug flutter_aot_target runs no whole-program compile",
    )
    asserts.equals(
        env,
        1,
        len([a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]),
        "debug flutter_aot_target links its modules",
    )
    outputs = [f.basename for f in analysistest.target_under_test(env)[DefaultInfo].files.to_list()]
    asserts.equals(env, ["_inputs_aot_target.dill"], outputs)
    return analysistest.end(env)

def _kernel_target_release_aot_test_impl(ctx):
    """In `opt` and `fastbuild`, default `flutter_kernel_target` runs AOT product `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    compile_action = _find_action(env, ["FlutterKernelCompile"])
    asserts.true(env, "--aot" in compile_action.argv, "expected --aot in FlutterKernelCompile argv")
    asserts.true(env, "--tfa" in compile_action.argv, "expected --tfa in FlutterKernelCompile argv")
    asserts.true(
        env,
        "-Ddart.vm.product=true" in compile_action.argv,
        "expected -Ddart.vm.product=true in FlutterKernelCompile argv",
    )
    _assert_some_path_contains(
        env,
        _input_paths(compile_action),
        ["flutter_patched_sdk_product/platform_strong.dill"],
        "release AOT flutter_kernel_target",
    )
    _assert_no_path_contains(
        env,
        _input_paths(compile_action),
        ["flutter_patched_sdk/platform_strong.dill"],
        "release AOT flutter_kernel_target",
    )
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, [], modular_links, "AOT flutter_kernel_target must not run DartKernelLink")
    return analysistest.end(env)

def _kernel_target_dbg_test_impl(ctx):
    """In `-c dbg`, non-AOT `flutter_kernel_target` links per-package kernels instead of `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "no whole-program compile")
    assert_kernel_target_dbg_modular(env)
    return analysistest.end(env)

def _kernel_target_aot_test_impl(ctx):
    """`flutter_kernel_target(aot = True)` runs whole-program `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    _find_action(env, ["FlutterKernelCompile"])
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, [], modular_links, "AOT flutter_kernel_target must not run DartKernelLink")
    return analysistest.end(env)

def _kernel_target_aot_dbg_test_impl(ctx):
    """In `-c dbg`, `flutter_kernel_target(aot = True)` compiles against the non-product platform `.dill`."""
    env = analysistest.begin(ctx)
    compile_action = _find_action(env, ["FlutterKernelCompile"])
    asserts.true(env, "--aot" in compile_action.argv, "expected --aot in FlutterKernelCompile argv")
    _assert_some_path_contains(
        env,
        _input_paths(compile_action),
        ["flutter_patched_sdk/platform_strong.dill"],
        "debug AOT flutter_kernel_target",
    )
    _assert_no_path_contains(
        env,
        _input_paths(compile_action),
        ["flutter_patched_sdk_product/"],
        "debug AOT flutter_kernel_target",
    )
    return analysistest.end(env)

def _web_inputs_test_impl(ctx):
    """`FlutterDart2Wasm` and `FlutterDart2JS` stage only their own compiler inputs."""
    env = analysistest.begin(ctx)

    wasm_action = _find_action(env, ["FlutterDart2Wasm"])
    wasm_paths = _input_paths(wasm_action)
    _assert_some_path_contains(
        env,
        wasm_paths,
        [
            "web-sdk/kernel/dart2wasm_platform.dill",
            "dart-sdk/bin/dart",
            "dart-sdk/bin/dartvm",
            "dart-sdk/bin/snapshots/dart2wasm",
            "dart-sdk/bin/snapshots/dartdev",
            "dart-sdk/bin/utils/wasm-opt",
        ],
        "FlutterDart2Wasm",
    )
    _assert_no_path_contains(
        env,
        wasm_paths,
        [
            "/patched-sdk/",
            "/web-sdk/canvaskit/",
            "/web-sdk/lib/",
            "dart2js_platform.dill",
            "dart2js_aot.dart.snapshot",
            "dartdevc",
            "gen_snapshot",
            ".sym",
            "analysis_server",
        ],
        "FlutterDart2Wasm",
    )

    js_action = _find_action(env, ["FlutterDart2JS"])
    js_paths = _input_paths(js_action)
    _assert_some_path_contains(
        env,
        js_paths,
        [
            "web-sdk/kernel/dart2js_platform.dill",
            "web-sdk/libraries.json",
            "dart-sdk/bin/dart",
            "dart-sdk/bin/dartvm",
            "dart-sdk/bin/snapshots/dart2js",
            "dart-sdk/bin/snapshots/dartdev",
        ],
        "FlutterDart2JS",
    )
    _assert_no_path_contains(
        env,
        js_paths,
        [
            "/patched-sdk/",
            "/web-sdk/canvaskit/",
            "/web-sdk/lib/",
            "dart-sdk/lib/_internal/dart2js_platform.dill",
            "dart2wasm_platform.dill",
            "dart2wasm_product.snapshot",
            "dartdevc",
            "wasm-opt",
            "analysis_server",
        ],
        "FlutterDart2JS",
    )
    return analysistest.end(env)

def _assert_web_guarded(env, action, context):
    """A web compile runs behind `web_guard`, reads in place, and has its read set checked.

    `web_guard` refuses disallowed directives in the compile's main and
    sources before the compiler runs; the `--declared-inputs` manifest it
    checks against must be an action input. The compile reads every input in
    place: its multi-roots are the output directories of its generated inputs,
    then the exec root `.`, and no input is a staged copy. Because the exec
    root carries files the action did not declare, the compile wrapper gets
    the same manifest (`--declared-inputs=`) and checks the compiler's own
    dependency report against it.
    """
    argv = action.argv if action else []
    guards = [a for a in argv if a.split("/")[-1] in ("web_guard", "web_guard.exe")]
    asserts.equals(
        env,
        1,
        len(guards),
        "%s must run behind the web_guard executable, got argv %r" % (context, argv[:8]),
    )
    manifests = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--declared-inputs"]
    asserts.equals(
        env,
        1,
        len(manifests),
        "%s must carry --declared-inputs <manifest>, got %r" % (context, argv[:8]),
    )
    input_paths = [f.path for f in action.inputs.to_list()] if action else []
    if action and len(manifests) == 1:
        asserts.true(
            env,
            manifests[0] in input_paths,
            "%s --declared-inputs manifest %r must be an action input" % (context, manifests[0]),
        )
        asserts.true(
            env,
            any([p.split("/")[-1] in ("web_guard", "web_guard.exe") for p in input_paths]),
            "%s web_guard executable must be an action input" % context,
        )
        asserts.true(
            env,
            "--declared-inputs=" + manifests[0] in argv,
            "%s must hand the compile wrapper the same manifest, got %r" % (context, argv),
        )
    roots = []
    for i, a in enumerate(argv):
        if a == "--multi-root" and i + 1 < len(argv):
            roots.append(argv[i + 1])
        elif a.startswith("--multi-root="):
            roots.append(a.split("=", 1)[1])
    asserts.true(
        env,
        len(roots) > 0 and roots[-1] == ".",
        "%s must read its sources in place, the exec root last, got multi-roots %r" % (context, roots),
    )
    for root in roots[:-1]:
        asserts.true(
            env,
            root.startswith("bazel-out/") and root.endswith("/bin"),
            "%s mounts only output directories before the exec root, got %r" % (context, root),
        )
    asserts.equals(
        env,
        [],
        [p for p in input_paths if ".stage/" in p],
        "%s stages no input" % context,
    )

def _web_guard_inputs_test_impl(ctx):
    """`FlutterDart2Wasm` and `FlutterDart2JS` are guarded."""
    env = analysistest.begin(ctx)
    for mnemonic in ["FlutterDart2Wasm", "FlutterDart2JS"]:
        actions = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
        asserts.true(
            env,
            len(actions) > 0,
            "expected %s actions, got %s" % (mnemonic, [a.mnemonic for a in analysistest.target_actions(env)]),
        )
        for action in actions:
            _assert_web_guarded(env, action, mnemonic)
    return analysistest.end(env)

_web_guard_inputs_test = analysistest.make(_web_guard_inputs_test_impl)

def _pub_runfiles_test_impl(ctx):
    """`//flutter:pub` runfiles carry `dartdev`, not the full Dart/patched SDK."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runfile_paths = [f.path for f in target[DefaultInfo].default_runfiles.files.to_list()]

    _assert_some_path_contains(
        env,
        runfile_paths,
        [
            "dart-sdk/bin/dart",
            "dart-sdk/bin/snapshots/dartdev",
            "dart-sdk/version",
        ],
        "flutter_pub runfiles",
    )
    _assert_no_path_contains(
        env,
        runfile_paths,
        [
            "/patched-sdk/",
            "/dart-sdk/lib/",
            "dartdevc",
            "snapshots/analysis_server",
        ],
        "flutter_pub runfiles",
    )
    return analysistest.end(env)

_InspectActionsInfo = provider(
    doc = "Actions collected after `dart_analyze` and `dart_analyzer_summary` run.",
    fields = ["actions"],
)

def _inspect_analyze_actions_aspect_impl(target, _ctx):
    return [_InspectActionsInfo(actions = target.actions)]

_inspect_analyze_actions_aspect = aspect(
    implementation = _inspect_analyze_actions_aspect_impl,
    requires = [dart_analyze],
)

def _dart_toolchain_inputs_test_impl(ctx):
    """Bundled `dart_toolchain` stages `compile_files` for compile and `analyze_files` for analysis."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    all_actions = target[_InspectActionsInfo].actions

    for mnemonic in ["DartKernel", "DartCompile"]:
        compile_action = _find_action(env, [mnemonic])
        compile_paths = _input_paths(compile_action)
        _assert_some_path_contains(
            env,
            compile_paths,
            [
                "dart-sdk/bin/dart",
                "vm_platform_strong.dill",
            ],
            mnemonic,
        )
        _assert_no_path_contains(
            env,
            compile_paths,
            [
                "/patched-sdk/",
                "dart-sdk/bin/snapshots/analysis_server",
                "dart-sdk/bin/snapshots/dart2wasm",
                "dart-sdk/lib/core/",
            ],
            mnemonic,
        )

    analyze_found = [a for a in all_actions if a.mnemonic == "DartAnalyze"]
    asserts.equals(
        env,
        1,
        len(analyze_found),
        "expected one DartAnalyze action, got %s" % [a.mnemonic for a in all_actions],
    )
    analyze_paths = _input_paths(analyze_found[0] if analyze_found else None)
    _assert_some_path_contains(
        env,
        analyze_paths,
        [
            "dart-sdk/bin/snapshots/analysis_server",
            "dart-sdk/lib/core/",
        ],
        "DartAnalyze",
    )
    _assert_no_path_contains(
        env,
        analyze_paths,
        [
            "/patched-sdk/",
            "dart-sdk/bin/snapshots/dart2wasm",
            "dart-sdk/bin/utils/wasm-opt",
        ],
        "DartAnalyze",
    )
    return analysistest.end(env)

_RuleKindInfo = provider(
    doc = "Rule kind observed on a target.",
    fields = ["kind"],
)

def _inspect_rule_kind_aspect_impl(_target, ctx):
    return [_RuleKindInfo(kind = ctx.rule.kind)]

_inspect_rule_kind_aspect = aspect(
    implementation = _inspect_rule_kind_aspect_impl,
)

def _flutter_test_rule_kind_test_impl(ctx):
    """A `flutter_test` target has rule kind `flutter_test`.

    `bazel query --output=label_kind`, `kind(flutter_test, ...)` and
    `native.existing_rules()` report it so. `flutter_test` of `//flutter:defs.bzl`
    is a legacy macro over the rule of that name (it attaches a package's
    generated localizations), which keeps the kind.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        "flutter_test",
        target[_RuleKindInfo].kind,
        "a flutter_test target must have rule kind 'flutter_test', as query and native.existing_rules() report it",
    )
    return analysistest.end(env)

def _flutter_library_rule_kind_test_impl(ctx):
    """A `flutter_library` target has rule kind `flutter_library`.

    `bazel query --output=label_kind`, `kind(flutter_library, ...)` and
    `native.existing_rules()` report it so. `flutter_library` of `//flutter:defs.bzl`
    is a legacy macro over the rule of that name (it attaches a package's
    generated localizations), which keeps the kind.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        "flutter_library",
        target[_RuleKindInfo].kind,
        "a flutter_library target must have rule kind 'flutter_library', as query and native.existing_rules() report it",
    )
    return analysistest.end(env)

def _flutter_plugin_rule_kind_test_impl(ctx):
    """`flutter_plugin` is a first-class rule (`flutter_plugin rule`), not a wrapper macro."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        "rule",
        type(flutter_plugin),
        "flutter_plugin exported by //flutter:defs.bzl must be a rule",
    )
    asserts.equals(
        env,
        "flutter_plugin",
        target[_RuleKindInfo].kind,
        "flutter_plugin target must have rule kind 'flutter_plugin'",
    )
    return analysistest.end(env)

def _synthetic_dart_sdk_toolchain_impl(ctx):
    """Provides a synthetic standalone `@rules_dart` SDK distinct from Flutter's bundled SDK."""
    prefix = "synthetic_dart_sdk/"
    dart = ctx.actions.declare_file(prefix + "bin/dart")
    dartvm = ctx.actions.declare_file(prefix + "bin/dartvm")
    dartaotruntime = ctx.actions.declare_file(prefix + "bin/dartaotruntime")
    gen_kernel = ctx.actions.declare_file(prefix + "bin/snapshots/gen_kernel_aot.dart.snapshot")
    kernel_worker = ctx.actions.declare_file(prefix + "bin/snapshots/kernel_worker_aot.dart.snapshot")
    platform_dill = ctx.actions.declare_file(prefix + "lib/_internal/vm_platform_strong.dill")
    product_platform_dill = ctx.actions.declare_file(prefix + "lib/_internal/vm_platform_product.dill")
    libraries_json = ctx.actions.declare_file(prefix + "lib/libraries.json")

    all_files = [
        dart,
        dartvm,
        dartaotruntime,
        gen_kernel,
        kernel_worker,
        platform_dill,
        product_platform_dill,
        libraries_json,
    ]
    for f in all_files:
        ctx.actions.write(output = f, content = "", is_executable = f in (dart, dartvm, dartaotruntime))

    compile_files = depset(all_files)
    runtime_files = depset([dart, dartvm, platform_dill, libraries_json])
    dart_sdk_info = DartSdkInfo(
        dart = dart,
        sdk_root = None,
        version = "3.0.0-synthetic",
        # A library under an SDK without a module compiler fails at analysis; these
        # analysis tests run no module compile, so an empty file stands in for it.
        module_compiler = gen_kernel,
        tool_files = compile_files,
        compile_files = compile_files,
        runtime_files = runtime_files,
        analyze_files = compile_files,
        target_os = "",
        target_arch = "",
    )
    template_variables = platform_common.TemplateVariableInfo({"DART_BIN": dart.path})
    default = DefaultInfo(files = compile_files)
    return [
        default,
        platform_common.ToolchainInfo(
            dart_sdk_info = dart_sdk_info,
            template_variables = template_variables,
            default = default,
        ),
        template_variables,
    ]

_synthetic_dart_sdk_toolchain = rule(
    implementation = _synthetic_dart_sdk_toolchain_impl,
)

def _reverse_toolchain_flutter_test_impl(ctx):
    """When `@rules_dart`'s SDK resolves first, modular `flutter_test` still compiles with the Flutter SDK's own module compiler."""
    env = analysistest.begin(ctx)

    kernel_action = _find_action(env, ["DartKernel"])
    kernel_inputs = _input_paths(kernel_action)
    _assert_some_path_contains(
        env,
        kernel_inputs,
        [
            "dart-sdk/bin/dartaotruntime",
            "module_compiler.aot",
            "flutter_patched_sdk/platform_strong.dill",
            "fake_test_api.flutter.koutline",
        ],
        "reverse-toolchain flutter_test DartKernel inputs",
    )
    _assert_no_path_contains(
        env,
        kernel_inputs,
        ["synthetic_dart_sdk/bin/dartaotruntime"],
        "reverse-toolchain flutter_test DartKernel inputs",
    )
    argv_joined = " ".join(kernel_action.argv)
    asserts.true(
        env,
        "module_compiler.aot" in argv_joined and "synthetic_dart_sdk" not in argv_joined,
        "expected the Flutter SDK's module compiler in DartKernel argv, got %s" % kernel_action.argv,
    )
    asserts.true(
        env,
        "dart-sdk/bin/dartaotruntime" in argv_joined,
        "expected Flutter SDK dartaotruntime in DartKernel argv, got %s" % kernel_action.argv,
    )

    link_action = _find_action(env, ["DartKernelLink"])
    _assert_some_path_contains(
        env,
        _input_paths(link_action),
        ["fake_test_api.flutter.kmod"],
        "reverse-toolchain flutter_test DartKernelLink inputs",
    )
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "reverse-toolchain modular flutter_test must not fall back to FlutterKernelCompile")
    return analysistest.end(env)

def _reverse_toolchain_application_opt_fonts_test_impl(ctx):
    """When `@rules_dart`'s SDK resolves first, icon tree-shaking reads no Dart SDK."""
    env = analysistest.begin(ctx)
    asset_paths = _input_paths(_find_action(env, ["FlutterAssets"]))
    _assert_some_path_contains(
        env,
        asset_paths,
        ["font-subset"],
        "reverse-toolchain release FlutterAssets",
    )
    _assert_no_path_contains(
        env,
        asset_paths,
        ["synthetic_dart_sdk/"],
        "reverse-toolchain release FlutterAssets",
    )
    return analysistest.end(env)

def _reverse_toolchain_web_test_impl(ctx):
    """When `@rules_dart`'s SDK resolves first, `dart2wasm` and `dart2js` use Flutter's `dart-sdk/`."""
    env = analysistest.begin(ctx)

    for mnemonic in ["FlutterDart2Wasm", "FlutterDart2JS"]:
        action = _find_action(env, [mnemonic])
        paths = _input_paths(action)
        _assert_some_path_contains(
            env,
            paths,
            ["dart-sdk/bin/dart", "dart-sdk/bin/dartvm"],
            "reverse-toolchain " + mnemonic,
        )
        _assert_no_path_contains(
            env,
            paths,
            ["synthetic_dart_sdk/"],
            "reverse-toolchain " + mnemonic,
        )
    return analysistest.end(env)

_REVERSE_TOOLCHAIN_EXTRA_TOOLCHAINS = [
    str(Label("//flutter/tests:_synthetic_dart_exec_tools_toolchain")),
    str(Label("//flutter/tests:_synthetic_dart_toolchain")),
]

def _generated_tool_file_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.filename)
    ctx.actions.write(output = out, content = "", is_executable = True)
    return [DefaultInfo(files = depset([out]))]

_generated_tool_file = rule(
    implementation = _generated_tool_file_impl,
    attrs = {
        "filename": attr.string(mandatory = True),
    },
)

def _exec_font_subset_toolchain_test_impl(ctx):
    """App rules resolve `font_subset` in `exec` config from their own toolchain, independent of `deps`."""
    env = analysistest.begin(ctx)
    asset_paths = _input_paths(_find_action(env, ["FlutterAssets", "FlutterWebBundle"]))
    _assert_some_path_contains(
        env,
        asset_paths,
        ["exec_font_subset"],
        "exec-configured font_subset_toolchain bundle",
    )
    for p in [p for p in asset_paths if p.endswith("exec_font_subset")]:
        asserts.true(env, "-exec-" in p, "expected font-subset tool %r in exec cfg" % p)
    if flutter_line(ctx).icon_tree_shaker == "const_finder":
        _assert_some_path_contains(env, asset_paths, ["exec_const_finder.dart.snapshot"], "exec-configured const_finder")
        for p in [p for p in asset_paths if p.endswith("exec_const_finder.dart.snapshot")]:
            asserts.true(env, "-exec-" in p, "expected const_finder tool %r in exec cfg" % p)
    return analysistest.end(env)

def _missing_font_subset_toolchain_test_impl(ctx):
    """App rules fail with a named error when icon tree shaking is active and font-subset is unavailable for the exec platform."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "font-subset")
    return analysistest.end(env)

_EXEC_FONT_SUBSET_EXTRA_TOOLCHAINS = [
    str(Label("//flutter/tests:_exec_font_subset_registered_toolchain")),
]
_EMPTY_FONT_SUBSET_EXTRA_TOOLCHAINS = [
    str(Label("//flutter/tests:_empty_font_subset_registered_toolchain")),
]

_flutter_test_rule_kind_test = analysistest.make(
    _flutter_test_rule_kind_test_impl,
    extra_target_under_test_aspects = [_inspect_rule_kind_aspect],
)
_flutter_library_rule_kind_test = analysistest.make(
    _flutter_library_rule_kind_test_impl,
    extra_target_under_test_aspects = [_inspect_rule_kind_aspect],
)
_flutter_plugin_rule_kind_test = analysistest.make(
    _flutter_plugin_rule_kind_test_impl,
    extra_target_under_test_aspects = [_inspect_rule_kind_aspect],
)
_flutter_test_runfiles_test = analysistest.make(_flutter_test_runfiles_test_impl)
_flutter_test_defines_modular_test = analysistest.make(_flutter_test_defines_modular_test_impl)

# A comma in a global define changes nothing for a `flutter_test`: it stays modular.
_flutter_test_comma_modular_test = analysistest.make(
    _flutter_test_comma_modular_test_impl,
    config_settings = {str(Label("//flutter:extra_dart_defines")): ["FOO=a,b"]},
)
_flutter_comma_defines_fallback_test = analysistest.make(
    _comma_defines_fallback_test_impl,
    config_settings = {str(Label("//flutter:extra_dart_defines")): ["FOO=a,b"]},
)
_dart_extra_defines_ignored_test = analysistest.make(
    _dart_extra_defines_ignored_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
        str(Label("@rules_dart//dart:extra_dart_defines")): ["FROM_DART=1", "dart.vm.product=true"],
    },
)
_OPT = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): False}
_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_FASTBUILD = {"//command_line_option:compilation_mode": "fastbuild", str(Label("//flutter:profile")): False}

_application_opt_inputs_test = analysistest.make(_application_opt_inputs_test_impl, config_settings = _OPT)
_application_opt_bundle_inputs_test = analysistest.make(_application_opt_bundle_inputs_test_impl, attrs = FLUTTER_LINE_ATTR, config_settings = _OPT)
_application_dbg_bundle_inputs_test = analysistest.make(_application_dbg_bundle_inputs_test_impl, config_settings = _DBG)
_application_no_tree_shake_icons_test = analysistest.make(
    _application_no_tree_shake_icons_test_impl,
    config_settings = _OPT,
)
_aot_target_inputs_test = analysistest.make(_aot_target_inputs_test_impl, config_settings = _OPT)
_aot_target_dbg_inputs_test = analysistest.make(_aot_target_dbg_inputs_test_impl, config_settings = _DBG)
_kernel_target_opt_test = analysistest.make(_kernel_target_release_aot_test_impl, config_settings = _OPT)
_kernel_target_fastbuild_test = analysistest.make(_kernel_target_release_aot_test_impl, config_settings = _FASTBUILD)
_kernel_target_dbg_test = analysistest.make(_kernel_target_dbg_test_impl, config_settings = _DBG)
_kernel_target_aot_test = analysistest.make(_kernel_target_aot_test_impl)
_kernel_target_aot_dbg_test = analysistest.make(_kernel_target_aot_dbg_test_impl, config_settings = _DBG)
_web_inputs_test = analysistest.make(_web_inputs_test_impl, config_settings = _OPT)
_pub_runfiles_test = analysistest.make(_pub_runfiles_test_impl)
_dart_toolchain_inputs_test = analysistest.make(
    _dart_toolchain_inputs_test_impl,
    extra_target_under_test_aspects = [_inspect_analyze_actions_aspect],
)
_reverse_toolchain_flutter_test = analysistest.make(
    _reverse_toolchain_flutter_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": _REVERSE_TOOLCHAIN_EXTRA_TOOLCHAINS,
    },
)
_reverse_toolchain_application_opt_fonts_test = analysistest.make(
    _reverse_toolchain_application_opt_fonts_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _REVERSE_TOOLCHAIN_EXTRA_TOOLCHAINS,
        str(Label("//flutter:profile")): False,
    },
)
_reverse_toolchain_web_test = analysistest.make(
    _reverse_toolchain_web_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _REVERSE_TOOLCHAIN_EXTRA_TOOLCHAINS,
        str(Label("//flutter:profile")): False,
    },
)
_exec_font_subset_toolchain_test = analysistest.make(
    _exec_font_subset_toolchain_test_impl,
    attrs = FLUTTER_LINE_ATTR,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _EXEC_FONT_SUBSET_EXTRA_TOOLCHAINS,
        str(Label("//flutter:profile")): False,
    },
)
_missing_font_subset_toolchain_test = analysistest.make(
    _missing_font_subset_toolchain_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _EMPTY_FONT_SUBSET_EXTRA_TOOLCHAINS,
        str(Label("//flutter:profile")): False,
    },
)

def _setup_fixtures():
    _synthetic_dart_sdk_toolchain(
        name = "_synthetic_dart_sdk",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_synthetic_dart_exec_tools_toolchain",
        toolchain = ":_synthetic_dart_sdk",
        toolchain_type = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    native.toolchain(
        name = "_synthetic_dart_toolchain",
        toolchain = ":_synthetic_dart_sdk",
        toolchain_type = "@rules_dart//dart:toolchain_type",
    )
    _generated_tool_file(
        name = "_generated_exec_const_finder",
        filename = "exec_const_finder.dart.snapshot",
        tags = ["manual"],
    )
    _generated_tool_file(
        name = "_generated_exec_font_subset",
        filename = "exec_font_subset",
        tags = ["manual"],
    )
    flutter_font_subset_toolchain(
        name = "_exec_font_subset_tc",
        const_finder = ":_generated_exec_const_finder",
        font_subset = ":_generated_exec_font_subset",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_exec_font_subset_registered_toolchain",
        toolchain = ":_exec_font_subset_tc",
        toolchain_type = "//flutter/private:font_subset_toolchain_type",
    )
    flutter_font_subset_toolchain(
        name = "_empty_font_subset_tc",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_empty_font_subset_registered_toolchain",
        toolchain = ":_empty_font_subset_tc",
        toolchain_type = "//flutter/private:font_subset_toolchain_type",
    )
    flutter_application(
        name = "_inputs_application_bare_fonts",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_inputs_web_bundle_bare_fonts",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_test(
        name = "_inputs_flutter_test",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    existing_flutter_test = native.existing_rule("_inputs_flutter_test")
    if existing_flutter_test == None or existing_flutter_test.get("kind") != "flutter_test":
        fail("expected native.existing_rule('_inputs_flutter_test')['kind'] == 'flutter_test', got %r" % (
            existing_flutter_test.get("kind") if existing_flutter_test else None,
        ))
    flutter_library(
        name = "_inputs_flutter_library",
        srcs = [_MAIN],
        tags = ["manual"],
    )
    existing_flutter_library = native.existing_rule("_inputs_flutter_library")
    if existing_flutter_library == None or existing_flutter_library.get("kind") != "flutter_library":
        fail("expected native.existing_rule('_inputs_flutter_library')['kind'] == 'flutter_library', got %r" % (
            existing_flutter_library.get("kind") if existing_flutter_library else None,
        ))
    flutter_library(
        name = "_inputs_flutter_library_fonts",
        srcs = [_MAIN],
        tags = ["manual"],
    )
    existing_flutter_library_fonts = native.existing_rule("_inputs_flutter_library_fonts")
    if existing_flutter_library_fonts == None or existing_flutter_library_fonts.get("kind") != "flutter_library":
        fail("expected native.existing_rule('_inputs_flutter_library_fonts')['kind'] == 'flutter_library', got %r" % (
            existing_flutter_library_fonts.get("kind") if existing_flutter_library_fonts else None,
        ))
    flutter_plugin(
        name = "_inputs_flutter_plugin",
        srcs = [_MAIN],
        tags = ["manual"],
    )
    existing_flutter_plugin = native.existing_rule("_inputs_flutter_plugin")
    if existing_flutter_plugin == None or existing_flutter_plugin.get("kind") != "flutter_plugin":
        fail("expected native.existing_rule('_inputs_flutter_plugin')['kind'] == 'flutter_plugin', got %r" % (
            existing_flutter_plugin.get("kind") if existing_flutter_plugin else None,
        ))
    flutter_plugin(
        name = "_inputs_flutter_plugin_fonts",
        srcs = [_MAIN],
        tags = ["manual"],
    )
    existing_flutter_plugin_fonts = native.existing_rule("_inputs_flutter_plugin_fonts")
    if existing_flutter_plugin_fonts == None or existing_flutter_plugin_fonts.get("kind") != "flutter_plugin":
        fail("expected native.existing_rule('_inputs_flutter_plugin_fonts')['kind'] == 'flutter_plugin', got %r" % (
            existing_flutter_plugin_fonts.get("kind") if existing_flutter_plugin_fonts else None,
        ))
    flutter_test(
        name = "_inputs_flutter_test_defines",
        package_name = _PACKAGE,
        main = _MAIN,
        defines = ["FOO=1"],
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_application(
        name = "_inputs_application",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_application(
        name = "_inputs_application_with_fonts",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_application(
        name = "_inputs_application_with_fonts_no_tree_shake",
        package_name = _PACKAGE,
        main = _MAIN,
        tree_shake_icons = False,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_inputs_aot_target",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_inputs_kernel_target",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_kernel_target(
        name = "_inputs_kernel_target_aot",
        package_name = _PACKAGE,
        main = _MAIN,
        aot = True,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_web_bundle(
        name = "_inputs_web_bundle",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    dart_binary(
        name = "_inputs_dart_binary",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        target_compatible_with = HOST_COMPATIBLE,
    )

def action_inputs_test_suite(name):
    """Defines analysis tests for trimmed action inputs and test runfiles.

    Args:
        name: The test_suite target name.
    """
    _setup_fixtures()

    _flutter_test_rule_kind_test(
        name = name + "_flutter_test_rule_kind",
        target_under_test = ":_inputs_flutter_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _flutter_library_rule_kind_test(
        name = name + "_flutter_library_rule_kind",
        target_under_test = ":_inputs_flutter_library",
    )
    _flutter_library_rule_kind_test(
        name = name + "_flutter_library_fonts_rule_kind",
        target_under_test = ":_inputs_flutter_library_fonts",
    )
    _flutter_plugin_rule_kind_test(
        name = name + "_flutter_plugin_rule_kind",
        target_under_test = ":_inputs_flutter_plugin",
    )
    _flutter_plugin_rule_kind_test(
        name = name + "_flutter_plugin_fonts_rule_kind",
        target_under_test = ":_inputs_flutter_plugin_fonts",
    )
    _flutter_test_runfiles_test(
        name = name + "_flutter_test_runfiles",
        target_under_test = ":_inputs_flutter_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _flutter_test_defines_modular_test(
        name = name + "_flutter_test_defines_modular",
        target_under_test = ":_inputs_flutter_test_defines",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _flutter_test_comma_modular_test(
        name = name + "_flutter_test_comma_modular",
        target_under_test = ":_inputs_flutter_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _dart_extra_defines_ignored_test(
        name = name + "_flutter_test_dart_extra_defines_ignored",
        target_under_test = ":_inputs_flutter_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _flutter_comma_defines_fallback_test(
        name = name + "_kernel_target_comma_defines_fallback",
        target_under_test = ":_inputs_kernel_target",
    )
    _dart_extra_defines_ignored_test(
        name = name + "_kernel_target_dart_extra_defines_ignored",
        target_under_test = ":_inputs_kernel_target",
    )
    _application_opt_inputs_test(
        name = name + "_application_opt",
        target_under_test = ":_inputs_application",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_opt_bundle_inputs_test(
        name = name + "_application_opt_bundle",
        target_under_test = ":_inputs_application_with_fonts",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_dbg_bundle_inputs_test(
        name = name + "_application_dbg_bundle",
        target_under_test = ":_inputs_application_with_fonts",
    )
    _application_no_tree_shake_icons_test(
        name = name + "_application_no_tree_shake",
        target_under_test = ":_inputs_application_with_fonts_no_tree_shake",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _aot_target_inputs_test(
        name = name + "_aot_target",
        target_under_test = ":_inputs_aot_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _aot_target_dbg_inputs_test(
        name = name + "_aot_target_dbg",
        target_under_test = ":_inputs_aot_target",
    )
    _kernel_target_opt_test(
        name = name + "_kernel_target_opt",
        target_under_test = ":_inputs_kernel_target",
    )
    _kernel_target_fastbuild_test(
        name = name + "_kernel_target_fastbuild",
        target_under_test = ":_inputs_kernel_target",
    )
    _kernel_target_dbg_test(
        name = name + "_kernel_target_dbg",
        target_under_test = ":kernel_target_modular_twin",
    )
    _kernel_target_aot_test(
        name = name + "_kernel_target_aot",
        target_under_test = ":_inputs_kernel_target_aot",
    )
    _kernel_target_aot_dbg_test(
        name = name + "_kernel_target_aot_dbg",
        target_under_test = ":_inputs_kernel_target_aot",
    )
    _web_inputs_test(
        name = name + "_web",
        target_under_test = ":_inputs_web_bundle",
    )
    _web_guard_inputs_test(
        name = name + "_web_guard",
        target_under_test = ":_inputs_web_bundle",
    )
    _web_guard_inputs_test(
        name = name + "_web_guard_fonts",
        target_under_test = ":_inputs_web_bundle_bare_fonts",
    )
    _pub_runfiles_test(
        name = name + "_pub",
        target_under_test = "//flutter:pub",
    )
    _dart_toolchain_inputs_test(
        name = name + "_dart_toolchain",
        target_under_test = ":_inputs_dart_binary",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _reverse_toolchain_flutter_test(
        name = name + "_reverse_toolchain_flutter_test",
        target_under_test = ":_inputs_flutter_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _reverse_toolchain_application_opt_fonts_test(
        name = name + "_reverse_toolchain_application_opt_fonts",
        target_under_test = ":_inputs_application_with_fonts",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _reverse_toolchain_web_test(
        name = name + "_reverse_toolchain_web",
        target_under_test = ":_inputs_web_bundle",
    )
    _exec_font_subset_toolchain_test(
        name = name + "_exec_font_subset_application",
        target_under_test = ":_inputs_application_bare_fonts",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _exec_font_subset_toolchain_test(
        name = name + "_exec_font_subset_web",
        target_under_test = ":_inputs_web_bundle_bare_fonts",
    )
    _missing_font_subset_toolchain_test(
        name = name + "_missing_font_subset_application",
        target_under_test = ":_inputs_application_bare_fonts",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _missing_font_subset_toolchain_test(
        name = name + "_missing_font_subset_web",
        target_under_test = ":_inputs_web_bundle_bare_fonts",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flutter_test_rule_kind",
            ":" + name + "_flutter_library_rule_kind",
            ":" + name + "_flutter_library_fonts_rule_kind",
            ":" + name + "_flutter_plugin_rule_kind",
            ":" + name + "_flutter_plugin_fonts_rule_kind",
            ":" + name + "_flutter_test_runfiles",
            ":" + name + "_flutter_test_defines_modular",
            ":" + name + "_flutter_test_comma_modular",
            ":" + name + "_flutter_test_dart_extra_defines_ignored",
            ":" + name + "_kernel_target_comma_defines_fallback",
            ":" + name + "_kernel_target_dart_extra_defines_ignored",
            ":" + name + "_application_opt",
            ":" + name + "_application_opt_bundle",
            ":" + name + "_application_dbg_bundle",
            ":" + name + "_application_no_tree_shake",
            ":" + name + "_aot_target",
            ":" + name + "_aot_target_dbg",
            ":" + name + "_kernel_target_opt",
            ":" + name + "_kernel_target_fastbuild",
            ":" + name + "_kernel_target_dbg",
            ":" + name + "_kernel_target_aot",
            ":" + name + "_kernel_target_aot_dbg",
            ":" + name + "_web",
            ":" + name + "_web_guard",
            ":" + name + "_web_guard_fonts",
            ":" + name + "_pub",
            ":" + name + "_dart_toolchain",
            ":" + name + "_reverse_toolchain_flutter_test",
            ":" + name + "_reverse_toolchain_application_opt_fonts",
            ":" + name + "_reverse_toolchain_web",
            ":" + name + "_exec_font_subset_application",
            ":" + name + "_exec_font_subset_web",
            ":" + name + "_missing_font_subset_application",
            ":" + name + "_missing_font_subset_web",
        ],
    )
