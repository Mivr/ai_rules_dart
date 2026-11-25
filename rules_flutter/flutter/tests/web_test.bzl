"""Unit tests for web application helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")
load(
    "//flutter/private:flutter_web_compile.bzl",
    "default_dart2js_optimization_level",
    "default_dart2wasm_optimization_level",
    "flutter_dart2js_action",
    "make_dart2js_request",
    "resolve_web_minify",
    "resolve_web_optimization_level",
    "web_canvaskit_url_defines",
    "web_mode_defines",
)
load(
    "//flutter/private:flutter_web_sdk_repo.bzl",
    "flutter_web_sdk_repo_impl",
    "generate_web_sdk_build",
    "resolve_web_sdk_host_repos",
    "rewrite_web_sdk_libraries_json",
)
load("//flutter/private:validation.bzl", "escape_html", "is_valid_web_compiler_renderer", "web_renderer")
load(
    "//flutter/private:web_stubs.bzl",
    "make_web_plugins_stub_content",
    "make_web_ui_web_stub_content",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")
load(":action_content.bzl", "written_json")

visibility(["//flutter/tests/..."])

def _html_title_escaping_test_impl(ctx):
    """Test that HTML special characters in titles are properly escaped."""
    env = unittest.begin(ctx)

    test_cases = [
        ("My App", "My App"),
        ("App & Co", "App &amp; Co"),
        ("<script>", "&lt;script&gt;"),
        ('He said "hi"', "He said &quot;hi&quot;"),
        ("Normal Title", "Normal Title"),
    ]

    for title, expected in test_cases:
        asserts.equals(env, expected, escape_html(title), "Escaping '%s'" % title)

    return unittest.end(env)

def _web_compiler_renderer_validation_test_impl(ctx):
    """Test that invalid compiler+renderer combos are rejected."""
    env = unittest.begin(ctx)

    # Valid combinations.
    asserts.true(env, is_valid_web_compiler_renderer("dart2wasm", "skwasm"), "dart2wasm+skwasm should be valid")
    asserts.true(env, is_valid_web_compiler_renderer("dart2wasm", "canvaskit"), "dart2wasm+canvaskit should be valid")
    asserts.true(env, is_valid_web_compiler_renderer("dart2js", "canvaskit"), "dart2js+canvaskit should be valid")

    # Invalid: dart2js cannot use skwasm (skwasm requires wasm).
    asserts.false(env, is_valid_web_compiler_renderer("dart2js", "skwasm"), "dart2js+skwasm should be invalid")

    return unittest.end(env)

def _web_renderer_default_test_impl(ctx):
    """An unset renderer follows the compiler; a named one is kept."""
    env = unittest.begin(ctx)
    asserts.equals(env, "skwasm", web_renderer("dart2wasm", ""))
    asserts.equals(env, "canvaskit", web_renderer("dart2js", ""))
    asserts.equals(env, "canvaskit", web_renderer("dart2wasm", "canvaskit"))

    # Named and wrong is still refused, by the validation above.
    asserts.equals(env, "skwasm", web_renderer("dart2js", "skwasm"))
    return unittest.end(env)

_t0_test = unittest.make(_html_title_escaping_test_impl)
_t1_test = unittest.make(_web_compiler_renderer_validation_test_impl)
_t5_test = unittest.make(_web_renderer_default_test_impl)

# -- Analysis tests over the flutter_web_bundle rule -------------------------
#
# These read the actual dart2wasm/dart2js command lines and declared outputs
# of fixture targets, in a pinned compilation mode, so that the defines a web
# build carries per mode — and the `-c dbg` dev-loop contract (dev config +
# DDC side-files) — are asserted where they live rather than inferred.

def _action(env, mnemonic):
    """The single action with `mnemonic` on the target under test."""
    found = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(found), "expected exactly one %s action" % mnemonic)
    return found[0] if found else None

def _assert_argv(env, action, present = [], absent_substrings = []):
    """Assert exact args present and substrings absent on an action's argv."""
    if action == None:
        return
    argv = action.argv
    for arg in present:
        asserts.true(env, arg in argv, "%r missing from %s argv: %s" % (arg, action.mnemonic, argv))
    for sub in absent_substrings:
        matches = [a for a in argv if sub in a]
        asserts.equals(env, [], matches, "%r must not appear in %s argv" % (sub, action.mnemonic))

def _assert_optimization_level(env, action, expected):
    """Assert the action states exactly one `-O`, and that it is `expected`.

    Asserted as "exactly one" rather than "contains": both compilers default
    to `-O1` when the flag is absent, so a level that fails to reach the
    command line is not a neutral outcome, and a second `-O` would silently
    win over the first.

    Args:
        env: The analysistest env.
        action: The action to read, from `_action`.
        expected: The level as an int.
    """
    if action == None:
        return
    levels = [a for a in action.argv if a.startswith("-O")]
    asserts.equals(
        env,
        ["-O%d" % expected],
        levels,
        "%s must state exactly one optimization level" % action.mnemonic,
    )

def _assert_dart2js_platform_binaries(env, action):
    """Assert dart2js receives `--platform-binaries=<.../web-sdk/kernel>` and exec-platform `--libraries-spec`."""
    if action == None:
        return
    flags = [a for a in action.argv if a.startswith("--platform-binaries=")]
    asserts.equals(
        env,
        1,
        len(flags),
        "FlutterDart2JS must state --platform-binaries once: %s" % action.argv,
    )
    if flags:
        asserts.true(
            env,
            flags[0].endswith("/web-sdk/kernel"),
            "--platform-binaries must point at web-sdk/kernel, got %r" % flags[0],
        )
    spec_flags = [a for a in action.argv if a.startswith("--libraries-spec=")]
    asserts.equals(
        env,
        1,
        len(spec_flags),
        "FlutterDart2JS must state --libraries-spec once: %s" % action.argv,
    )
    if spec_flags:
        asserts.false(
            env,
            spec_flags[0].endswith("/web-sdk/libraries.json"),
            "--libraries-spec must select exec-platform libraries.<platform>.json, got %r" % spec_flags[0],
        )
        asserts.true(
            env,
            "/web-sdk/libraries." in spec_flags[0] and spec_flags[0].endswith(".json"),
            "--libraries-spec must point at web-sdk/libraries.<platform>.json, got %r" % spec_flags[0],
        )
    input_paths = [f.path for f in action.inputs.to_list()]
    asserts.true(
        env,
        any(["/web-sdk/libraries." in p and not p.endswith("/web-sdk/libraries.json") for p in input_paths]),
        "FlutterDart2JS inputs must contain exec-platform web-sdk/libraries.<platform>.json: %s" % input_paths,
    )
    asserts.true(
        env,
        any([p.endswith("/dart-sdk/lib/libraries.json") for p in input_paths]),
        "FlutterDart2JS inputs must contain the exec platform's dart-sdk/lib/libraries.json: %s" % input_paths,
    )

def _default_basenames(env):
    target = analysistest.target_under_test(env)
    return [f.basename for f in target[DefaultInfo].files.to_list()]

