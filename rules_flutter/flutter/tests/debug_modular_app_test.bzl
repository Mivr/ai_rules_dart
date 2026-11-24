"""Analysis tests: a debug `flutter_application` compiles kernel modules and links them; there is no other path.

- a debug app that is plain, tracks widget creation or sits over the registrant twin closure: `DartKernel`
  modules, one `DartKernelLink`, no `FlutterKernelCompile`;
- a define, a global define, a define file and a flavor (alone or beside tracking) stay modular: they are the
  configuration of the app's `deps`, and the entry compile carries them too;
- a native asset (alone or beside tracking, and in a `flutter_test`) stays modular: the entry module embeds
  the native-assets mapping (`--native-assets`);
- `track_widget_creation` is on by default, as in stock `flutter`: a debug app that does not set it tracks, and its
  release build compiles without the flag; the fixtures below set it to False unless they name tracking;
- `track_widget_creation` stays modular: every module of its closure (the SDK `flutter` module and its registrant
  twin, the entry) compiles with `--track-widget-creation`, and a plain app's modules carry none;
- a release build (plain or tracking): one `FlutterKernelCompile`, no link;
- a tracking app, a plain app and a `flutter_test` over one library in one debug configuration analyse without
  conflicting actions, and so do two `flutter_test` targets whose names differ only in their directory;
- an app (and a `flutter_test`) whose `main` a library in its `deps` lists, the stock layout's `lib/main.dart`
  globbed into `lib/`, takes `main` from that library: its entry module names `main` by the library's `package:`
  URI and reads no file of it, and its release build accepts the same targets;
- `main` in a library the app reaches only through another, and a source other than `main` that the app and its
  library both list, still fail at analysis, naming both targets;
- a package at two roots fails at analysis, naming the package, both roots and a target that brings in each: across
  two branches, each consistent alone, the program finds it; under one library that takes both halves, the library.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application", "flutter_library", "flutter_test")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load(":kernel_target_modular_test.bzl", "assert_kernel_target_dbg_modular")

visibility(["//flutter/tests/..."])

_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_DBG_GLOBAL_DEFINE = _DBG | {str(Label("//flutter:extra_dart_defines")): ["GLOBAL=1"]}
_OPT = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): False}
# A Dart plugin is what makes a registrant.
_DEPS = ["//flutter/tests/registrant_twin_fixture/app", "//flutter/tests/registrant_twin_fixture/plugin"]
_APP = {
    # Off unless a fixture asks for tracking: the default (on) has its own fixture, `_modular_app_default`.
    "track_widget_creation": False,
    "package_name": "inputs_fixture",
    "main": "lib/language_version_main.dart",
    "tags": ["manual"],
    "target_compatible_with": HOST_COMPATIBLE,
}

def _mnemonics(env, mnemonic):
    """The target's actions with this mnemonic."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _modular_impl(ctx):
    """A plain debug app: modules and one link, no whole-program compile."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    assert_kernel_target_dbg_modular(env)
    return analysistest.end(env)

def _link_modules(env):
    """The `.kmod` modules the one link consumes, as short paths."""
    links = _mnemonics(env, "DartKernelLink")
    asserts.equals(env, 1, len(links), "one DartKernelLink")
    return [f.short_path for f in links[0].inputs.to_list() if f.short_path.endswith(".kmod")] if links else []

def _tracking_modular_impl(ctx):
    """A tracking debug app is modular, and every module (SDK, registrant twin and entry too) tracks.

    The aspect's module actions are not the target's own, so the closure is read off the link's inputs: the
    tracking set carries the `.tracked` stem, the entry action's argv carries the flag itself.
    """
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    assert_kernel_target_dbg_modular(env)
    entry = _mnemonics(env, "DartKernel")
    asserts.equals(env, 1, len(entry), "the entry is the target's own module action")
    for action in entry:
        asserts.true(env, "--track-widget-creation" in action.argv, "the entry tracks: %s" % action.argv)
    modules = [m for m in _link_modules(env) if ".flutter_entry.kmod" not in m]
    asserts.true(env, len(modules) > 1, "dependency modules: %s" % modules)
    asserts.true(env, any([".flutter_registrant.kmod" in m for m in modules]), "the SDK twin is linked: %s" % modules)
    for module in modules:
        asserts.true(env, ".tracked." in module, "module of the tracking set: " + module)
    return analysistest.end(env)

def _plain_untracked_impl(ctx):
    """A plain debug app's modules carry no tracking flag and no tracking stem."""
    env = analysistest.begin(ctx)
    for action in _mnemonics(env, "DartKernel"):
        asserts.false(env, "--track-widget-creation" in action.argv, "plain entry tracks: %s" % action.argv)
    modules = _link_modules(env)
    asserts.true(env, len(modules) > 1, "modules present")
    for module in modules:
        asserts.false(env, ".tracked." in module, "module of the plain set: " + module)
    return analysistest.end(env)

