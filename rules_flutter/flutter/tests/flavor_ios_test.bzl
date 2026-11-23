"""Analysis tests that iOS app targets keep the flavor of `flutter_application`.

`flutter_ios_app` has no `flavor` attribute: the flavor comes from its
`application`, with one `flutter_application` and one `flutter_ios_app` per
flavor. These tests build `dev` and `prod` applications (with flavor-gated
assets, flavor-gated shaders, and flavor-specific plugins) and wire every iOS
packaging path over each: `flutter_ios_app` on both `xtool` and `rules_apple`
backends across device (`dbg`, `fastbuild`, `opt`, `profile`) and simulator
(`dbg`, plus simulator AOT slices), `_ios_device_transition`, and Tier 2
composable macros (`flutter_ios_framework_gen`, `flutter_ios_registrant_gen` in
Swift and Objective-C, and `flutter_ios_xcframeworks`).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application", "flutter_library", "flutter_plugin")
load(
    "//flutter:ios.bzl",
    "flutter_apple_plugin_library",
    "flutter_ios_app",
    "flutter_ios_framework_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_xcframeworks",
)
load(":apple_bundling.bzl", "fake_xcframework")

visibility(["//flutter/tests/..."])

_PACKAGE = "flavor_ios_test_fixture"
_MAIN = "lib/language_version_main.dart"
_FLAVORS = ["dev", "prod"]

def _other(flavor):
    """Returns the opposite flavor in `_FLAVORS`."""
    return "prod" if flavor == "dev" else "dev"

def _title(word):
    """Capitalizes the ASCII word `word`."""
    return word[0].upper() + word[1:]

_GraphInfo = provider(
    doc = "Package-reachable target nodes collected from an iOS target's dependency graph.",
    fields = {"nodes": "Depset of structs(label, actions, files) for non-tool dependencies."},
)

def _targets_in_value(val):
    """Extracts `Target` items from one attribute value `val`."""
    if type(val) == "Target":
        return [val]
    if type(val) == "list":
        return [item for item in val if type(item) == "Target"]
    if type(val) == "dict":
        return [item for item in val.keys() if type(item) == "Target"]
    return []

def _aspect_deps(rule_attr):
    """Lists every `Target` reachable through non-private attributes of `rule_attr`."""
    targets = []
    for attr_name in dir(rule_attr):
        if not attr_name.startswith("_"):
            targets.extend(_targets_in_value(getattr(rule_attr, attr_name)))
    return targets

def _graph_aspect_impl(target, ctx):
    """Records `target`'s actions and files and merges transitive non-tool deps."""
    own = struct(label = target.label, actions = target.actions, files = target[DefaultInfo].files)
    transitive = [dep[_GraphInfo].nodes for dep in _aspect_deps(ctx.rule.attr) if _GraphInfo in dep]
    return [_GraphInfo(nodes = depset(direct = [own], transitive = transitive))]

_graph_aspect = aspect(
    implementation = _graph_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects actions and outputs across the iOS target's non-private dependency graph.",
)

def _package_nodes(tut):
    """Package-local `_GraphInfo` nodes reachable from `tut`."""
    return [
        node
        for node in tut[_GraphInfo].nodes.to_list()
        if node.label.repo_name == tut.label.repo_name and node.label.package == tut.label.package
    ]

def _package_actions(tut):
    """Deduplicated actions registered by targets in `tut`'s package."""
    seen = {}
    out = []
    for node in _package_nodes(tut):
        for action in node.actions:
            outputs = action.outputs.to_list()
            key = outputs[0].short_path if outputs else str(action)
            if key not in seen:
                seen[key] = True
                out.append(action)
    return out

def _by_mnemonic(actions, mnemonic):
    """Filters `actions` to those matching `mnemonic`."""
    return [a for a in actions if a.mnemonic == mnemonic]

def _input_paths(action):
    """Short paths of all inputs to `action`."""
    return [f.short_path for f in action.inputs.to_list()]

def _written_content(env, actions, suffix):
    """Returns the single `FileWrite` content whose output basename ends with `suffix`."""
    matches = [a for a in actions if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(suffix)]
    asserts.equals(env, 1, len(matches), "expected one %s FileWrite, got %d" % (suffix, len(matches)))
    return matches[0].content if matches else ""