def _dbg_web_defines_test_impl(ctx):
    """A `-c dbg` web build is a debug build: no product define, asserts on.

    Both compilers are checked — the dart2js fallback ships in the same
    bundle, and a fallback silently compiled as release would be the same bug
    reappearing on WASM-less browsers.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = [
            "--extra-compiler-option=--enable-asserts",
            "--no-minify",
            # Debug shipped stripped until `strip_wasm` was gated on release.
            # A stripped debug WASM is a stack trace with no names in it.
            "--no-strip-wasm",
        ],
        # `toString()` bodies have to survive a debug build: dropping them is
        # what makes `'$widget'` stop naming the type, and debug is where that
        # output is read.
        absent_substrings = ["dart.vm.product", "dart.vm.profile", "delete-tostring"],
    )
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["--enable-asserts", "--no-minify", "--native-null-assertions"],
        absent_substrings = ["dart.vm.product", "dart.vm.profile", "frequency-based"],
    )

    # Upstream's debug levels, which the two compilers disagree about: dart2js
    # stops at 1 because level 0 "is not well supported" there, while dart2wasm
    # takes 0 — it compiles a debug app in half the time for twice the output,
    # which is the trade a debug build exists to make. Both were 2 until this
    # was corrected, which is what minified debug JS before `--no-minify` was
    # stated outright.
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 0)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 1)

    # The dbg outputs still carry the DDC side-files.
    basenames = _default_basenames(env)
    for expected in [
        "_web_fixture_ddc_outline.dill",
        "_web_fixture_ddc_libraries.json",
        "_web_fixture_ddc_dart_sdk.js",
        "_web_fixture_ddc_module_loader.js",
        "_web_fixture_ddc_stack_trace_mapper.js",
        "_web_fixture_dev_flutter_bootstrap.js",
    ]:
        asserts.true(env, expected in basenames, "%s missing from dbg outputs: %s" % (expected, basenames))
    return analysistest.end(env)

_dbg_web_defines_test = analysistest.make(
    _dbg_web_defines_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
    },
)

def _profile_web_defines_test_impl(ctx):
    """`profile = True` is its own mode, and neither of the other two.

    Asserted from a `-c dbg` configuration on purpose: the attr overrides the
    compilation-mode mapping, so a profile build assembled under `-c dbg` must
    still come out as profile. An implementation that only special-cased
    `-c opt` would pass an opt-configured version of this test.
    """
    env = analysistest.begin(ctx)

    # dart2wasm: profile carries its own define, and the release-shaped
    # `toString()` stripping that makes it representative of release.
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = [
            "-Ddart.vm.profile=true",
            # Left unminified and unstripped on purpose: a profile build
            # exists to be read, and upstream gates both on release.
            "--no-minify",
            "--no-strip-wasm",
            "--extra-compiler-option=--delete-tostring-package-uri=dart:ui",
            "--extra-compiler-option=--delete-tostring-package-uri=package:flutter",
        ],
        absent_substrings = ["enable-asserts", "dart.vm.product"],
    )

    # dart2js gets the define but not the tostring options — upstream's
    # `Dart2JSTarget` has no equivalent, and dart2js would reject them.
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["-Ddart.vm.profile=true", "--no-minify", "--native-null-assertions"],
        absent_substrings = ["enable-asserts", "dart.vm.product", "delete-tostring"],
    )

    # A profile build optimizes exactly as release does — it exists to measure
    # release, so a lower level here would measure something nobody ships.
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 2)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 4)

    # A profile build is not a dev-loop build: nothing may serve it as one.
    for basename in _default_basenames(env):
        asserts.false(
            env,
            "dev_config" in basename or "_ddc_" in basename,
            "dev-loop file %s leaked into a profile build" % basename,
        )
    return analysistest.end(env)

_profile_web_defines_test = analysistest.make(
    _profile_web_defines_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
    },
)

def _opt_web_defines_test_impl(ctx):
    """A `-c opt` web build is a release build: product define, no asserts."""
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = [
            "-Ddart.vm.product=true",
            "--minify",
            "--strip-wasm",
            # Release drops `toString()` bodies upstream. Missing here until
            # profile mode landed, which is why it is pinned in both modes
            # that carry it rather than only in the new one.
            "--extra-compiler-option=--delete-tostring-package-uri=dart:ui",
            "--extra-compiler-option=--delete-tostring-package-uri=package:flutter",
        ],
        absent_substrings = ["enable-asserts", "dart.vm.profile"],
    )
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["-Ddart.vm.product=true", "--minify", "--native-null-assertions"],
        absent_substrings = ["enable-asserts", "dart.vm.profile"],
    )
    _assert_dart2js_platform_binaries(env, _action(env, "FlutterDart2JS"))

    # The release levels, and the reason they differ: dart2js goes to 4, while
    # dart2wasm stops at 2 because that is the highest level using only sound
    # optimizations and upstream's benchmarks put the rest at marginal. A
    # single shared level cannot state both, which is why there is no single
    # shared attr.
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 2)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 4)

    # Release output is the bundle directory alone — none of the dev-loop
    # side-files may leak into it.
    for basename in _default_basenames(env):
        asserts.false(
            env,
            "dev_config" in basename or "_ddc_" in basename,
            "dev-loop file %s leaked into release outputs" % basename,
        )

    # A release web bundle with no fonts and no language experiments skips the
    # redundant icon tree-shaking kernel compile.
    asserts.equals(
        env,
        [],
        [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"],
        "a fontless release web build must skip FlutterKernelCompile",
    )
    return analysistest.end(env)

_opt_web_defines_test = analysistest.make(
    _opt_web_defines_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _fastbuild_web_defines_test_impl(ctx):
    """A `fastbuild` web build is a release build: product define, no asserts, and `-O2` on dart2wasm.

    `fastbuild` maps to `"release"` in `flutter_build_mode`, so both `fastbuild`
    and `opt` web builds use `dart2wasm`'s release optimization level (`-O2`)
    and `dart2js`'s release optimization level (`-O4`), matching upstream's
    `flutter build web --wasm` release configuration.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = [
            "-Ddart.vm.product=true",
            "--minify",
            "--strip-wasm",
            "--extra-compiler-option=--delete-tostring-package-uri=dart:ui",
            "--extra-compiler-option=--delete-tostring-package-uri=package:flutter",
        ],
        absent_substrings = ["enable-asserts", "dart.vm.profile", "--no-minify", "--no-strip-wasm"],
    )
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["-Ddart.vm.product=true", "--minify", "--native-null-assertions"],
        absent_substrings = ["enable-asserts", "dart.vm.profile", "--no-minify"],
    )
    _assert_dart2js_platform_binaries(env, _action(env, "FlutterDart2JS"))
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 2)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 4)
    return analysistest.end(env)

_fastbuild_web_defines_test = analysistest.make(
    _fastbuild_web_defines_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "fastbuild",
        str(Label("//flutter:profile")): False,
    },
)

_profile_flag_web_defines_test = analysistest.make(
    _profile_web_defines_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): True,
    },
)

def _wasm_source_map_test_impl(ctx):
    """`source_maps = True` declares main.dart.wasm.map and ships it.

    dart2wasm writes `<output>.map` and embeds a sourceMappingURL pointing at
    that basename, so the declared output and the bundled name must both be
    exactly `main.dart.wasm.map`.
    """
    env = analysistest.begin(ctx)
    wasm_action = _action(env, "FlutterDart2Wasm")
    _assert_argv(env, wasm_action, absent_substrings = ["--no-source-maps"])
    out_basenames = [f.basename for f in wasm_action.outputs.to_list()] if wasm_action else []
    asserts.true(
        env,
        "main.dart.wasm.map" in out_basenames,
        "main.dart.wasm.map not declared by dart2wasm action: %s" % out_basenames,
    )
    return analysistest.end(env)

_wasm_source_map_test = analysistest.make(_wasm_source_map_test_impl)