def _modular_env_impl(ctx):
    """A debug app with an environment is modular, and its entry compile carries that environment."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    assert_kernel_target_dbg_modular(env)
    entry = _mnemonics(env, "DartKernel")
    asserts.equals(env, 1, len(entry), "the entry is the target's own module action")
    for action in entry:
        for want in ctx.attr.expected:
            asserts.true(env, want in action.argv, "the entry carries %s: %s" % (want, action.argv))
    return analysistest.end(env)

def _native_asset_impl(ctx):
    """A debug app with a native asset is modular, and its entry module embeds the native-assets mapping."""
    env = analysistest.begin(ctx)
    if ctx.attr.app:
        assert_kernel_target_dbg_modular(env)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    asserts.equals(env, 1, len(_mnemonics(env, "DartKernelLink")), "one DartKernelLink")
    entry = _mnemonics(env, "DartKernel")
    asserts.equals(env, 1, len(entry), "the entry is the target's own module action")
    for action in entry:
        asserts.true(env, "--native-assets" in action.argv, "the entry embeds the mapping: %s" % action.argv)
        manifests = [f for f in action.inputs.to_list() if f.basename.endswith("native_assets.json")]
        asserts.equals(env, 1, len(manifests), "the mapping is an input of the entry")
    return analysistest.end(env)

def _whole_program_impl(ctx):
    """One whole-program compile, no module and no link."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_mnemonics(env, "FlutterKernelCompile")), "one FlutterKernelCompile")
    asserts.equals(env, [], _mnemonics(env, "DartKernelLink"), "no DartKernelLink")
    asserts.equals(env, [], _mnemonics(env, "DartKernel"), "no DartKernel")
    return analysistest.end(env)

def _release_untracked_impl(ctx):
    """A release build compiles whole-program without `--track-widget-creation`, whatever the attribute says."""
    env = analysistest.begin(ctx)
    compiles = _mnemonics(env, "FlutterKernelCompile")
    asserts.equals(env, 1, len(compiles), "one FlutterKernelCompile")
    for action in compiles:
        asserts.false(env, "--track-widget-creation" in action.argv, "release tracks: %s" % action.argv)
    return analysistest.end(env)

_release_untracked_test = analysistest.make(_release_untracked_impl, config_settings = _OPT)
_tracking_modular_test = analysistest.make(_tracking_modular_impl, config_settings = _DBG)
_plain_untracked_test = analysistest.make(_plain_untracked_impl, config_settings = _DBG)
_modular_test = analysistest.make(_modular_impl, config_settings = _DBG)
_native_asset_test = analysistest.make(_native_asset_impl, attrs = {"app": attr.bool(default = True)}, config_settings = _DBG)
_env_test = analysistest.make(_modular_env_impl, attrs = {"expected": attr.string_list()}, config_settings = _DBG)
_global_define_test = analysistest.make(
    _modular_env_impl,
    attrs = {"expected": attr.string_list()},
    config_settings = _DBG_GLOBAL_DEFINE,
)
_release_test = analysistest.make(_whole_program_impl, config_settings = _OPT)

def _shared_lib_test_impl(ctx):
    """The test target analyses beside an app over the same library: no conflicting actions."""
    env = analysistest.begin(ctx)
    asserts.true(env, len(_mnemonics(env, "DartKernel")) > 0)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    return analysistest.end(env)

_shared_lib_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG)