def _assert_compile_defines(env, actions, flavor, mode):
    """Checks the single Dart kernel (and AOT) compile in the iOS target's graph."""
    other = _other(flavor)
    compiles = _by_mnemonic(actions, "FlutterKernelCompile")
    asserts.equals(env, 1, len(compiles), "expected exactly one FlutterKernelCompile")
    argv = compiles[0].argv if compiles else []
    asserts.true(env, "-DFLUTTER_APP_FLAVOR=" + flavor in argv, "missing %s define in %s" % (flavor, argv))
    asserts.false(env, "-DFLUTTER_APP_FLAVOR=" + other in argv, "unexpected %s define in %s" % (other, argv))
    if mode == "profile":
        asserts.true(env, "-Ddart.vm.profile=true" in argv, "missing profile define in %s" % argv)
    elif mode == "opt":
        asserts.true(env, "-Ddart.vm.product=true" in argv, "missing product define in %s" % argv)
    if mode == "dbg":
        dev_cfg = json.decode(_written_content(env, actions, "_dev_config.json") or "{}")
        defines = dev_cfg.get("dartDefines", [])
        asserts.true(env, "FLUTTER_APP_FLAVOR=" + flavor in defines, "missing %s in dev_config: %s" % (flavor, defines))
        asserts.false(env, "FLUTTER_APP_FLAVOR=" + other in defines, "unexpected %s in dev_config: %s" % (other, defines))
        asserts.equals(env, [], _by_mnemonic(actions, "FlutterAotMacho"), "dbg must not run AOT")
    else:
        aots = _by_mnemonic(actions, "FlutterAotMacho")
        asserts.equals(env, 1, len(aots), "expected one FlutterAotMacho in %s" % mode)
        aot_inputs = _input_paths(aots[0]) if aots else []
        asserts.true(env, any([p.endswith("_app_%s.dill" % flavor) for p in aot_inputs]), "AOT must read %s dill: %s" % (flavor, aot_inputs))
        asserts.false(env, any([("_app_%s" % other) in p for p in aot_inputs]), "AOT must not read %s: %s" % (other, aot_inputs))

def _assert_bundle_and_shaders(env, actions, prefix, flavor):
    """Checks the single asset bundle and shader compiles in the iOS target's graph."""
    other = _other(flavor)
    bundles = _by_mnemonic(actions, "FlutterAssetBundle")
    asserts.equals(env, 1, len(bundles), "expected exactly one FlutterAssetBundle")
    paths = _input_paths(bundles[0]) if bundles else []
    copies = json.decode(_written_content(env, actions, ".asset_bundle_config.json") or "{}").get("copies", {})

    for kept_input in ["%s_%s.txt" % (prefix, flavor), "%s_any.txt" % prefix, flavor + ".frag.iplr", "any.frag.iplr"]:
        asserts.true(env, any([p.endswith(kept_input) for p in paths]), "missing bundle input %s in %s" % (kept_input, paths))
    for kept_key in [
        "packages/%s/assets/%s.txt" % (_PACKAGE, flavor),
        "packages/%s/assets/any.txt" % _PACKAGE,
        "packages/%s/shaders/%s.frag" % (_PACKAGE, flavor),
        "packages/%s/shaders/any.frag" % _PACKAGE,
    ]:
        asserts.true(env, kept_key in copies, "missing bundle key %s in %s" % (kept_key, copies.keys()))

    for dropped_input in ["%s_%s.txt" % (prefix, other), other + ".frag.iplr"]:
        asserts.false(env, any([p.endswith(dropped_input) for p in paths]), "unexpected %s in %s" % (dropped_input, paths))
    for dropped_key in ["packages/%s/assets/%s.txt" % (_PACKAGE, other), "packages/%s/shaders/%s.frag" % (_PACKAGE, other)]:
        asserts.false(env, dropped_key in copies, "unexpected bundle key %s in %s" % (dropped_key, copies.keys()))

    shader_inputs = [f.basename for a in _by_mnemonic(actions, "FlutterShaderCompile") for f in a.inputs.to_list()]
    asserts.true(env, (prefix + "_" + flavor + ".frag") in shader_inputs, "expected %s shader compile" % flavor)
    asserts.false(env, (prefix + "_" + other + ".frag") in shader_inputs, "%s shader must not compile" % other)

