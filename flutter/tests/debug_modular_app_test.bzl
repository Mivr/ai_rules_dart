"""Analysis tests: a debug `flutter_application` compiles whole-program unless the private flag is on.

- default flag (off, #421), a debug app that is plain, tracks widget creation or sits over the registrant twin
  closure: one `FlutterKernelCompile`, no `DartKernel` module, no `DartKernelLink`;
- flag on, a plain debug app: `DartKernel` modules, one `DartKernelLink`, no `FlutterKernelCompile`;
- each selector (define, global define, define file, flavor, native asset) keeps the whole-program compile, and so
  do tracking beside a define, tracking in a release build and any frontend flag other than tracking;
- `track_widget_creation` stays modular: every module of its closure (the SDK `flutter` module and its registrant
  twin, the entry) compiles with `--track-widget-creation`, and a plain app's modules carry none;
- flag off explicitly, and a release build: one `FlutterKernelCompile`, no link;
- a tracking app, a plain app and a `flutter_test` over one library in one debug configuration analyse without
  conflicting actions, with the flag at its default, on and off.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application", "flutter_test")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load(":kernel_target_modular_test.bzl", "assert_kernel_target_dbg_modular")

visibility(["//flutter/tests/..."])

_FLAG = str(Label("//flutter/private:debug_modular_app"))
_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_DBG_ON = _DBG | {_FLAG: True}
_DBG_OFF = _DBG | {_FLAG: False}
_DBG_ON_GLOBAL_DEFINE = _DBG_ON | {str(Label("//flutter:extra_dart_defines")): ["GLOBAL=1"]}
_OPT_ON = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): False, _FLAG: True}
_DEPS = ["//flutter/tests/registrant_twin_fixture/app"]
_APP = {
    "package_name": "inputs_fixture",
    "main": "lib/language_version_main.dart",
    "tags": ["manual"],
    "target_compatible_with": HOST_COMPATIBLE,
}

def _mnemonics(env, mnemonic):
    """The target's actions with this mnemonic."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _modular_impl(ctx):
    """Flag on, a plain debug app: modules and one link, no whole-program compile."""
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

def _whole_program_impl(ctx):
    """One whole-program compile, no module and no link."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_mnemonics(env, "FlutterKernelCompile")), "one FlutterKernelCompile")
    asserts.equals(env, [], _mnemonics(env, "DartKernelLink"), "no DartKernelLink")
    asserts.equals(env, [], _mnemonics(env, "DartKernel"), "no DartKernel")
    return analysistest.end(env)

_tracking_modular_test = analysistest.make(_tracking_modular_impl, config_settings = _DBG_ON)
_plain_untracked_test = analysistest.make(_plain_untracked_impl, config_settings = _DBG_ON)
_modular_test = analysistest.make(_modular_impl, config_settings = _DBG_ON)
_default_test = analysistest.make(_whole_program_impl, config_settings = _DBG)
_selector_test = analysistest.make(_whole_program_impl, config_settings = _DBG_ON)
_global_define_test = analysistest.make(_whole_program_impl, config_settings = _DBG_ON_GLOBAL_DEFINE)
_global_define_tracking_test = analysistest.make(_whole_program_impl, config_settings = _DBG_ON_GLOBAL_DEFINE)
_flag_off_test = analysistest.make(_whole_program_impl, config_settings = _DBG_OFF)
_release_test = analysistest.make(_whole_program_impl, config_settings = _OPT_ON)

def _shared_lib_test_impl(ctx):
    """The test target analyses beside an app over the same library: no conflicting actions."""
    env = analysistest.begin(ctx)
    asserts.true(env, len(_mnemonics(env, "DartKernel")) > 0 or len(_mnemonics(env, "FlutterKernelCompile")) > 0)
    return analysistest.end(env)

_shared_lib_default_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG)
_shared_lib_on_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG_ON)
_shared_lib_off_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG_OFF)

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
    """Declares an app and a `flutter_test` over one library, each analysed in the default, on and off flag states.

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
    for flag, make in {
        "default": _shared_lib_default_test,
        "on": _shared_lib_on_test,
        "off": _shared_lib_off_test,
    }.items():
        for kind in ["app", "flutter_test"]:
            test = "%s_shared_lib_%s_%s" % (name, kind, flag)
            make(name = test, target_under_test = ":_shared_lib_" + kind)
            tests.append(test)
    return tests

def debug_modular_app_test_suite(name):
    """Declares the fixture applications and the analysis tests.

    Args:
        name: The test_suite name.
    """
    write_file(name = "_modular_app_defines_file", out = "_modular_app.defines", content = ["A=1"], tags = ["manual"])
    variants = {
        "plain": {},
        "define": {"defines": ["A=1"]},
        "flagfile": {"define_flagfiles": [":_modular_app_defines_file"]},
        "flavor": {"flavor": "prod"},
        "tracking_define": {"track_widget_creation": True, "defines": ["A=1"]},
        "tracking_flavor": {"track_widget_creation": True, "flavor": "prod"},
        "tracking_native_asset": {
            "track_widget_creation": True,
            "deps": ["//flutter/tests/modular_app_native_fixture:plugin"],
        },
        "widget_tracking": {"track_widget_creation": True},
        # The closure holds the registrant twin of the SDK `flutter` module (`_DEPS`), so the generated registrant is in play.
        "registrant": {},
        "native_asset": {"deps": ["//flutter/tests/modular_app_native_fixture:plugin"]},
    }
    for variant, extra in variants.items():
        flutter_application(name = "_modular_app_" + variant, **(_APP | {"deps": _DEPS} | extra))
    _modular_test(name = name + "_modular", target_under_test = ":_modular_app_plain")
    _default_test(name = name + "_default_plain", target_under_test = ":_modular_app_plain")
    _default_test(name = name + "_default_tracking", target_under_test = ":_modular_app_widget_tracking")
    _default_test(name = name + "_default_registrant", target_under_test = ":_modular_app_registrant")
    _flag_off_test(name = name + "_flag_off", target_under_test = ":_modular_app_plain")
    _release_test(name = name + "_release", target_under_test = ":_modular_app_plain")
    _global_define_test(name = name + "_global_define", target_under_test = ":_modular_app_plain")
    _tracking_modular_test(name = name + "_widget_tracking", target_under_test = ":_modular_app_widget_tracking")
    _plain_untracked_test(name = name + "_plain_untracked", target_under_test = ":_modular_app_plain")
    _release_test(name = name + "_release_tracking", target_under_test = ":_modular_app_widget_tracking")
    _global_define_tracking_test(
        name = name + "_global_define_tracking",
        target_under_test = ":_modular_app_widget_tracking",
    )
    tests = _shared_lib_cases(name) + _tracking_shared_cases(name) + [
        name + "_widget_tracking",
        name + "_plain_untracked",
        name + "_release_tracking",
        name + "_global_define_tracking",
    ] + [
        name + "_modular",
        name + "_default_plain",
        name + "_default_tracking",
        name + "_default_registrant",
        name + "_flag_off",
        name + "_release",
        name + "_global_define",
    ]
    selectors = ["define", "flagfile", "flavor", "native_asset", "tracking_define", "tracking_flavor"]
    for variant in selectors + ["tracking_native_asset"]:
        _selector_test(name = "%s_%s" % (name, variant), target_under_test = ":_modular_app_" + variant)
        tests.append("%s_%s" % (name, variant))
    native.test_suite(name = name, tests = tests)