def _tracking_shared_cases(name):
    """A tracking app and a plain app over one library, analysed in one debug configuration.

    One build holds both module sets: they differ by the `.tracked` stem, so no two actions write one output.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    flutter_application(name = "_tracking_shared_app", **(_APP | {"deps": _DEPS, "track_widget_creation": True}))
    flutter_application(name = "_tracking_shared_plain_app", **(_APP | {"deps": _DEPS}))
    tests = []
    for kind, make in {"app": _tracking_modular_test, "plain_app": _plain_untracked_test}.items():
        test = "%s_tracking_shared_%s" % (name, kind)
        make(name = test, target_under_test = ":_tracking_shared_" + kind)
        tests.append(test)
    return tests

def _shared_lib_cases(name):
    """Declares an app and a `flutter_test` over one library, analysed in one debug configuration.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    flutter_application(name = "_shared_lib_app", **(_APP | {"deps": _DEPS}))
    flutter_test(
        name = "_shared_lib_flutter_test",
        package_name = "shared_lib_test",
        main = "lib/web_fixture_main.dart",
        deps = _DEPS + ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
        tags = ["manual"],
    )
    tests = []
    for kind in ["app", "flutter_test"]:
        test = "%s_shared_lib_%s" % (name, kind)
        _shared_lib_test(name = test, target_under_test = ":_shared_lib_" + kind)
        tests.append(test)
    return tests

_MAIN_IN_LIB = "flutter/tests/lib/web_fixture_main.dart"
_MAIN_IN_LIB_URI = "package:main_in_lib/web_fixture_main.dart"