def _assert_dart_registrant(env, actions, flavor, is_dbg):
    """Checks the Dart plugin registrant (and dev registrant in debug) for `flavor`."""
    other = _other(flavor)
    reg_writes = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith("plugin_registrant.dart") and
           ".dev_plugin_registrant." not in a.outputs.to_list()[0].basename
    ]
    asserts.equals(env, 1, len(reg_writes), "expected one Dart plugin_registrant.dart")
    src = reg_writes[0].content if reg_writes else ""
    asserts.true(env, ("FlavorDart%sPlugin.registerWith();" % _title(flavor)) in src, "missing %s Dart plugin in %s" % (flavor, src))
    asserts.false(env, ("FlavorDart%sPlugin" % _title(other)) in src, "unexpected %s Dart plugin in %s" % (other, src))
    if is_dbg:
        asserts.true(env, ("FLUTTER_APP_FLAVOR=" + flavor) in src, "missing %s flavor in build_info registrant: %s" % (flavor, src))
        asserts.false(env, ("FLUTTER_APP_FLAVOR=" + other) in src, "unexpected %s flavor in build_info registrant: %s" % (other, src))
        dev_src = _written_content(env, actions, ".dev_plugin_registrant.ios.dart")
        asserts.true(env, ("FlavorDart%sPlugin.registerWith();" % _title(flavor)) in dev_src, "missing %s in dev iOS registrant" % flavor)
        asserts.false(env, ("FlavorDart%sPlugin" % _title(other)) in dev_src, "unexpected %s in dev iOS registrant" % other)

def _assert_swift_registrant(env, actions, flavor):
    """Checks the generated Swift `GeneratedPluginRegistrant` for `flavor`."""
    other = _other(flavor)
    src = _written_content(env, actions, "_native_plugin_registrant.swift")
    asserts.true(env, ("import " + _PACKAGE) in src, "missing module import in %s" % src)
    asserts.true(env, ("FlavorIos%sPlugin.register(" % _title(flavor)) in src, "missing %s register in %s" % (flavor, src))
    asserts.false(env, ("FlavorIos%sPlugin" % _title(other)) in src, "unexpected %s register in %s" % (other, src))

def _assert_no_own_dart_or_assets(env):
    """Checks the iOS target under test registers no Dart, asset, or shader compile of its own."""
    own = [a.mnemonic for a in analysistest.target_actions(env)]
    for forbidden in ["FlutterKernelCompile", "FlutterAotMacho", "FlutterAssetBundle", "FlutterShaderCompile"]:
        asserts.false(env, forbidden in own, "iOS target must not register %s on its own: %s" % (forbidden, own))

def _assert_own_flavor_files(env, tut, prefix, flavor):
    """Checks `tut` and its package-reachable deps reference `flavor` and never its sibling."""
    other = _other(flavor)
    paths = [f.short_path for node in _package_nodes(tut) for f in node.files.to_list()]
    if OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "flutter_assets"):
        paths.extend([f.short_path for f in tut[OutputGroupInfo].flutter_assets.to_list()])
    for action in tut.actions:
        paths.extend(_input_paths(action))
    asserts.false(
        env,
        any([("_app_" + other) in p or ("_ios_" + other) in p or ("_plugin_" + other) in p or ("_privacy_" + other) in p for p in paths]),
        "target %s leaked %s paths: %s" % (tut.label, other, paths),
    )
    asserts.true(
        env,
        any([("%s_app_%s" % (prefix, flavor)) in p for p in paths]),
        "expected %s_app_%s outputs on %s, got %s" % (prefix, flavor, tut.label, paths),
    )