def _wasm_no_source_map_test_impl(ctx):
    """Without `source_maps` the compile is told so and declares no map."""
    env = analysistest.begin(ctx)
    wasm_action = _action(env, "FlutterDart2Wasm")
    _assert_argv(env, wasm_action, present = ["--no-source-maps"])
    out_basenames = [f.basename for f in wasm_action.outputs.to_list()] if wasm_action else []
    for basename in out_basenames:
        asserts.false(env, basename.endswith(".map"), "unexpected source map output %s" % basename)
    return analysistest.end(env)

_wasm_no_source_map_test = analysistest.make(_wasm_no_source_map_test_impl)

def _minify_override_test_impl(ctx):
    """An explicit `minify_*` beats the mode, in both directions at once.

    Read from `-c dbg`, where "auto" would give both compilers `--no-minify`.
    The fixture asks for the opposite of that on one compiler and the same as
    it on the other, so an implementation that ignored the attr, or that
    applied one compiler's value to both, fails here.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["--minify"],
        absent_substrings = ["--no-minify"],
    )
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = ["--no-minify"],
    )
    return analysistest.end(env)

_minify_override_test = analysistest.make(
    _minify_override_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
    },
)

def _optimization_override_test_impl(ctx):
    """An explicit `optimization_level_*` beats the mode, on one compiler only.

    Read from `-c dbg`, where "auto" would give dart2js 1 and dart2wasm 0. The
    fixture asks dart2js for 3 and leaves dart2wasm alone, so an
    implementation that ignored the attr, or that let one compiler's value
    reach both, fails here — and 3 is a level neither compiler's default ever
    produces in any mode, so it cannot be arrived at by accident.
    """
    env = analysistest.begin(ctx)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 3)
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 0)
    return analysistest.end(env)

_optimization_override_test = analysistest.make(
    _optimization_override_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): False,
    },
)

def _optimization_zero_test_impl(ctx):
    """`"0"` reaches the command line rather than being read as "unset".

    Both compilers default to `-O1` when no `-O` is passed, so a level of 0
    that fails to appear is not a no-op — it is a build quietly running one
    level higher than it was told to. Asserted in `-c opt`, where the mode
    default for both compilers is something other than 0.
    """
    env = analysistest.begin(ctx)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 0)
    _assert_optimization_level(env, _action(env, "FlutterDart2Wasm"), 0)
    return analysistest.end(env)

_optimization_zero_test = analysistest.make(
    _optimization_zero_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _js_only_settings_test_impl(ctx):
    """The dart2js settings reach the compile a `dart2js` target actually runs.

    Every other assertion here reads a `compiler = "dart2wasm"` target, whose
    dart2js action is the *fallback*. That leaves the JS-only call site — a
    separate call in the rule — pinned by nothing: dropping its settings there
    keeps every other test green while an explicit level or minify choice on a
    `compiler = "dart2js"` target silently reaches nothing, which is the class
    of bug this ruleset refuses at analysis time rather than ships.

    Read from `-c opt`, where the defaults are 4 and `--minify`, so the
    fixture's 3 and `--no-minify` cannot be arrived at by ignoring it.
    """
    env = analysistest.begin(ctx)
    _assert_optimization_level(env, _action(env, "FlutterDart2JS"), 3)
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ["--no-minify"],
    )

    # There is no second compile to have taken the settings instead.
    asserts.equals(
        env,
        [],
        [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterDart2Wasm"],
        "a dart2js target must run no wasm compile",
    )
    return analysistest.end(env)

_js_only_settings_test = analysistest.make(
    _js_only_settings_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _optimization_wasm_on_js_refused_test_impl(ctx):
    """The wasm-only refusal covers the wasm optimization level too."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "optimization_level_wasm")
    asserts.expect_failure(env, "compiler = \"dart2wasm\"")
    return analysistest.end(env)

_optimization_wasm_on_js_refused_test = analysistest.make(
    _optimization_wasm_on_js_refused_test_impl,
    expect_failure = True,
)

def _js_flags_test_impl(ctx):
    """The dart2js-only flags reach dart2js, and only dart2js.

    One fixture carries them all: each is an independent `if` on the same
    command line, so separate fixtures would multiply full compile analyses
    without separating anything. The absence assertions on the WASM action are
    the load-bearing half — `dart compile wasm` rejects every one of these
    outright ("Could not find an option named"), so a flag leaking across
    would break the build rather than merely misconfigure it.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        present = ctx.attr.expect_js,
        absent_substrings = ctx.attr.expect_not_js,
    )
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        absent_substrings = ctx.attr.expect_not_wasm,
    )
    return analysistest.end(env)

_js_flags_test = analysistest.make(
    _js_flags_test_impl,
    attrs = {
        "expect_js": attr.string_list(mandatory = True),
        "expect_not_js": attr.string_list(mandatory = True),
        "expect_not_wasm": attr.string_list(mandatory = True),
    },
)

def _experiments_test_impl(ctx):
    """An experiment reaches every step that parses the source.

    Read from `-c opt`, which is the only configuration where the icon
    tree-shake kernel compile exists at all — and that compile is the one a
    web-only implementation forgets, because both real compilers would have
    accepted the code without it.
    """
    env = analysistest.begin(ctx)
    flag = "--enable-experiment=test-experiment"
    for mnemonic in ["FlutterDart2Wasm", "FlutterDart2JS"]:
        _assert_argv(env, _action(env, mnemonic), present = [flag])

    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterDart2JSCFE"
    ]
    asserts.equals(env, 1, len(kernels), "expected the icon tree-shake kernel compile")
    if kernels:
        _assert_argv(env, kernels[0], present = [flag, "--cfe-only"])
    return analysistest.end(env)

_experiments_test = analysistest.make(
    _experiments_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _web_conditional_icon_test_impl(ctx):
    """The icon tree-shake kernel compiles with the web compiler so platform-conditional imports resolve to the web branch.

    `package:cond_icons` exports `icon_vm.dart` normally and `icon_web.dart`
    when `dart.library.js_interop` is available. The web compilers take the
    web branch; a `--target flutter` kernel against the VM platform takes the
    VM branch, so const_finder misses the web icon. Asserted here as the
    action shape that guarantees the resolution: a `dart compile js
    --cfe-only` kernel (the same frontend upstream runs to produce the
    `app.dill` const_finder reads), with the web platform binaries and
    libraries spec, and both branches' files among the inputs (so editing
    the web branch re-runs the compile instead of hitting a stale disk-cache
    entry keyed only on the VM-resolved digest).
    """
    env = analysistest.begin(ctx)
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterDart2JSCFE"
    ]
    asserts.true(env, len(kernels) > 0, "expected at least one icon tree-shake kernel compile")
    for k in kernels:
        _assert_argv(
            env,
            k,
            present = [
                "--cfe-only",
                "-Ddart.vm.product=true",
            ],
            absent_substrings = [
                "/flutter_patched_sdk",
                "/flutter_patched_sdk_product/platform_strong.dill",
            ],
        )
        input_paths = [f.path for f in k.inputs.to_list()]
        asserts.true(
            env,
            any(["dart2js_platform.dill" in p for p in input_paths]),
            "web icon kernel must compile against the web platform dill: %s" % input_paths,
        )
        asserts.true(
            env,
            any(["cond_icons/lib/src/icon_web.dart" in p for p in input_paths]),
            "web icon kernel must take the web branch file as an input: %s" % input_paths,
        )
        asserts.true(
            env,
            any(["cond_icons/lib/src/icon_vm.dart" in p for p in input_paths]),
            "web icon kernel must take the VM branch file as an input: %s" % input_paths,
        )
    return analysistest.end(env)

_web_conditional_icon_test = analysistest.make(
    _web_conditional_icon_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _dump_info_test_impl(ctx):
    """`dump_info` produces a named artifact.

    Two joints: the flag dart2js actually needs, and the extraction the
    bundler is told to perform.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        # NOT the bare `--dump-info`, which writes a binary `.info.data`.
        present = ["--stage=dump-info-all"],
    )

    bundle = written_json(env, "_web_bundle_config.json")
    if bundle == None:
        return analysistest.end(env)

    extracts = bundle["extracts"]
    asserts.equals(env, 1, len(extracts), "expected one extract, got %s" % extracts)
    if extracts:
        asserts.true(
            env,
            extracts[0]["src"].endswith("/main.dart.js.info.json"),
            "the extract must name dart2js's own output path, got %r" % extracts[0]["src"],
        )
        asserts.true(
            env,
            extracts[0]["dst"].endswith("_dart2js_info.json"),
            "the extract must land on the declared file, got %r" % extracts[0]["dst"],
        )

    # And it is reachable by name rather than only as a file inside a tree.
    group = analysistest.target_under_test(env)[OutputGroupInfo].dump_info.to_list()
    asserts.equals(env, 1, len(group), "dump_info output group: %s" % group)
    return analysistest.end(env)