def _main_in_lib_impl(ctx):
    """The entry names the library's `main` by its `package:` URI and compiles no file of it."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    asserts.equals(env, 1, len(_mnemonics(env, "DartKernelLink")), "one DartKernelLink")
    entry = _mnemonics(env, "DartKernel")
    asserts.equals(env, 1, len(entry), "the entry is the target's own module action")
    for action in entry:
        argv = action.argv
        sources = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--source"]
        if ctx.attr.app:
            asserts.true(env, sources and sources[0] == _MAIN_IN_LIB_URI, "the entry point is the library's main: %s" % sources)
        else:
            asserts.false(env, _MAIN_IN_LIB_URI in sources, "the bootstrap is the entry point, and imports main: %s" % sources)
        asserts.false(
            env,
            any([f.short_path == _MAIN_IN_LIB or f.short_path.endswith("/" + _MAIN_IN_LIB) for f in action.inputs.to_list()]),
            "the entry reads no file of main",
        )
    links = _link_modules(env)
    asserts.true(env, any(["_main_in_lib_lib." in m for m in links]), "the library's module is linked: %s" % links)
    return analysistest.end(env)

_main_in_lib_test = analysistest.make(_main_in_lib_impl, attrs = {"app": attr.bool(default = True)}, config_settings = _DBG)

def _main_in_lib_refused_impl(ctx):
    env = analysistest.begin(ctx)
    for want in ctx.attr.messages:
        asserts.expect_failure(env, want)
    return analysistest.end(env)

_main_in_lib_refused_test = analysistest.make(
    _main_in_lib_refused_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
    config_settings = _DBG,
)

def _main_in_lib_cases(name):
    """An app whose `main` its library also lists: the shape of a stock `lib/main.dart` globbed into `lib/`.

    The library owns `main` when it is in the app's own `deps`. Through another library, or with a second
    source the app lists too, the app is refused, naming both targets.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    flutter_library(
        name = "_main_in_lib_lib",
        package_name = "main_in_lib",
        srcs = ["lib/web_fixture_main.dart", "lib/language_version_main.dart"],
        deps = _DEPS,
        tags = ["manual"],
    )
    flutter_library(
        name = "_main_in_lib_facade",
        package_name = "main_in_lib",
        srcs = ["lib/web_cond_fixture_main.dart"],
        deps = [":_main_in_lib_lib"],
        tags = ["manual"],
    )
    app = _APP | {"package_name": "main_in_lib", "main": "lib/web_fixture_main.dart"}
    flutter_application(name = "_main_in_lib_app", **(app | {"deps": [":_main_in_lib_lib"]}))
    flutter_test(
        name = "_main_in_lib_flutter_test",
        package_name = "main_in_lib",
        main = "lib/web_fixture_main.dart",
        deps = [":_main_in_lib_lib", "//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
        tags = ["manual"],
    )
    flutter_application(name = "_main_in_lib_indirect_app", **(app | {"deps": [":_main_in_lib_facade"] + _DEPS}))
    flutter_application(
        name = "_main_in_lib_shared_src_app",
        **(app | {"srcs": ["lib/language_version_main.dart"], "deps": [":_main_in_lib_lib"]})
    )
    _main_in_lib_test(name = name + "_main_in_lib", target_under_test = ":_main_in_lib_app")
    _main_in_lib_test(name = name + "_main_in_lib_flutter_test", target_under_test = ":_main_in_lib_flutter_test", app = False)
    _release_test(name = name + "_main_in_lib_release", target_under_test = ":_main_in_lib_app")
    _main_in_lib_refused_test(
        name = name + "_main_in_lib_indirect",
        target_under_test = ":_main_in_lib_indirect_app",
        messages = [
            "source flutter/tests/lib/web_fixture_main.dart is listed by two targets",
            ":_main_in_lib_indirect_app and ",
            ":_main_in_lib_lib: one source belongs to one target",
            "only when the library is in ",
        ],
    )
    _main_in_lib_refused_test(
        name = name + "_main_in_lib_shared_src",
        target_under_test = ":_main_in_lib_shared_src_app",
        messages = [
            "source flutter/tests/lib/language_version_main.dart is listed by two targets",
            ":_main_in_lib_shared_src_app and ",
            ":_main_in_lib_lib",
        ],
    )
    return [name + "_main_in_lib" + suffix for suffix in ["", "_flutter_test", "_release", "_indirect", "_shared_src"]]

_TWO_ROOTS = "//flutter/tests/two_roots_fixture"

def _two_roots_cases(name):
    """A package, `two_roots_split`, at two roots, reached by a debug app across two branches and under one library.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    for case, deps in [
        ("branches", [_TWO_ROOTS + "/a:branch", _TWO_ROOTS + "/b:branch"]),
        ("join", [_TWO_ROOTS + ":join"]),
    ]:
        flutter_application(name = "_two_roots_%s_app" % case, **(_APP | {"deps": _DEPS + deps}))
    roots = [
        "package `two_roots_split` has 2 roots: ",
        "`flutter/tests/two_roots_fixture/a`, from ",
        "//flutter/tests/two_roots_fixture/a:split",
        "`flutter/tests/two_roots_fixture/b`, from ",
        "//flutter/tests/two_roots_fixture/b:split",
        "put every library of `two_roots_split` under one root",
    ]
    _main_in_lib_refused_test(
        name = name + "_two_roots_branches",
        target_under_test = ":_two_roots_branches_app",
        messages = [":_two_roots_branches_app compiles Flutter kernel modules, and cannot"] + roots,
    )
    _main_in_lib_refused_test(
        name = name + "_two_roots_join",
        target_under_test = ":_two_roots_join_app",
        messages = ["//flutter/tests/two_roots_fixture:join compiles no module: "] + roots,
    )
    return [name + "_two_roots_branches", name + "_two_roots_join"]

def _same_basename_cases(name):
    """Two `flutter_test` targets whose names differ only in their directory, analysed together.

    A project that names each test target by its file's path (`a/x_test`, `b/x_test`) gives two targets one
    basename; every file of their entry modules is declared beside its module, so no two actions write one.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    tests = []
    for directory in ["one", "two"]:
        flutter_test(
            name = "_same_basename/%s/x_test" % directory,
            package_name = "same_basename_test",
            main = "lib/web_fixture_main.dart",
            deps = _DEPS + ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
            tags = ["manual"],
        )
        test = "%s_same_basename_%s" % (name, directory)
        _shared_lib_test(name = test, target_under_test = ":_same_basename/%s/x_test" % directory)
        tests.append(test)
    return tests

def debug_modular_app_test_suite(name):
    """Declares the fixture applications and the analysis tests.

    Args:
        name: The test_suite name.
    """
    write_file(name = "_modular_app_defines_file", out = "_modular_app.defines", content = ["-DA=1"], tags = ["manual"])
    variants = {
        "plain": {},
        "define": {"defines": ["A=1"]},
        "flagfile": {"define_flagfiles": [":_modular_app_defines_file"]},
        "flavor": {"flavor": "prod"},
        "tracking_define": {"track_widget_creation": True, "defines": ["A=1"]},
        "tracking_flavor": {"track_widget_creation": True, "flavor": "prod"},
        "tracking_native_asset": {
            "track_widget_creation": True,
            "deps": _DEPS + ["//flutter/tests/modular_app_native_fixture:plugin"],
        },
        "widget_tracking": {"track_widget_creation": True},
        # The closure holds the registrant twin of the SDK `flutter` module (`_DEPS`), so the generated registrant is in play.
        "registrant": {},
        "native_asset": {"deps": _DEPS + ["//flutter/tests/modular_app_native_fixture:plugin"]},
    }
    for variant, extra in variants.items():
        flutter_application(name = "_modular_app_" + variant, **(_APP | {"deps": _DEPS} | extra))

    # The attribute left unset: tracking is the default in debug, and release drops it.
    flutter_application(
        name = "_modular_app_default",
        **({k: v for k, v in _APP.items() if k != "track_widget_creation"} | {"deps": _DEPS})
    )
    _tracking_modular_test(name = name + "_unset_tracks", target_under_test = ":_modular_app_default")
    _release_untracked_test(name = name + "_unset_release_untracked", target_under_test = ":_modular_app_default")
    _release_untracked_test(name = name + "_set_release_untracked", target_under_test = ":_modular_app_widget_tracking")
    _modular_test(name = name + "_modular", target_under_test = ":_modular_app_plain")
    _modular_test(name = name + "_registrant", target_under_test = ":_modular_app_registrant")
    _release_test(name = name + "_release", target_under_test = ":_modular_app_plain")
    _global_define_test(name = name + "_global_define", target_under_test = ":_modular_app_plain", expected = ["-DGLOBAL=1"])
    _tracking_modular_test(name = name + "_widget_tracking", target_under_test = ":_modular_app_widget_tracking")
    _plain_untracked_test(name = name + "_plain_untracked", target_under_test = ":_modular_app_plain")
    _release_test(name = name + "_release_tracking", target_under_test = ":_modular_app_widget_tracking")
    _global_define_test(
        name = name + "_global_define_tracking",
        target_under_test = ":_modular_app_widget_tracking",
        expected = ["-DGLOBAL=1", "--track-widget-creation"],
    )
    tests = _shared_lib_cases(name) + _tracking_shared_cases(name) + _same_basename_cases(name) + _main_in_lib_cases(name) + _two_roots_cases(name) + [
        name + "_widget_tracking",
        name + "_plain_untracked",
        name + "_release_tracking",
        name + "_global_define_tracking",
        name + "_unset_tracks",
        name + "_unset_release_untracked",
        name + "_set_release_untracked",
    ] + [
        name + "_modular",
        name + "_registrant",
        name + "_release",
        name + "_global_define",
    ]
    environments = {
        "define": ["-DA=1"],
        "flagfile": ["--define-file"],
        "flavor": ["-DFLUTTER_APP_FLAVOR=prod"],
        "tracking_define": ["-DA=1", "--track-widget-creation"],
        "tracking_flavor": ["-DFLUTTER_APP_FLAVOR=prod", "--track-widget-creation"],
    }
    for variant, expected in environments.items():
        _env_test(name = "%s_%s" % (name, variant), target_under_test = ":_modular_app_" + variant, expected = expected)
        tests.append("%s_%s" % (name, variant))
    for variant in ["native_asset", "tracking_native_asset"]:
        _native_asset_test(name = "%s_%s" % (name, variant), target_under_test = ":_modular_app_" + variant)
        tests.append("%s_%s" % (name, variant))
    flutter_test(
        name = "_native_asset_flutter_test",
        package_name = "native_asset_flutter_test",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/modular_app_native_fixture:plugin", "//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
        tags = ["manual"],
    )
    _native_asset_test(name = name + "_flutter_test_native_asset", target_under_test = ":_native_asset_flutter_test", app = False)
    tests.append(name + "_flutter_test_native_asset")
    native.test_suite(name = name, tests = tests)