def _xtool_ios_app_test_impl(ctx):
    """Verifies a full `flutter_ios_app` (`xtool` backend) keeps its application's flavor."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = _package_actions(tut)
    flavor = ctx.attr.flavor
    prefix = ctx.attr.prefix
    mode = ctx.attr.mode

    _assert_no_own_dart_or_assets(env)
    _assert_own_flavor_files(env, tut, prefix, flavor)
    _assert_compile_defines(env, actions, flavor, mode)
    _assert_bundle_and_shaders(env, actions, prefix, flavor)
    _assert_dart_registrant(env, actions, flavor, mode == "dbg")
    _assert_swift_registrant(env, actions, flavor)

    runners = _by_mnemonic(analysistest.target_actions(env), "FlutterXtoolRunner")
    bundles = _by_mnemonic(analysistest.target_actions(env), "FlutterXtoolIosBundle")
    asserts.equals(env, 1, len(runners), "expected FlutterXtoolRunner")
    asserts.equals(env, 1, len(bundles), "expected FlutterXtoolIosBundle")
    runner_inputs = _input_paths(runners[0]) if runners else []
    bundle_inputs = _input_paths(bundles[0]) if bundles else []
    asserts.true(env, any([("%s_plugin_%s_ios_xtool" % (prefix, flavor)) in p and p.endswith(".modulemap") for p in runner_inputs]), "missing %s modulemap" % flavor)
    asserts.true(env, any([("%s_privacy_%s" % (prefix, flavor)) in p for p in bundle_inputs]), "missing %s privacy manifest" % flavor)
    return analysistest.end(env)

def _ios_slice_test_impl(ctx):
    """Verifies a `rules_apple` or Tier 2 framework/bundle slice keeps its application's flavor."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = _package_actions(tut)
    flavor = ctx.attr.flavor
    mode = ctx.attr.mode

    asserts.equals(env, 1, len(_by_mnemonic(actions, "FlutterKernelCompile")), "expected one FlutterKernelCompile")
    _assert_no_own_dart_or_assets(env)
    _assert_own_flavor_files(env, tut, ctx.attr.prefix, flavor)
    _assert_compile_defines(env, actions, flavor, mode)
    _assert_bundle_and_shaders(env, actions, ctx.attr.prefix, flavor)
    _assert_dart_registrant(env, actions, flavor, mode == "dbg")
    return analysistest.end(env)

def _ios_registrant_test_impl(ctx):
    """Verifies an iOS native registrant target (Swift or Objective-C) keeps its flavor's plugins."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = _package_actions(tut)
    flavor = ctx.attr.flavor
    other = _other(flavor)

    _assert_no_own_dart_or_assets(env)
    _assert_compile_defines(env, actions, flavor, ctx.attr.mode)
    if ctx.attr.language == "objc":
        src = _written_content(env, analysistest.target_actions(env), "GeneratedPluginRegistrant.m")
        asserts.true(env, ("[%s registerWithRegistrar:" % ("FlavorIos%sPlugin" % _title(flavor))) in src, "missing %s ObjC plugin in %s" % (flavor, src))
        asserts.false(env, ("FlavorIos%sPlugin" % _title(other)) in src, "unexpected %s ObjC plugin in %s" % (other, src))
    else:
        _assert_swift_registrant(env, analysistest.target_actions(env), flavor)
    return analysistest.end(env)

def _ios_aux_test_impl(ctx):
    """Verifies privacy-manifest and native-framework targets read only their flavor's application."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = _package_actions(tut)
    flavor = ctx.attr.flavor

    _assert_no_own_dart_or_assets(env)
    _assert_own_flavor_files(env, tut, ctx.attr.prefix, flavor)
    _assert_compile_defines(env, actions, flavor, ctx.attr.mode)
    if ctx.attr.expect_privacy:
        files = [f.short_path for f in tut[DefaultInfo].files.to_list()]
        asserts.true(env, any([("%s_privacy_%s" % (ctx.attr.prefix, flavor)) in p for p in files]), "missing %s privacy output: %s" % (flavor, files))
    return analysistest.end(env)

def _ios_device_transition_impl(_settings, _attr):
    """Transitions a target to the iOS arm64 device platform on the `xtool` backend."""
    return {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//flutter:profile": False,
        "//flutter/settings:apple_backend": "xtool",
    }

_ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        "//flutter:profile",
        "//flutter/settings:apple_backend",
    ],
)

_IosPairInfo = provider(
    doc = "Holds the transitioned `dev` and `prod` iOS app targets for side-by-side inspection.",
    fields = {"dev": "Configured `dev` target.", "prod": "Configured `prod` target."},
)

def _ios_pair_probe_impl(ctx):
    """Exposes both transitioned `flutter_ios_app` targets without running actions."""
    dev = ctx.attr.dev[0] if type(ctx.attr.dev) == "list" else ctx.attr.dev
    prod = ctx.attr.prod[0] if type(ctx.attr.prod) == "list" else ctx.attr.prod
    return [
        DefaultInfo(files = depset(transitive = [dev[DefaultInfo].files, prod[DefaultInfo].files])),
        _IosPairInfo(dev = dev, prod = prod),
    ]