_dump_info_test = analysistest.make(_dump_info_test_impl)

def _no_dump_info_test_impl(ctx):
    """With the attr off, nothing is asked for and the group is empty."""
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2JS"),
        absent_substrings = ["dump-info"],
    )
    asserts.equals(
        env,
        [],
        analysistest.target_under_test(env)[OutputGroupInfo].dump_info.to_list(),
    )
    return analysistest.end(env)

_no_dump_info_test = analysistest.make(_no_dump_info_test_impl)

def _no_strip_release_test_impl(ctx):
    """`strip_wasm = False` reaches the one mode that would have stripped.

    Read from `-c opt`. The debug and profile assertions elsewhere prove the
    release gate; only this proves the attr is consulted at all, rather than
    the gate alone deciding.
    """
    env = analysistest.begin(ctx)
    _assert_argv(
        env,
        _action(env, "FlutterDart2Wasm"),
        present = ["--no-strip-wasm", "-Ddart.vm.product=true"],
    )
    return analysistest.end(env)

_no_strip_release_test = analysistest.make(
    _no_strip_release_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

def _strip_wasm_on_js_refused_test_impl(ctx):
    """The same refusal covers the other wasm-only attr, named for itself."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "strip_wasm")
    asserts.expect_failure(env, "compiler = \"dart2wasm\"")
    return analysistest.end(env)

_strip_wasm_on_js_refused_test = analysistest.make(
    _strip_wasm_on_js_refused_test_impl,
    expect_failure = True,
)

def _wasm_only_attr_refused_test_impl(ctx):
    """A wasm-only setting on a dart2js target is refused, by attr name."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "minify_wasm")

    # The message has to name the way out, or it reads as "you may not have
    # this" rather than "ask the other compiler for it".
    asserts.expect_failure(env, "compiler = \"dart2wasm\"")
    return analysistest.end(env)

_wasm_only_attr_refused_test = analysistest.make(
    _wasm_only_attr_refused_test_impl,
    expect_failure = True,
)

# The project a web bundle that is built for real needs: `flutter build web`
# refuses a project without `web/`, and so does the bundle action.
_WEB_PROJECT_PUBSPEC = "web_project/pubspec.yaml"
_WEB_PROJECT_SRCS = ["web_project/web/index.html"]

def _setup_web_fixtures():
    """flutter_web_bundle instances the analysis tests read.

    `tags = ["manual"]` keeps them out of `bazel test //...` glob expansion;
    the map fixture is additionally built for real by a build_test, which is
    what proves dart2wasm writes main.dart.wasm.map where it was declared
    (an undeclared or misplaced output fails that action, not an assertion).

    Every fixture's `main` sits under this package's own `lib/`, the shape a
    real app has, so the build_tests below cover a nested-package web compile.
    `_web_pkg_root_main_fixture` is the one deliberate exception.
    """
    flutter_web_bundle(
        name = "_web_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        defines = ["from.attr=1"],
        tags = ["manual"],
    )

    # A `main` beside the package's `lib/` rather than inside it, which has no
    # `package:` URI at all.
    flutter_web_bundle(
        name = "_web_pkg_root_main_fixture",
        package_name = "web_fixture",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_web_nonlib_generated_src_fixture",
        srcs = [":_ae_declared_shadow_src"],
        package_name = "web_fixture",
        main = "nonlib/nonlib_shadow_main.dart",
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )
    flutter_web_bundle(
        name = "_web_map_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        source_maps = True,
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # Read from a `-c dbg` configuration, so the attr is what makes it a
    # profile build rather than the compilation mode agreeing by accident.
    flutter_web_bundle(
        name = "_web_profile_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        profile = True,
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # Opposite overrides on the two compilers, so neither can be satisfied by
    # an implementation that resolves one value and passes it to both.
    flutter_web_bundle(
        name = "_web_minify_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        minify_js = "true",
        minify_wasm = "false",
        tags = ["manual"],
    )

    # The dart2js-only flags, all on at once.
    flutter_web_bundle(
        name = "_web_js_flags_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        frequency_based_minification = False,
        native_null_assertions = False,
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # `test-experiment` is the SDK's own no-op experiment, declared for
    # exactly this: it exercises the flag path without pinning the fixture to
    # a language feature whose name changes when it ships.
    flutter_web_bundle(
        name = "_web_experiments_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        enable_experiments = ["test-experiment"],
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # Platform-conditional icon regression fixture: the app draws the web
    # branch's icon (0xe04b); the VM branch draws 0xe04c.
    flutter_web_bundle(
        name = "_web_cond_fixture",
        package_name = "web_fixture",
        main = "lib/web_cond_fixture_main.dart",
        deps = [
            "//flutter/tests/icon_tree_shake_fixture:flutter_stub",
            "//flutter/tests/icon_tree_shake_fixture/cond_icons",
        ],
        tags = ["manual"],
        visibility = ["//flutter/tests:__subpackages__"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    flutter_web_bundle(
        name = "_web_dump_info_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        dump_info = True,
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # The same attr in JS-only mode. The tree the report is lifted out of is a
    # different target there (`_dart2js` rather than `_dart2js_fallback`), so
    # a path built from the wrong one fails only here.
    flutter_web_bundle(
        name = "_web_dump_info_js_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        compiler = "dart2js",
        dump_info = True,
        renderer = "canvaskit",
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # Release is the only mode that would have stripped, so it is the only
    # one where turning the attr off can be told apart from the gate.
    flutter_web_bundle(
        name = "_web_no_strip_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        strip_wasm = False,
        tags = ["manual"],
    )

    # Wasm-only settings on a target that runs no wasm compile.
    flutter_web_bundle(
        name = "_web_strip_wasm_on_js",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        compiler = "dart2js",
        renderer = "canvaskit",
        strip_wasm = False,
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_web_minify_wasm_on_js",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        compiler = "dart2js",
        minify_wasm = "false",
        renderer = "canvaskit",
        tags = ["manual"],
    )

    # One compiler overridden and the other left alone, so a value that
    # reached both would fail on the one that was not asked.
    flutter_web_bundle(
        name = "_web_optimization_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        optimization_level_js = "3",
        tags = ["manual"],
    )

    # `"0"` on both, which is the value the old `if level > 0` guard dropped.
    flutter_web_bundle(
        name = "_web_optimization_zero_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        optimization_level_js = "0",
        optimization_level_wasm = "0",
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )

    # A dart2js-only target that sets the dart2js settings, so the call site
    # that serves `compiler = "dart2js"` is pinned rather than only the
    # fallback call inside a dart2wasm target.
    flutter_web_bundle(
        name = "_web_js_only_settings_fixture",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        compiler = "dart2js",
        minify_js = "false",
        optimization_level_js = "3",
        renderer = "canvaskit",
        tags = ["manual"],
    )

    flutter_web_bundle(
        name = "_web_optimization_wasm_on_js",
        package_name = "web_fixture",
        main = "lib/web_fixture_main.dart",
        compiler = "dart2js",
        optimization_level_wasm = "0",
        renderer = "canvaskit",
        tags = ["manual"],
    )

    _web_sdk_libraries_json_probe(
        name = "_web_sdk_missing_include_probe",
        libraries_json = "fixtures/broken_libraries.json",
        tags = ["manual"],
    )
    _web_sdk_libraries_json_probe(
        name = "_web_sdk_missing_target_probe",
        libraries_json = "fixtures/missing_target_libraries.json",
        tags = ["manual"],
    )
    _web_sdk_libraries_json_probe(
        name = "_web_sdk_missing_file_probe",
        scenario = "missing_file",
        tags = ["manual"],
    )
    _web_sdk_libraries_json_probe(
        name = "_web_sdk_missing_libraries_entry_probe",
        scenario = "missing_libraries_entry",
        tags = ["manual"],
    )
    _web_sdk_exec_probe(
        name = "_web_sdk_exec_fixture",
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )

    # The web-guard fixtures: `web_guard_fixture/lib/secret.dart` sits on the
    # host but in no target's `srcs`, and each hostile `main` below imports it
    # in one undeclared-input spelling. Every web compile runs behind
    # `web_guard`, so building any hostile fixture must fail with `is not a
    # declared input` before the compiler runs — under the sandboxed and the
    # local strategy alike — and embed nothing. They stay `manual`: a passing
    # `//flutter/...` cannot build a target that must fail. The clean bundle
    # beside them builds for real (see the suite's build_test), proving the
    # guard leaves declared imports alone.
    flutter_web_bundle(
        name = "_web_guard_clean",
        package_name = "web_guard_fixture",
        main = "web_guard_fixture/lib/clean_main.dart",
        srcs = ["web_guard_fixture/lib/helper.dart"],
        tags = ["manual"],
        pubspec = _WEB_PROJECT_PUBSPEC,
        pubspec_srcs = _WEB_PROJECT_SRCS,
    )
    for spelling in [
        "file",
        "relative",
        "app_scheme",
        "double_slash",
        "schemeless",
    ]:
        flutter_web_bundle(
            name = "_web_guard_hostile_" + spelling,
            package_name = "web_guard_fixture",
            main = "web_guard_fixture/lib/hostile/%s_main.dart" % spelling,
            tags = ["manual"],
        )
        flutter_web_bundle(
            name = "_web_guard_hostile_%s_js" % spelling,
            package_name = "web_guard_fixture",
            main = "web_guard_fixture/lib/hostile/%s_main.dart" % spelling,
            compiler = "dart2js",
            renderer = "canvaskit",
            tags = ["manual"],
        )

_VALID_WEB_SDK_LIBRARIES_JSON = """{
  "comment:0": "NOTE: THIS FILE IS GENERATED. DO NOT EDIT.",
  "dartdevc": {
    "include": [
      {
        "path": "../dart-sdk/lib/libraries.json",
        "target": "dartdevc"
      }
    ],
    "libraries": {
      "ui": {
        "uri": "lib/ui/ui.dart"
      },
      "ui_web": {
        "uri": "lib/ui_web/ui_web.dart"
      }
    }
  },
  "dart2js": {
    "include": [
      {
        "path": "../dart-sdk/lib/libraries.json",
        "target": "dart2js"
      }
    ],
    "libraries": {
      "ui": {
        "uri": "lib/ui/ui.dart"
      },
      "ui_web": {
        "uri": "lib/ui_web/ui_web.dart"
      }
    }
  },
  "wasm": {
    "include": [
      {
        "path": "../dart-sdk/lib/libraries.json",
        "target": "wasm"
      }
    ],
    "libraries": {
      "ui": {
        "uri": "lib/ui/ui.dart"
      },
      "ui_web": {
        "uri": "lib/ui_web/ui_web.dart"
      }
    }
  }
}
"""

_BROKEN_INCLUDE_LIBRARIES_JSON = """{
  "dartdevc": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "dartdevc"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  },
  "dart2js": {
    "include": [{"path": "../unexpected-sdk/lib/libraries.json", "target": "dart2js"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  },
  "wasm": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "wasm"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  }
}
"""

_MISSING_TARGET_LIBRARIES_JSON = """{
  "dartdevc": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "dartdevc"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  },
  "dart2js": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "dart2js"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  }
}
"""

_MISSING_LIBRARIES_ENTRY_JSON = """{
  "dartdevc": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "dartdevc"}],
    "libraries": {}
  },
  "dart2js": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "dart2js"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  },
  "wasm": {
    "include": [{"path": "../dart-sdk/lib/libraries.json", "target": "wasm"}],
    "libraries": {"ui": {"uri": "lib/ui/ui.dart"}, "ui_web": {"uri": "lib/ui_web/ui_web.dart"}}
  }
}
"""

def _web_optimization_level_defaults_test_impl(ctx):
    """Both `fastbuild` and `opt` release builds default dart2wasm to `-O2`; `dbg` uses `-O0`."""
    env = unittest.begin(ctx)

    asserts.equals(env, 0, default_dart2wasm_optimization_level("debug"))
    asserts.equals(env, 0, default_dart2wasm_optimization_level("debug", "dbg"))
    asserts.equals(env, 2, default_dart2wasm_optimization_level("profile"))
    asserts.equals(env, 2, default_dart2wasm_optimization_level("profile", "opt"))
    asserts.equals(env, 2, default_dart2wasm_optimization_level("release"))
    asserts.equals(env, 2, default_dart2wasm_optimization_level("release", "fastbuild"))
    asserts.equals(env, 2, default_dart2wasm_optimization_level("release", "opt"))

    asserts.equals(env, 1, default_dart2js_optimization_level("debug"))
    asserts.equals(env, 4, default_dart2js_optimization_level("profile"))
    asserts.equals(env, 4, default_dart2js_optimization_level("release"))

    asserts.equals(env, 2, resolve_web_optimization_level("auto", default_dart2wasm_optimization_level("release", "fastbuild")))
    asserts.equals(env, 0, resolve_web_optimization_level("auto", default_dart2wasm_optimization_level("debug", "dbg")))
    asserts.equals(env, 3, resolve_web_optimization_level("3", default_dart2wasm_optimization_level("release")))

    asserts.equals(env, False, resolve_web_minify("auto", "debug"))
    asserts.equals(env, False, resolve_web_minify("auto", "profile"))
    asserts.equals(env, True, resolve_web_minify("auto", "release"))
    asserts.equals(env, ["dart.vm.product=true"], web_mode_defines("release"))
    asserts.equals(env, ["dart.vm.profile=true"], web_mode_defines("profile"))
    asserts.equals(env, [], web_mode_defines("debug"))

    return unittest.end(env)

def _web_sdk_repo_rewrite_and_build_test_impl(ctx):
    """`flutter_web_sdk_repo` locates SDKs by declared `Label`s and rewrites `libraries.json` per exec platform."""
    env = unittest.begin(ctx)

    rewritten = rewrite_web_sdk_libraries_json(
        _VALID_WEB_SDK_LIBRARIES_JSON,
        "custom_sdk_linux_x64",
    )
    decoded = json.decode(rewritten)
    for target in ("dartdevc", "dart2js", "wasm"):
        asserts.equals(
            env,
            "../../custom_sdk_linux_x64/dart-sdk/lib/libraries.json",
            decoded[target]["include"][0]["path"],
        )
        asserts.equals(env, target, decoded[target]["include"][0]["target"])
        asserts.equals(env, "lib/ui/ui.dart", decoded[target]["libraries"]["ui"]["uri"])

    host_sdks = {
        Label("@@custom_darwin_arm64_sdk//:dart-sdk/lib/libraries.json"): "darwin-arm64",
        Label("@@custom_darwin_x64_sdk//:dart-sdk/lib/libraries.json"): "darwin-x64",
        Label("@@custom_windows_x64_sdk//:dart-sdk/lib/libraries.json"): "windows-x64",
        Label("@@custom_linux_x64_sdk//:dart-sdk/lib/libraries.json"): "linux-x64",
        Label("@@custom_linux_arm64_sdk//:dart-sdk/lib/libraries.json"): "linux-arm64",
    }
    resolved = resolve_web_sdk_host_repos(host_sdks)
    asserts.equals(env, "custom_darwin_arm64_sdk", resolved["darwin-arm64"].repo_name)
    asserts.equals(env, "custom_darwin_x64_sdk", resolved["darwin-x64"].repo_name)
    asserts.equals(env, "custom_windows_x64_sdk", resolved["windows-x64"].repo_name)
    asserts.equals(env, "custom_linux_x64_sdk", resolved["linux-x64"].repo_name)
    asserts.equals(env, "custom_linux_arm64_sdk", resolved["linux-arm64"].repo_name)

    build_content = generate_web_sdk_build(host_sdks)
    asserts.true(env, '":darwin-arm64": ["web-sdk/libraries.darwin-arm64.json"]' in build_content)
    asserts.true(env, '":darwin-x64": ["web-sdk/libraries.darwin-x64.json"]' in build_content)
    asserts.true(env, '":windows-x64": ["web-sdk/libraries.windows-x64.json"]' in build_content)
    asserts.true(env, '":linux-x64": ["web-sdk/libraries.linux-x64.json"]' in build_content)
    asserts.true(env, '":linux-arm64": ["web-sdk/libraries.linux-arm64.json"]' in build_content)
    asserts.true(env, "custom_darwin_arm64_sdk//:dart-sdk/lib/libraries.json" in build_content)
    asserts.true(env, "custom_darwin_x64_sdk//:dart-sdk/lib/libraries.json" in build_content)
    asserts.true(env, "custom_windows_x64_sdk//:dart-sdk/lib/libraries.json" in build_content)
    asserts.true(env, "custom_linux_x64_sdk//:dart-sdk/lib/libraries.json" in build_content)
    asserts.true(env, "custom_linux_arm64_sdk//:dart-sdk/lib/libraries.json" in build_content)
    asserts.true(env, "custom_darwin_arm64_sdk//:dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js" in build_content)
    asserts.true(env, "custom_windows_x64_sdk//:dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js" in build_content)
    asserts.true(env, "custom_linux_x64_sdk//:dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js" in build_content)

    # Also exercise `flutter_web_sdk_repo_impl` directly with a fake repository_ctx
    # whose `.path(".")` has a completely arbitrary repository name (not ending in
    # `_web_sdk` and containing no `+`), proving repo resolution uses declared labels.
    written_files = {}
    fake_rctx = struct(
        name = "arbitrary_web_repo_name",
        os = struct(name = "mac os x", arch = "aarch64"),
        attr = struct(
            engine_revision = "",
            sha256 = "",
            user_repository_name = "unused_base",
            host_sdks = host_sdks,
            libraries_json = None,
        ),
        path = lambda p: struct(exists = (p == "web-sdk/libraries.json"), basename = "arbitrary_web_repo_name"),
        read = lambda _p: _VALID_WEB_SDK_LIBRARIES_JSON,
        file = lambda path, content: written_files.update({path: content}),
    )
    flutter_web_sdk_repo_impl(fake_rctx)
    asserts.true(env, "web-sdk/libraries.darwin-arm64.json" in written_files)
    asserts.true(env, "web-sdk/libraries.darwin-x64.json" in written_files)
    asserts.true(env, "web-sdk/libraries.windows-x64.json" in written_files)
    asserts.true(env, "web-sdk/libraries.linux-x64.json" in written_files)
    asserts.true(env, "web-sdk/libraries.linux-arm64.json" in written_files)
    asserts.true(env, "../../custom_darwin_arm64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.darwin-arm64.json"])
    asserts.true(env, "../../custom_darwin_x64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.darwin-x64.json"])
    asserts.true(env, "../../custom_windows_x64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.windows-x64.json"])
    asserts.true(env, "../../custom_linux_x64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.linux-x64.json"])
    asserts.true(env, "../../custom_linux_arm64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.linux-arm64.json"])
    asserts.true(env, "../../custom_darwin_arm64_sdk/dart-sdk/lib/libraries.json" in written_files["web-sdk/libraries.json"])

    return unittest.end(env)

def _web_stubs_api_surface_test_impl(ctx):
    """`make_web_ui_web_stub_content` and `make_web_plugins_stub_content` cover the real `flutter_web_plugins` and `dart:ui_web` API surface."""
    env = unittest.begin(ctx)

    ui_web = make_web_ui_web_stub_content()
    for required in [
        "Future<void> bootstrapEngine(",
        "void setPluginHandler(ui.PlatformMessageCallback handler)",
        "typedef EventListener =",
        "typedef PopStateListener =",
        "abstract interface class PlatformLocation",
        "class BrowserPlatformLocation implements PlatformLocation",
        "abstract class UrlStrategy",
        "UrlStrategy? urlStrategy;",
        "class HashUrlStrategy extends UrlStrategy",
    ]:
        asserts.true(
            env,
            required in ui_web,
            "ui_web stub missing %r" % required,
        )

    for has_services in (True, False):
        plugins_stub = make_web_plugins_stub_content(has_flutter_services = has_services)
        for required in [
            "class Registrar extends BinaryMessenger",
            "void registerMessageHandler()",
            "Future<void> handlePlatformMessage(",
            "Future<void> handleFrameworkMessage(",
            "BinaryMessenger get messenger => this;",
            "Future<ByteData?> send(String channel, ByteData? message)",
            "void setMessageHandler(String channel, MessageHandler? handler)",
            "class PluginRegistry extends Registrar",
            "Registrar registrarFor(Type key) => this;",
            "final Registrar webPluginRegistrar = PluginRegistry();",
            "PluginRegistry get webPluginRegistry =>",
            "BinaryMessenger get pluginBinaryMessenger => webPluginRegistrar;",
            "class PluginEventChannel<T>",
            "void setController(StreamController<T>? controller)",
            "class PathUrlStrategy extends HashUrlStrategy",
            "void setUrlStrategy(UrlStrategy? strategy)",
            "void usePathUrlStrategy()",
            "String extractPathname(String url)",
            "String checkBaseHref(String? baseHref)",
            "String ensureLeadingSlash(String path)",
            "String stripTrailingSlash(String path)",
        ]:
            asserts.true(
                env,
                required in plugins_stub,
                "flutter_web_plugins stub (has_flutter_services=%s) missing %r" % (has_services, required),
            )

    asserts.true(
        env,
        "import 'package:flutter/services.dart';" in make_web_plugins_stub_content(has_flutter_services = True),
    )
    asserts.true(
        env,
        "abstract class BinaryMessenger" in make_web_plugins_stub_content(has_flutter_services = False),
    )

    return unittest.end(env)

def _web_canvaskit_url_define_test_impl(ctx):
    """A web compile names the engine's CanvasKit on the CDN, as `flutter build web` does, unless a define does or the bundle serves its own."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["FLUTTER_WEB_CANVASKIT_URL=https://www.gstatic.com/flutter-canvaskit/abc123/"],
        web_canvaskit_url_defines(["A=1"], "abc123"),
    )
    asserts.equals(env, [], web_canvaskit_url_defines(["FLUTTER_WEB_CANVASKIT_URL=canvaskit/"], "abc123"))
    asserts.equals(env, [], web_canvaskit_url_defines(["A=1"], "abc123", use_local_canvaskit = True))
    return unittest.end(env)

_t6_test = unittest.make(_web_optimization_level_defaults_test_impl)
_t9_test = unittest.make(_web_canvaskit_url_define_test_impl)
_t7_test = unittest.make(_web_sdk_repo_rewrite_and_build_test_impl)
_t8_test = unittest.make(_web_stubs_api_surface_test_impl)

def _web_sdk_libraries_json_probe_impl(ctx):
    scenario = ctx.attr.scenario
    fixture_file = ctx.file.libraries_json
    source_name = fixture_file.short_path if fixture_file != None else "web-sdk/libraries.json"

    file_exists = True
    content = _VALID_WEB_SDK_LIBRARIES_JSON
    if scenario == "missing_file":
        file_exists = False
    elif scenario == "missing_libraries_entry":
        content = _MISSING_LIBRARIES_ENTRY_JSON
    elif fixture_file != None and fixture_file.basename == "broken_libraries.json":
        content = _BROKEN_INCLUDE_LIBRARIES_JSON
    elif fixture_file != None and fixture_file.basename == "missing_target_libraries.json":
        content = _MISSING_TARGET_LIBRARIES_JSON

    fake_rctx = struct(
        name = "flutter_web_sdk",
        attr = struct(
            engine_revision = "",
            sha256 = "",
            user_repository_name = "flutter",
            host_sdks = {
                Label("@@flutter_linux-x64//:dart-sdk/lib/libraries.json"): "linux-x64",
            },
            libraries_json = ctx.attr.libraries_json.label if ctx.attr.libraries_json != None else None,
        ),
        path = lambda _p: struct(exists = file_exists, basename = source_name),
        read = lambda _p: content,
        file = lambda _path, _content: None,
    )
    flutter_web_sdk_repo_impl(fake_rctx)
    return [DefaultInfo()]

_web_sdk_libraries_json_probe = rule(
    implementation = _web_sdk_libraries_json_probe_impl,
    attrs = {
        "libraries_json": attr.label(allow_single_file = [".json"]),
        "scenario": attr.string(default = ""),
    },
)

def _web_sdk_libraries_json_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_web_sdk_libraries_json_failure_test = analysistest.make(
    _web_sdk_libraries_json_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_error": attr.string(mandatory = True),
    },
)

def _probe_request(ctx, dart, main_dart, package_config, output_dir):
    """Builds the release-mode dart2js request the exec probe compiles with.

    Mirrors the rule's request shape over the probe's files: no SDK (an empty
    file set, as the probe passed before), the web SDK's `libraries*.json`
    files, and the dart2js platform dill.
    """
    return make_dart2js_request(
        struct(
            dart = dart,
            flutter_sdk_info = struct(dart2js_files = depset()),
            dart2wasm_platform_dill = None,
            dart2js_platform_dill = ctx.file._dart2js_platform_dill,
            web_sdk_files = [ctx.file._default_libraries_json] + ctx.files._libraries_json,
            main_dart = main_dart,
            srcs = [main_dart],
            package_config = package_config,
            mode = "release",
            defines = [],
            renderer = "canvaskit",
            web_compile_tool = None,
            web_compile_inputs = [],
            web_guard_tool = None,
            enable_experiments = [],
        ),
        struct(
            optimization_level = "auto",
            minify = "auto",
            native_null_assertions = True,
            frequency_based_minification = True,
            dump_info = False,
            source_maps = False,
        ),
        "canvaskit",
        output_dir,
    )

def _web_sdk_exec_probe_impl(ctx):
    fake_dart = ctx.actions.declare_file(ctx.label.name + "_fake_dart")
    ctx.actions.write(fake_dart, "", is_executable = True)
    pkg_cfg = ctx.actions.declare_file(ctx.label.name + "_package_config.json")
    ctx.actions.write(pkg_cfg, '{"configVersion": 2, "packages": []}\n')
    out_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
    flutter_dart2js_action(ctx, _probe_request(ctx, fake_dart, ctx.file.main, pkg_cfg, out_dir))
    return [DefaultInfo(files = depset(ctx.files._libraries_json + [out_dir]))]

_web_sdk_exec_probe = rule(
    implementation = _web_sdk_exec_probe_impl,
    attrs = {
        "main": attr.label(allow_single_file = [".dart"], mandatory = True),
        "_default_libraries_json": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/libraries.json"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_libraries_json": attr.label(
            default = Label("@flutter_web_sdk//:libraries_json"),
            cfg = "exec",
        ),
        "_dart2js_platform_dill": attr.label(
            default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
            allow_single_file = True,
            cfg = "exec",
        ),
    },
)

def _web_sdk_exec_platform_selection_test_impl(ctx):
    """`@flutter_web_sdk//:libraries_json` selects `web-sdk/libraries.<platform>.json`."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    files = [f for f in tut[DefaultInfo].files.to_list() if f.basename.endswith(".json")]
    asserts.equals(env, 1, len(files))
    if files:
        asserts.equals(env, ctx.attr.expected_basename, files[0].basename)
    js_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterDart2JS"]
    if js_actions:
        spec_flags = [a for a in js_actions[0].argv if a.startswith("--libraries-spec=")]
        asserts.equals(env, 1, len(spec_flags))
        if spec_flags:
            asserts.true(
                env,
                spec_flags[0].endswith("/web-sdk/" + ctx.attr.expected_basename),
                "--libraries-spec must end with /web-sdk/%s, got %r" % (ctx.attr.expected_basename, spec_flags[0]),
            )
    return analysistest.end(env)

def _make_web_sdk_platform_selection_test(platform_label):
    return analysistest.make(
        _web_sdk_exec_platform_selection_test_impl,
        config_settings = {
            "//command_line_option:platforms": str(Label(platform_label)),
            "//command_line_option:host_platform": str(Label(platform_label)),
            "//command_line_option:extra_execution_platforms": [str(Label(platform_label))],
        },
        attrs = {
            "expected_basename": attr.string(mandatory = True),
        },
    )

_web_sdk_select_linux_x64_test = _make_web_sdk_platform_selection_test("//flutter/platforms:linux_x64")
_web_sdk_select_linux_arm64_test = _make_web_sdk_platform_selection_test("//flutter/platforms:linux_arm64")
_web_sdk_select_macos_arm64_test = _make_web_sdk_platform_selection_test("//flutter/platforms:macos_arm64")
_web_sdk_select_macos_x64_test = _make_web_sdk_platform_selection_test("//flutter/platforms:macos_x64")
_web_sdk_select_windows_x64_test = _make_web_sdk_platform_selection_test("//flutter/platforms:windows_x64")

def web_test_suite(name):
    """Instantiate the web-bundle fixtures and the analysis tests over them.

    Args:
        name: Prefix for the generated test targets and the suite itself.
    """
    _setup_web_fixtures()

    _dbg_web_defines_test(
        name = name + "_dbg_defines",
        target_under_test = ":_web_fixture",
    )
    _fastbuild_web_defines_test(
        name = name + "_fastbuild_defines",
        target_under_test = ":_web_fixture",
    )
    _opt_web_defines_test(
        name = name + "_opt_defines",
        target_under_test = ":_web_fixture",
    )
    _profile_web_defines_test(
        name = name + "_profile_defines",
        target_under_test = ":_web_profile_fixture",
    )
    _profile_flag_web_defines_test(
        name = name + "_profile_flag_defines",
        target_under_test = ":_web_fixture",
    )

    _web_sdk_libraries_json_failure_test(
        name = name + "_web_sdk_missing_include_fails",
        target_under_test = ":_web_sdk_missing_include_probe",
        expected_error = "missing_dart_sdk_include",
    )
    _web_sdk_libraries_json_failure_test(
        name = name + "_web_sdk_missing_target_fails",
        target_under_test = ":_web_sdk_missing_target_probe",
        expected_error = "missing_target_entry",
    )
    _web_sdk_libraries_json_failure_test(
        name = name + "_web_sdk_missing_file_fails",
        target_under_test = ":_web_sdk_missing_file_probe",
        expected_error = "missing_libraries_json",
    )
    _web_sdk_libraries_json_failure_test(
        name = name + "_web_sdk_missing_libraries_entry_fails",
        target_under_test = ":_web_sdk_missing_libraries_entry_probe",
        expected_error = "missing_libraries_entry",
    )

    _web_sdk_select_linux_x64_test(
        name = name + "_web_sdk_select_linux_x64",
        target_under_test = ":_web_sdk_exec_fixture",
        expected_basename = "libraries.linux-x64.json",
    )
    _web_sdk_select_linux_arm64_test(
        name = name + "_web_sdk_select_linux_arm64",
        target_under_test = ":_web_sdk_exec_fixture",
        expected_basename = "libraries.linux-arm64.json",
    )
    _web_sdk_select_macos_arm64_test(
        name = name + "_web_sdk_select_macos_arm64",
        target_under_test = ":_web_sdk_exec_fixture",
        expected_basename = "libraries.darwin-arm64.json",
    )
    _web_sdk_select_macos_x64_test(
        name = name + "_web_sdk_select_macos_x64",
        target_under_test = ":_web_sdk_exec_fixture",
        expected_basename = "libraries.darwin-x64.json",
    )
    _web_sdk_select_windows_x64_test(
        name = name + "_web_sdk_select_windows_x64",
        target_under_test = ":_web_sdk_exec_fixture",
        expected_basename = "libraries.windows-x64.json",
    )

    _wasm_source_map_test(
        name = name + "_wasm_source_map",
        target_under_test = ":_web_map_fixture",
    )
    _wasm_no_source_map_test(
        name = name + "_wasm_no_source_map",
        target_under_test = ":_web_fixture",
    )
    _minify_override_test(
        name = name + "_minify_override",
        target_under_test = ":_web_minify_fixture",
    )
    _wasm_only_attr_refused_test(
        name = name + "_minify_wasm_on_js_refused",
        target_under_test = ":_web_minify_wasm_on_js",
    )
    _optimization_override_test(
        name = name + "_optimization_override",
        target_under_test = ":_web_optimization_fixture",
    )
    _optimization_zero_test(
        name = name + "_optimization_zero",
        target_under_test = ":_web_optimization_zero_fixture",
    )
    _optimization_wasm_on_js_refused_test(
        name = name + "_optimization_wasm_on_js_refused",
        target_under_test = ":_web_optimization_wasm_on_js",
    )
    _js_only_settings_test(
        name = name + "_js_only_settings",
        target_under_test = ":_web_js_only_settings_fixture",
    )

    # Analysis proves the level reaches the command line; only a build proves
    # the compilers accept the ends of the range. `-O0` is the one the old
    # guard never emitted, so it had never been run.
    build_test(
        name = name + "_optimization_zero_build",
        targets = [":_web_optimization_zero_fixture"],
    )
    _js_flags_test(
        name = name + "_js_flags",
        target_under_test = ":_web_js_flags_fixture",
        expect_js = ["--no-frequency-based-minification"],
        # The one flag here that is on by default, so turning it off is the
        # only way to tell the attr from the default.
        expect_not_js = ["native-null-assertions"],
        expect_not_wasm = ["frequency-based", "native-null-assertions"],
    )
    build_test(
        name = name + "_js_flags_build",
        targets = [":_web_js_flags_fixture"],
    )

    # Built in the default (release) configuration, where the icon tree-shake
    # kernel compile runs — so this is what proves the frontend_server takes
    # the flag, not just the two compilers.
    build_test(
        name = name + "_experiments_build",
        targets = [":_web_experiments_fixture"],
    )
    _experiments_test(
        name = name + "_experiments",
        target_under_test = ":_web_experiments_fixture",
    )
    _web_conditional_icon_test(
        name = name + "_conditional_icon",
        target_under_test = ":_web_cond_fixture",
    )
    build_test(
        name = name + "_conditional_icon_build",
        targets = [":_web_cond_fixture"],
    )
    _dump_info_test(
        name = name + "_dump_info",
        target_under_test = ":_web_dump_info_fixture",
    )
    _dump_info_test(
        name = name + "_dump_info_js_only",
        target_under_test = ":_web_dump_info_js_fixture",
    )
    build_test(
        name = name + "_dump_info_build",
        targets = [
            ":_web_dump_info_fixture",
            ":_web_dump_info_js_fixture",
        ],
    )
    _no_dump_info_test(
        name = name + "_no_dump_info",
        target_under_test = ":_web_fixture",
    )
    _no_strip_release_test(
        name = name + "_no_strip_release",
        target_under_test = ":_web_no_strip_fixture",
    )
    _strip_wasm_on_js_refused_test(
        name = name + "_strip_wasm_on_js_refused",
        target_under_test = ":_web_strip_wasm_on_js",
    )
    build_test(
        name = name + "_wasm_map_build",
        targets = [":_web_map_fixture"],
    )

    # Analysis proves the flags are on the command line; only a real build
    # proves both compilers accept them. `--delete-tostring-package-uri` is
    # dart2wasm-only, so a copy of it onto the dart2js fallback would fail
    # here and nowhere else.
    build_test(
        name = name + "_profile_build",
        targets = [":_web_profile_fixture"],
    )
    build_test(
        name = name + "_nonlib_generated_src_build",
        targets = [":_web_nonlib_generated_src_fixture"],
    )

    # The guard's clean control builds for real: declared relative, package
    # and app-scheme imports compile through `web_guard` untouched on both
    # compilers. The hostile `_web_guard_hostile_*` fixtures beside it stay
    # manual-only and must fail instead (see `_setup_web_fixtures`).
    build_test(
        name = name + "_guard_clean_build",
        targets = [":_web_guard_clean"],
    )

    small_unittest_suite(name, _t0_test, _t1_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test)