_ios_pair_probe = rule(
    implementation = _ios_pair_probe_impl,
    doc = "Transitions both flavored `flutter_ios_app` targets under `_ios_device_transition`.",
    attrs = {
        "dev": attr.label(cfg = _ios_device_transition, aspects = [_graph_aspect], mandatory = True, doc = "The `dev` `flutter_ios_app` target."),
        "prod": attr.label(cfg = _ios_device_transition, aspects = [_graph_aspect], mandatory = True, doc = "The `prod` `flutter_ios_app` target."),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
            doc = "Allowlist for `_ios_device_transition`.",
        ),
    },
)

def _ios_pair_test_impl(ctx):
    """Checks both `flutter_ios_app`s built side-by-side under `_ios_device_transition`."""
    env = analysistest.begin(ctx)
    pair = analysistest.target_under_test(env)[_IosPairInfo]
    dev_files = {f.short_path: True for f in pair.dev[DefaultInfo].files.to_list()}
    prod_files = [f.short_path for f in pair.prod[DefaultInfo].files.to_list()]
    asserts.equals(env, [], [p for p in prod_files if p in dev_files], "dev and prod bundle outputs must not collide")
    for flavor, target in [("dev", pair.dev), ("prod", pair.prod)]:
        actions = _package_actions(target)
        _assert_compile_defines(env, actions, flavor, "dbg")
        _assert_bundle_and_shaders(env, actions, ctx.attr.prefix, flavor)
        _assert_dart_registrant(env, actions, flavor, True)
        _assert_swift_registrant(env, actions, flavor)
    return analysistest.end(env)

_MACOS_EXEC = [str(Label("//flutter/platforms:macos_arm64"))]
_FAKE_XCODE = str(Label("//flutter/tests:ios_test_fake_xcode_config"))
_IOS_ARM64 = str(Label("//flutter/platforms:ios_arm64"))
_IOS_X64 = str(Label("//flutter/platforms:ios_x64"))
_IOS_SIM_ARM64 = str(Label("//flutter/private:ios_sim_arm64"))

def _cfg(platform, compilation_mode, profile, backend):
    """Builds `config_settings` for an iOS analysis test."""
    return {
        "//command_line_option:compilation_mode": compilation_mode,
        "//command_line_option:extra_execution_platforms": _MACOS_EXEC,
        "//command_line_option:platforms": platform,
        "//command_line_option:xcode_version_config": _FAKE_XCODE,
        str(Label("//flutter:profile")): profile,
        str(Label("//flutter/settings:apple_backend")): backend,
    }

_SLICE_ATTRS = {
    "flavor": attr.string(mandatory = True, doc = "Expected flavor (`dev` or `prod`)."),
    "mode": attr.string(mandatory = True, doc = "Expected mode (`dbg`, `fastbuild`, `opt`, or `profile`)."),
    "prefix": attr.string(mandatory = True, doc = "Target name prefix of the suite."),
}
_REG_ATTRS = dict(_SLICE_ATTRS, language = attr.string(default = "swift", doc = "Registrant language (`swift` or `objc`)."))
_AUX_ATTRS = dict(_SLICE_ATTRS, expect_privacy = attr.bool(default = False, doc = "Whether privacy manifests are expected."))

def _make_xtool_test(platform, compilation_mode, profile):
    """Creates an `xtool`-backend `analysistest` rule with `_graph_aspect`."""
    return analysistest.make(_xtool_ios_app_test_impl, attrs = _SLICE_ATTRS, config_settings = _cfg(platform, compilation_mode, profile, "xtool"), extra_target_under_test_aspects = [_graph_aspect])

def _make_slice_test(platform, compilation_mode, profile):
    """Creates a `rules_apple` or Tier 2 slice `analysistest` rule with `_graph_aspect`."""
    return analysistest.make(_ios_slice_test_impl, attrs = _SLICE_ATTRS, config_settings = _cfg(platform, compilation_mode, profile, "rules_apple"), extra_target_under_test_aspects = [_graph_aspect])

_xtool_device_dbg_test = _make_xtool_test(_IOS_ARM64, "dbg", False)
_xtool_device_fastbuild_test = _make_xtool_test(_IOS_ARM64, "fastbuild", False)
_xtool_device_opt_test = _make_xtool_test(_IOS_ARM64, "opt", False)
_xtool_device_profile_test = _make_xtool_test(_IOS_ARM64, "opt", True)
_xtool_sim_dbg_test = _make_xtool_test(_IOS_X64, "dbg", False)

_apple_device_dbg_test = _make_slice_test(_IOS_ARM64, "dbg", False)
_apple_device_fastbuild_test = _make_slice_test(_IOS_ARM64, "fastbuild", False)
_apple_device_opt_test = _make_slice_test(_IOS_ARM64, "opt", False)
_apple_device_profile_test = _make_slice_test(_IOS_ARM64, "opt", True)
_apple_sim_arm64_dbg_test = _make_slice_test(_IOS_SIM_ARM64, "dbg", False)
_apple_sim_arm64_opt_test = _make_slice_test(_IOS_SIM_ARM64, "opt", False)
_apple_sim_x64_opt_test = _make_slice_test(_IOS_X64, "opt", False)

_registrant_dbg_test = analysistest.make(_ios_registrant_test_impl, attrs = _REG_ATTRS, config_settings = _cfg(_IOS_ARM64, "dbg", False, "rules_apple"), extra_target_under_test_aspects = [_graph_aspect])
_registrant_opt_test = analysistest.make(_ios_registrant_test_impl, attrs = _REG_ATTRS, config_settings = _cfg(_IOS_ARM64, "opt", False, "rules_apple"), extra_target_under_test_aspects = [_graph_aspect])
_aux_dbg_test = analysistest.make(_ios_aux_test_impl, attrs = _AUX_ATTRS, config_settings = _cfg(_IOS_ARM64, "dbg", False, "rules_apple"), extra_target_under_test_aspects = [_graph_aspect])
_aux_opt_test = analysistest.make(_ios_aux_test_impl, attrs = _AUX_ATTRS, config_settings = _cfg(_IOS_ARM64, "opt", False, "rules_apple"), extra_target_under_test_aspects = [_graph_aspect])
_pair_transition_test = analysistest.make(_ios_pair_test_impl, attrs = {"prefix": attr.string(mandatory = True, doc = "Target name prefix of the suite.")})

_XTOOL_MODES = [
    ("device_dbg", "dbg", _xtool_device_dbg_test),
    ("device_fastbuild", "fastbuild", _xtool_device_fastbuild_test),
    ("device_opt", "opt", _xtool_device_opt_test),
    ("device_profile", "profile", _xtool_device_profile_test),
    ("sim_dbg", "dbg", _xtool_sim_dbg_test),
]

_APPLE_MODES = [
    ("apple_dbg", "dbg", _apple_device_dbg_test),
    ("apple_fastbuild", "fastbuild", _apple_device_fastbuild_test),
    ("apple_opt", "opt", _apple_device_opt_test),
    ("apple_profile", "profile", _apple_device_profile_test),
]

def _declare_plugin(name, flavor):
    """Declares a flavor-specific Dart + iOS plugin (`dev` or `prod`) with a privacy manifest."""
    pkg = "%s_plugin_%s" % (name, flavor)
    dart_cls = "FlavorDart%sPlugin" % _title(flavor)
    ios_cls = "FlavorIos%sPlugin" % _title(flavor)
    write_file(name = pkg + "_dart_src", out = "lib/%s.dart" % pkg, content = ["class %s { static void registerWith() {} }\n" % dart_cls], tags = ["manual"])
    write_file(name = pkg + "_swift_src", out = "%s.swift" % pkg, content = ["import Foundation\npublic class %s: NSObject {}\n" % ios_cls], tags = ["manual"])
    write_file(
        name = pkg + "_privacy_src",
        out = "%s_privacy_%s/PrivacyInfo.xcprivacy" % (name, flavor),
        content = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict/></plist>\n"],
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = pkg + "_ios_xtool",
        srcs = [":%s.swift" % pkg],
        module_name = _PACKAGE,
        platform = "ios",
        engine = ":" + name + "_engine",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_plugin(
        name = pkg,
        package_name = _PACKAGE,
        srcs = [":lib/%s.dart" % pkg],
        platforms = ["ios"],
        plugin_class = ios_cls,
        dart_plugin_class = dart_cls,
        apple_libs = select({"//flutter/settings:ios_xtool_backend": [":" + pkg + "_ios_xtool"], "//conditions:default": []}),
        apple_privacy_files = [":%s_privacy_%s/PrivacyInfo.xcprivacy" % (name, flavor)],
        tags = ["manual"],
    )

def _declare_fixtures(name):
    """Declares the flavor-restricted assets, shaders, engine, and plugins."""
    for suffix in _FLAVORS + ["any"]:
        write_file(name = "%s_write_%s_txt" % (name, suffix), out = "%s_%s.txt" % (name, suffix), content = [suffix + "\n"], tags = ["manual"])
        write_file(
            name = "%s_write_%s_frag" % (name, suffix),
            out = "%s_%s.frag" % (name, suffix),
            content = ["precision mediump float;", "void main() { gl_FragColor = vec4(1.0); }"],
            tags = ["manual"],
        )
    flutter_library(
        name = name + "_fixture_lib",
        package_name = _PACKAGE,
        srcs = [_MAIN],
        pkg_assets = {":%s_%s.txt" % (name, s): "assets/%s.txt" % s for s in _FLAVORS + ["any"]},
        pkg_shaders = {":%s_%s.frag" % (name, s): "shaders/%s.frag" % s for s in _FLAVORS + ["any"]},
        pkg_asset_flavors = dict(
            {":assets/%s.txt" % f: [f] for f in _FLAVORS},
            **{":shaders/%s.frag" % f: [f] for f in _FLAVORS}
        ),
        tags = ["manual"],
    )
    fake_xcframework(name = name + "_engine", framework_name = "Flutter", platform = "ios", tags = ["manual"])
    for flavor in _FLAVORS:
        _declare_plugin(name, flavor)

def _declare_flavor_targets(name, flavor):
    """Declares the flavored `flutter_application` and all iOS targets over it."""
    app = ":%s_app_%s" % (name, flavor)
    runners = [
        "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
    ]
    flutter_application(
        name = "%s_app_%s" % (name, flavor),
        flavor = flavor,
        main = _MAIN,
        package_name = _PACKAGE,
        deps = [":%s_fixture_lib" % name, ":%s_plugin_%s" % (name, flavor)],
        tags = ["manual"],
    )
    flutter_ios_app(
        name = "%s_ios_%s" % (name, flavor),
        application = app,
        bundle_id = "com.example.flavor." + flavor,
        srcs = runners,
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_engine",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_ios_app(
        name = "%s_apple_ios_%s" % (name, flavor),
        application = app,
        bundle_id = "com.example.apple.flavor." + flavor,
        srcs = runners,
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        launch_storyboard = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard",
        app_icons = [],
        entitlements = False,
        tags = ["manual"],
    )
    flutter_ios_framework_gen(name = "%s_fw_gen_%s" % (name, flavor), application = app, tags = ["manual"])
    flutter_ios_registrant_gen(name = "%s_reg_swift_%s" % (name, flavor), application = app, language = "swift", tags = ["manual"])
    flutter_ios_registrant_gen(name = "%s_reg_objc_%s" % (name, flavor), application = app, language = "objc", tags = ["manual"])
    flutter_ios_xcframeworks(name = "%s_xcf_%s" % (name, flavor), application = app, tags = ["manual"])

def _add_slice(suite, rule_fn, suffix, tut, mode):
    """Instantiates one slice/bundle `analysistest` and records its label."""
    tname = "%s_%s_%s" % (suite.prefix, suite.flavor, suffix)
    rule_fn(name = tname, size = "small", target_under_test = tut, flavor = suite.flavor, mode = mode, prefix = suite.prefix)
    suite.tests.append(":" + tname)

def _add_reg(suite, rule_fn, suffix, tut, mode, language):
    """Instantiates one registrant `analysistest` and records its label."""
    tname = "%s_%s_%s" % (suite.prefix, suite.flavor, suffix)
    rule_fn(name = tname, size = "small", target_under_test = tut, flavor = suite.flavor, mode = mode, prefix = suite.prefix, language = language)
    suite.tests.append(":" + tname)

def _add_aux(suite, rule_fn, suffix, tut, mode, expect_privacy):
    """Instantiates one privacy/native-framework `analysistest` and records its label."""
    tname = "%s_%s_%s" % (suite.prefix, suite.flavor, suffix)
    rule_fn(name = tname, size = "small", target_under_test = tut, flavor = suite.flavor, mode = mode, prefix = suite.prefix, expect_privacy = expect_privacy)
    suite.tests.append(":" + tname)

def _declare_flavor_tests(name, flavor):
    """Declares all analysis tests for one `flavor` and returns their labels."""
    suite = struct(prefix = name, flavor = flavor, tests = [])
    ios = "%s_ios_%s" % (name, flavor)
    apple_ios = "%s_apple_ios_%s" % (name, flavor)
    xcf = "%s_xcf_%s" % (name, flavor)

    for cfg_name, mode, rule_fn in _XTOOL_MODES:
        _add_slice(suite, rule_fn, cfg_name + "_xtool_app", ":" + ios, mode)
    for cfg_name, mode, rule_fn in _APPLE_MODES:
        _add_slice(suite, rule_fn, cfg_name + "_app_bundle", ":__%s_app_bundle" % apple_ios, mode)
    _add_slice(suite, _apple_device_dbg_test, "apple_dbg_split_assets", ":__%s_split_debug_assets" % apple_ios, "dbg")
    _add_slice(suite, _apple_device_dbg_test, "apple_dbg_intermediates", ":__%s_intermediates" % apple_ios, "dbg")
    _add_slice(suite, _apple_device_dbg_test, "fw_gen_dbg", ":%s_fw_gen_%s" % (name, flavor), "dbg")
    _add_slice(suite, _apple_device_opt_test, "fw_gen_opt", ":%s_fw_gen_%s" % (name, flavor), "opt")
    _add_slice(suite, _apple_device_opt_test, "xcf_device_fw", ":__%s_device_app_framework" % xcf, "opt")
    _add_slice(suite, _apple_sim_arm64_dbg_test, "xcf_sim_arm64_dbg", ":__%s_sim_arm64_app_framework" % xcf, "dbg")
    _add_slice(suite, _apple_sim_arm64_opt_test, "xcf_sim_arm64_opt", ":__%s_sim_arm64_app_framework" % xcf, "opt")
    _add_slice(suite, _apple_sim_x64_opt_test, "xcf_sim_x64_opt", ":__%s_sim_x64_app_framework" % xcf, "opt")

    for mode, reg_rule in [("dbg", _registrant_dbg_test), ("opt", _registrant_opt_test)]:
        _add_reg(suite, reg_rule, "apple_reg_" + mode, ":__%s_registrant" % apple_ios, mode, "swift")
        _add_reg(suite, reg_rule, "tier2_swift_reg_" + mode, ":%s_reg_swift_%s" % (name, flavor), mode, "swift")
        _add_reg(suite, reg_rule, "tier2_objc_reg_" + mode, ":%s_reg_objc_%s" % (name, flavor), mode, "objc")
    _add_reg(suite, _registrant_opt_test, "xcf_reg_opt", ":__%s_registrant" % xcf, "opt", "swift")

    for mode, aux_rule in [("dbg", _aux_dbg_test), ("opt", _aux_opt_test)]:
        _add_aux(suite, aux_rule, "privacy_" + mode, ":__%s_privacy_manifests" % apple_ios, mode, True)
        _add_aux(suite, aux_rule, "native_fw_" + mode, ":__%s_native_frameworks" % apple_ios, mode, False)
    return suite.tests

def flavor_ios_test_suite(name):
    """Declares the iOS flavor fixtures, analysis tests, and `test_suite`.

    Args:
        name: Prefix for every target declared here, and the `test_suite` name.
    """
    _declare_fixtures(name)
    tests = []
    for flavor in _FLAVORS:
        _declare_flavor_targets(name, flavor)
        tests.extend(_declare_flavor_tests(name, flavor))
    _ios_pair_probe(name = name + "_device_pair_probe", dev = ":%s_ios_dev" % name, prod = ":%s_ios_prod" % name, tags = ["manual"])
    _pair_transition_test(name = name + "_device_transition_pair", size = "small", target_under_test = ":%s_device_pair_probe" % name, prefix = name)
    tests.append(":%s_device_transition_pair" % name)
    native.test_suite(name = name, tests = tests)
