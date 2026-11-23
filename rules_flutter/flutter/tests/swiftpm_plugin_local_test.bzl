"""Unit tests for a plugin manifest's local (same-package) targets."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc//cc/common:objc_info.bzl", "ObjcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    "flutter_apple_plugin_library",
    "flutter_apple_plugin_objc_library",
)
load("//flutter/private:flutter_pub_apple.bzl", "apple_plugin_targets")
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "parse_plugin_local_package",
    "plugin_local_targets",
    "render_local_target_blocks",
    "with_apple_local_targets",
)
load("//flutter/private:swiftpm_package.bzl", "swiftpm_select_target_files")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _setting(kind, name, value = "", platforms = None):
    condition = struct(platforms = platforms) if platforms != None else None
    return struct(category = "c", kind = kind, name = name, value = value, condition = condition, line = 1)

def _target(name, deps = [], path = "", exclude = [], c_settings = [], swift_settings = [], public_headers_path = ""):
    return struct(
        kind = "target",
        name = name,
        deps = deps,
        path = path,
        exclude = exclude,
        sources = None,
        public_headers_path = public_headers_path,
        c_settings = c_settings,
        cxx_settings = [],
        swift_settings = swift_settings,
        linker_settings = [],
        line = 1,
    )

def _same(name, platforms = None):
    condition = struct(platforms = platforms) if platforms != None else None
    return struct(kind = "same", name = name, package = "", condition = condition)

def _product(name, targets):
    return struct(kind = "library", name = name, targets = targets, line = 1)

def _model(products, targets):
    return struct(products = products, targets = targets, pkg_deps = [], modes = [], tools_major = 5, tools_minor = 9)

_IMAGE_PICKER_OBJC = "ios/image_picker_ios/Sources/image_picker_ios_objc"
_IMAGE_PICKER_PRIMARY = "ios/image_picker_ios/Sources/image_picker_ios"

def _image_picker_model():
    objc = _target(
        "image_picker_ios_objc",
        path = "Sources/image_picker_ios_objc",
        exclude = ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"],
        c_settings = [_setting("headerSearchPath", "include/image_picker_ios")],
    )
    primary = _target(
        "image_picker_ios",
        deps = [_same("image_picker_ios_objc")],
        path = "Sources/image_picker_ios",
    )
    return _model([_product("image-picker-ios", ["image_picker_ios"])], [primary, objc])

def _image_picker_selected():
    files = {
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios.h": True,
        _IMAGE_PICKER_OBJC + "/include/ImagePickerPlugin.modulemap": True,
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios/messages.g.h": True,
        _IMAGE_PICKER_OBJC + "/messages.g.m": True,
    }
    dirs = {
        _IMAGE_PICKER_OBJC: True,
        _IMAGE_PICKER_OBJC + "/include": True,
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios": True,
    }
    target = _image_picker_model().targets[1]
    return swiftpm_select_target_files("image_picker_ios", target, _IMAGE_PICKER_OBJC, files, dirs)

def _image_picker_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    locals = plugin_local_targets("image_picker_ios", _image_picker_model(), "ios/image_picker_ios", _IMAGE_PICKER_PRIMARY, "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, 1, len(locals.targets))
    local = locals.targets[0]
    asserts.equals(env, "image_picker_ios_objc", local.name)
    asserts.equals(env, "image_picker_ios_objc", local.module_name)
    asserts.equals(env, _IMAGE_PICKER_OBJC, local.dir)

    selected = _image_picker_selected()
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.srcs)
    asserts.equals(env, [_IMAGE_PICKER_OBJC + "/messages.g.m"], selected.c_srcs)
    asserts.equals(env, [_IMAGE_PICKER_OBJC + "/include/image_picker_ios/messages.g.h"], selected.public_hdrs)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/include/image_picker_ios.h" not in selected.public_hdrs)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/include/ImagePickerPlugin.modulemap" not in selected.public_hdrs)

    rendered = render_local_target_blocks("image_picker_ios", "ios", locals.targets, {"image_picker_ios_objc": selected})
    asserts.true(env, rendered.ok)
    asserts.equals(env, [":image_picker_ios_apple_ios__image_picker_ios_objc"], rendered.labels)
    asserts.true(env, "flutter_apple_plugin_objc_library(" in rendered.text)
    asserts.true(env, "module_name = \"image_picker_ios_objc\"" in rendered.text)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/messages.g.m" in rendered.text)
    asserts.true(env, "include/image_picker_ios.h" not in rendered.text)
    asserts.true(env, "include/image_picker_ios\"" in rendered.text)

    content = apple_plugin_targets("image_picker_ios", [_IMAGE_PICKER_PRIMARY], [], "ios")
    patched = with_apple_local_targets(content, "image_picker_ios", "ios", rendered)
    asserts.true(env, "\":image_picker_ios_apple_ios__image_picker_ios_objc\"," in patched)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/messages.g.m" in patched)
    asserts.equals(env, 1, len(patched.split(":image_picker_ios_apple_ios__image_picker_ios_objc")) - 1)
    return unittest.end(env)

def _firebase_core_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    objc = _target(
        "firebase_core_objc",
        path = "Sources/firebase_core_objc",
        c_settings = [_setting("headerSearchPath", "include"), _setting("define", "LIBRARY_NAME", "flutter-fire-core")],
        public_headers_path = "include",
    )
    primary = _target(
        "firebase_core",
        deps = [_same("firebase_core_objc")],
        path = "Sources/firebase_core",
    )
    model = _model([_product("firebase-core", ["firebase_core", "firebase_core_objc"])], [objc, primary])
    locals = plugin_local_targets("firebase_core", model, "ios/firebase_core", "ios/firebase_core/Sources/firebase_core", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, 1, len(locals.targets))
    asserts.equals(env, "firebase_core_objc", locals.targets[0].name)

    selected = struct(ok = True, srcs = [], c_srcs = ["ios/firebase_core/Sources/firebase_core_objc/plugin.m"], public_hdrs = ["ios/firebase_core/Sources/firebase_core_objc/include/plugin.h"], private_hdrs = [], explicit_map = None, map_in_include = False)
    rendered = render_local_target_blocks("firebase_core", "ios", locals.targets, {"firebase_core_objc": selected})
    asserts.true(env, rendered.ok)
    content = apple_plugin_targets("firebase_core", ["ios/firebase_core/Sources/firebase_core"], [], "ios")
    patched = with_apple_local_targets(content, "firebase_core", "ios", rendered)
    asserts.true(env, "name = \"firebase_core_apple_ios\"" in patched)
    asserts.true(env, "name = \"firebase_core_apple_ios__firebase_core_objc\"" in patched)
    asserts.true(env, "\"-DLIBRARY_NAME=flutter-fire-core\"" in rendered.text)
    return unittest.end(env)

def _video_player_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    sibling_headers = "../video_player_avfoundation_objc/include/video_player_avfoundation_objc"
    ios = _target("video_player_avfoundation_ios", path = "Sources/video_player_avfoundation_ios", c_settings = [_setting("headerSearchPath", sibling_headers)])
    macos = _target("video_player_avfoundation_macos", path = "Sources/video_player_avfoundation_macos", c_settings = [_setting("headerSearchPath", sibling_headers)])
    objc = _target(
        "video_player_avfoundation_objc",
        deps = [_same("video_player_avfoundation_ios", ["ios"]), _same("video_player_avfoundation_macos", ["macos"])],
        path = "Sources/video_player_avfoundation_objc",
    )
    primary = _target(
        "video_player_avfoundation",
        deps = [_same("video_player_avfoundation_objc")],
        path = "Sources/video_player_avfoundation",
    )
    manifest = "darwin/video_player_avfoundation"
    model = _model([_product("video-player-avfoundation", ["video_player_avfoundation"])], [primary, objc, ios, macos])
    locals = plugin_local_targets("video_player_avfoundation", model, manifest, manifest + "/Sources/video_player_avfoundation", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["video_player_avfoundation_objc", "video_player_avfoundation_ios"], [target.name for target in locals.targets])

    files = {
        "video_player_avfoundation_objc": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_objc/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
        "video_player_avfoundation_ios": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_ios/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    rendered = render_local_target_blocks("video_player_avfoundation", "ios", locals.targets, files)
    asserts.true(env, rendered.ok)
    asserts.true(env, "select({" in rendered.text)
    asserts.true(env, "\"@platforms//os:ios\": [" in rendered.text)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_ios" in rendered.text)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_macos" not in rendered.text)
    asserts.true(env, manifest + "/Sources/video_player_avfoundation_objc/include/video_player_avfoundation_objc" in rendered.text)

    content = apple_plugin_targets("video_player_avfoundation", [manifest + "/Sources/video_player_avfoundation"], [], "ios")
    patched = with_apple_local_targets(content, "video_player_avfoundation", "ios", rendered)
    asserts.true(env, "\":video_player_avfoundation_apple_ios__video_player_avfoundation_ios\"," in patched)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_macos" not in patched)

    macos_locals = plugin_local_targets("video_player_avfoundation", model, manifest, manifest + "/Sources/video_player_avfoundation", "macos")
    asserts.true(env, macos_locals.ok)
    asserts.equals(env, ["video_player_avfoundation_objc", "video_player_avfoundation_macos"], [target.name for target in macos_locals.targets])
    macos_files = {
        "video_player_avfoundation_objc": files["video_player_avfoundation_objc"],
        "video_player_avfoundation_macos": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_macos/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    macos = render_local_target_blocks("video_player_avfoundation", "macos", macos_locals.targets, macos_files)
    asserts.true(env, macos.ok)
    asserts.true(env, "\"@platforms//os:macos\": [" in macos.text)
    asserts.true(env, ":video_player_avfoundation_apple_macos__video_player_avfoundation_macos" in macos.text)
    asserts.true(env, ":video_player_avfoundation_apple_macos__video_player_avfoundation_ios" not in macos.text)
    return unittest.end(env)

def _missing_directory_test_impl(ctx):
    env = unittest.begin(ctx)
    locals = plugin_local_targets("image_picker_ios", _image_picker_model(), "ios/image_picker_ios", _IMAGE_PICKER_PRIMARY, "ios")
    rendered = render_local_target_blocks("image_picker_ios", "ios", locals.targets, {})
    asserts.true(env, not rendered.ok)
    asserts.true(env, "image_picker_ios" in rendered.error)
    asserts.true(env, "image_picker_ios_objc" in rendered.error)
    asserts.true(env, _IMAGE_PICKER_OBJC in rendered.error)
    return unittest.end(env)

def _binary_target_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    binary = struct(kind = "binaryTarget", name = "Blob", deps = [], path = "", exclude = [], sources = None, public_headers_path = "", c_settings = [], cxx_settings = [], swift_settings = [], linker_settings = [], line = 1)
    primary = _target("plugin", path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin", "Blob"])], [primary, binary])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, not locals.ok)
    asserts.equals(env, "binary targets in plugin manifests land in POD-10", locals.error)
    return unittest.end(env)

def _parser_keeps_target_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "image_picker_ios",
    products: [.library(name: "image-picker-ios", targets: ["image_picker_ios"])],
    targets: [
        .target(name: "image_picker_ios", dependencies: ["image_picker_ios_objc"], resources: [.process("Resources")]),
        .target(
            name: "image_picker_ios_objc",
            exclude: ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"],
            cSettings: [.headerSearchPath("include/image_picker_ios")],
            publicHeadersPath: "include",
        ),
    ]
)
"""
    parsed = parse_plugin_local_package("image_picker_ios", manifest)
    asserts.true(env, parsed.ok)
    objc = parsed.model.targets[1]
    asserts.equals(env, ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"], objc.exclude)
    asserts.equals(env, "include", objc.public_headers_path)
    asserts.equals(env, ("headerSearchPath", "include/image_picker_ios"), (objc.c_settings[0].kind, objc.c_settings[0].name))
    return unittest.end(env)

def _parser_skips_untranslated_args_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "image_picker_ios",
    defaultLocalization: "en",
    platforms: [
        .iOS("11.0")
    ],
    products: [.library(name: "image-picker-ios", targets: ["image_picker_ios"])],
    targets: [
        .target(
            name: "image_picker_ios",
            dependencies: ["image_picker_ios_objc"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "image_picker_ios_objc",
            packageAccess: true,
            exclude: ["include/image_picker_ios.h"],
            cSettings: [.headerSearchPath("include/image_picker_ios")],
        ),
    ]
)
"""
    parsed = parse_plugin_local_package("image_picker_ios", manifest)
    asserts.true(env, parsed.ok, "parse failed: %s" % parsed.error)
    objc = parsed.model.targets[1]
    asserts.equals(env, ["include/image_picker_ios.h"], objc.exclude)
    asserts.equals(env, ("headerSearchPath", "include/image_picker_ios"), (objc.c_settings[0].kind, objc.c_settings[0].name))
    locals = plugin_local_targets("image_picker_ios", parsed.model, "ios/image_picker_ios", "ios/image_picker_ios/Sources/image_picker_ios", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["image_picker_ios_objc"], [target.name for target in locals.targets])
    return unittest.end(env)

def _primary_only_keeps_base_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    primary = _target("plain_plugin", path = "Sources/plain_plugin")
    model = _model([_product("plain-plugin", ["plain_plugin"])], [primary])
    locals = plugin_local_targets("plain_plugin", model, "ios/plain_plugin", "ios/plain_plugin/Sources/plain_plugin", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, [], locals.targets)
    asserts.equals(env, "plain_plugin", locals.primary.name)

    rendered = render_local_target_blocks("plain_plugin", "ios", locals.targets, {})
    asserts.true(env, rendered.ok)
    asserts.equals(env, "", rendered.text)
    content = apple_plugin_targets("plain_plugin", ["ios/plain_plugin/Sources/plain_plugin"], [], "ios")
    asserts.equals(env, content, with_apple_local_targets(content, "plain_plugin", "ios", rendered))
    return unittest.end(env)

def _transitive_default_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    leaf = _target("leaf")
    middle = _target("middle", deps = [_same("leaf")], path = "Sources/middle")
    primary = _target("root", deps = [_same("middle")], path = "Sources/root")
    model = _model([_product("root", ["root"])], [primary, middle, leaf])
    locals = plugin_local_targets("root", model, "ios/root", "ios/root/Sources/root", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["middle", "leaf"], [target.name for target in locals.targets])
    asserts.equals(env, "ios/root/Sources/leaf", locals.targets[1].dir)
    asserts.equals(env, "ios/root/Sources/leaf", locals.targets[1].directory)
    asserts.equals(env, [":root_apple_ios__leaf"], [edge.text for edge in locals.targets[0].edges])
    return unittest.end(env)

def _product_targets_in_manifest_order_test_impl(ctx):
    env = unittest.begin(ctx)
    first_objc = _target("first_objc", path = "Sources/first_objc")
    second_objc = _target("second-objc", path = "Sources/second_objc")
    primary = _target("primary", path = "Sources/primary")
    model = _model(
        [_product("two-objc", ["primary", "first_objc", "second-objc"])],
        [primary, first_objc, second_objc],
    )
    locals = plugin_local_targets("two_objc", model, "ios/two_objc", "ios/two_objc/Sources/primary", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["first_objc", "second-objc"], [target.name for target in locals.targets])
    asserts.equals(env, ["first_objc", "second_objc"], [target.module_name for target in locals.targets])
    asserts.equals(env, ["target", "target"], [target.kind for target in locals.targets])
    return unittest.end(env)

def _define_and_condition_select_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target(
        "conditional",
        path = "Sources/conditional",
        c_settings = [
            _setting("define", "ENABLED", "1", platforms = ["ios"]),
            _setting("headerSearchPath", "../conditional/include", platforms = ["macos"]),
        ],
        public_headers_path = "include",
    )
    primary = _target("conditional_plugin", deps = [_same("conditional")], path = "Sources/conditional_plugin")
    model = _model([_product("conditional-plugin", ["conditional_plugin"])], [primary, local])
    locals = plugin_local_targets("conditional_plugin", model, "ios/conditional_plugin", "ios/conditional_plugin/Sources/conditional_plugin", "ios")
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/conditional_plugin/Sources/conditional/a.m"],
        public_hdrs = ["ios/conditional_plugin/Sources/conditional/include/a.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("conditional_plugin", "ios", locals.targets, {"conditional": selected})
    asserts.true(env, rendered.ok)
    asserts.true(env, "copts = select({" in rendered.text)
    asserts.true(env, "conlyopts = " not in rendered.text)
    asserts.true(env, "\"-DENABLED=1\"," in rendered.text)
    asserts.true(env, "\"@platforms//os:ios\": [" in rendered.text)
    asserts.true(env, "\"@platforms//os:macos\": [" in rendered.text)
    asserts.true(env, "ios/conditional_plugin/Sources/conditional/../conditional/include" not in rendered.text)
    asserts.true(env, "ios/conditional_plugin/Sources/conditional/include" in rendered.text)
    return unittest.end(env)

def _render_local_plugin_defines_test_impl(ctx):
    env = unittest.begin(ctx)
    objc = _target("plugin_objc", path = "Sources/plugin_objc")
    swift = _target("plugin_swift", path = "Sources/plugin_swift")
    primary = _target(
        "plugin",
        deps = [_same("plugin_objc"), _same("plugin_swift")],
        path = "Sources/plugin",
    )
    model = _model([_product("plugin", ["plugin"])], [primary, objc, swift])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, locals.ok)
    files = {
        "plugin_objc": struct(
            ok = True,
            srcs = [],
            c_srcs = ["ios/plugin/Sources/plugin_objc/value.m"],
            public_hdrs = [],
            private_hdrs = [],
            explicit_map = None,
            map_in_include = False,
        ),
        "plugin_swift": struct(
            ok = True,
            srcs = ["ios/plugin/Sources/plugin_swift/value.swift"],
            c_srcs = [],
            public_hdrs = [],
            private_hdrs = [],
            explicit_map = None,
            map_in_include = False,
        ),
    }
    defines = ["PERMISSION_CAMERA=1", "PLUGIN_FLAG"]
    rendered = render_local_target_blocks(
        "plugin",
        "ios",
        locals.targets,
        files,
        plugin_defines = defines,
    )
    asserts.true(env, rendered.ok)
    asserts.true(env, "flutter_apple_plugin_objc_library(" in rendered.text)
    asserts.true(env, "flutter_apple_plugin_library(" in rendered.text)
    asserts.equals(env, 2, rendered.text.count('plugin_defines = ["PERMISSION_CAMERA=1", "PLUGIN_FLAG"],'))
    plain = render_local_target_blocks("plugin", "ios", locals.targets, files)
    asserts.true(env, plain.ok)
    asserts.true(env, "plugin_defines" not in plain.text)
    return unittest.end(env)

def _primary_conditional_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target("plugin_objc", path = "Sources/plugin_objc", public_headers_path = "include")
    primary = _target("plugin", deps = [_same("plugin_objc", ["ios"])], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, local])
    ios = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, ios.ok)
    asserts.equals(env, ["plugin_objc"], [target.name for target in ios.targets])
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/plugin/Sources/plugin_objc/value.m"],
        public_hdrs = ["ios/plugin/Sources/plugin_objc/include/value.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("plugin", "ios", ios.targets, {"plugin_objc": selected})
    asserts.true(env, rendered.ok)
    asserts.equals(env, [":plugin_apple_ios__plugin_objc"], rendered.labels)

    macos = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "macos")
    asserts.true(env, macos.ok)
    asserts.equals(env, [], [target.name for target in macos.targets])
    macos_rendered = render_local_target_blocks("plugin", "macos", macos.targets, {})
    asserts.true(env, macos_rendered.ok)
    asserts.equals(env, "", macos_rendered.text)
    return unittest.end(env)

def _binary_dependency_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    binary = struct(kind = "binaryTarget", name = "Artifact", deps = [], path = "", exclude = [], sources = None, public_headers_path = "", c_settings = [], cxx_settings = [], swift_settings = [], linker_settings = [], line = 1)
    primary = _target("plugin", deps = [_same("Artifact")], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, binary])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, not locals.ok)
    asserts.equals(env, "binary targets in plugin manifests land in POD-10", locals.error)
    return unittest.end(env)

def _xtool_appends_local_files_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target(
        "plugin_objc",
        path = "Sources/plugin_objc",
        c_settings = [_setting("headerSearchPath", "include")],
        public_headers_path = "include",
    )
    primary = _target("plugin", deps = [_same("plugin_objc")], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, local])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/plugin/Sources/plugin_objc/value.m"],
        public_hdrs = ["ios/plugin/Sources/plugin_objc/include/value.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("plugin", "ios", locals.targets, {"plugin_objc": selected})
    content = apple_plugin_targets("plugin", ["ios/plugin/Sources/plugin"], [], "ios")
    patched = with_apple_local_targets(content, "plugin", "ios", rendered)
    asserts.true(env, ") + [" in patched)
    asserts.true(env, "ios/plugin/Sources/plugin_objc/value.m" in patched)
    asserts.true(env, "ios/plugin/Sources/plugin_objc/include/value.h" in patched)
    asserts.true(env, "\":plugin_apple_ios__plugin_objc\"," in patched)
    return unittest.end(env)

def _byname_local_manifest(deps, with_local = False):
    """Build a plugin manifest whose primary target carries `deps`."""
    extra = ""
    if with_local:
        extra = ',\n        .target(name: "image_picker_ios_objc", cSettings: [.headerSearchPath("include/image_picker_ios")])'
    return """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "image_picker_ios",
    products: [.library(name: "image-picker-ios", targets: ["image_picker_ios"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],
    targets: [
        .target(name: "image_picker_ios", dependencies: [%s])%s
    ]
)
""" % (deps, extra)

def _parse_and_walk_local(deps, with_local = False):
    """Parse `_byname_local_manifest` and run `plugin_local_targets`."""
    parsed = parse_plugin_local_package("image_picker_ios", _byname_local_manifest(deps, with_local))
    return plugin_local_targets(
        "image_picker_ios",
        parsed.model,
        "ios/image_picker_ios",
        _IMAGE_PICKER_PRIMARY,
        "ios",
    )

def _byname_dependencies_test_impl(ctx):
    """By-name external products are skipped while by-name local targets are followed."""
    env = unittest.begin(ctx)
    expected_only = _parse_and_walk_local('.product(name: "BigInt", package: "BigInt")')
    byname_only = _parse_and_walk_local('"BigInt", .byName(name: "BigInt")')
    asserts.true(env, expected_only.ok, expected_only.error)
    asserts.true(env, byname_only.ok, byname_only.error)
    asserts.equals(env, expected_only.targets, byname_only.targets)

    expected = _parse_and_walk_local(
        '.product(name: "BigInt", package: "BigInt"), .target(name: "image_picker_ios_objc")',
        with_local = True,
    )
    byname = _parse_and_walk_local(
        '"BigInt", .byName(name: "BigInt"), "image_picker_ios_objc"',
        with_local = True,
    )
    case_local = _parse_and_walk_local(
        '"bigint", .byName(name: "IMAGE_PICKER_IOS_OBJC")',
        with_local = True,
    )
    asserts.true(env, expected.ok, expected.error)
    asserts.true(env, byname.ok, byname.error)
    asserts.equals(env, expected.targets, byname.targets)
    asserts.equals(env, ["image_picker_ios_objc"], [t.name for t in byname.targets])
    asserts.true(env, case_local.ok, case_local.error)
    asserts.equals(env, ["image_picker_ios_objc"], [t.name for t in case_local.targets])
    return unittest.end(env)

_image_picker_shape_test = unittest.make(_image_picker_shape_test_impl)
_primary_only_keeps_base_shape_test = unittest.make(_primary_only_keeps_base_shape_test_impl)
_transitive_default_dirs_test = unittest.make(_transitive_default_dirs_test_impl)
_product_targets_in_manifest_order_test = unittest.make(_product_targets_in_manifest_order_test_impl)
_define_and_condition_select_test = unittest.make(_define_and_condition_select_test_impl)
_render_local_plugin_defines_test = unittest.make(_render_local_plugin_defines_test_impl)
_primary_conditional_dep_test = unittest.make(_primary_conditional_dep_test_impl)
_binary_dependency_refusal_test = unittest.make(_binary_dependency_refusal_test_impl)
_xtool_appends_local_files_test = unittest.make(_xtool_appends_local_files_test_impl)
_byname_dependencies_test = unittest.make(_byname_dependencies_test_impl)
_firebase_core_shape_test = unittest.make(_firebase_core_shape_test_impl)
_video_player_shape_test = unittest.make(_video_player_shape_test_impl)
_missing_directory_test = unittest.make(_missing_directory_test_impl)
_binary_target_refusal_test = unittest.make(_binary_target_refusal_test_impl)
_parser_keeps_target_settings_test = unittest.make(_parser_keeps_target_settings_test_impl)
_parser_skips_untranslated_args_test = unittest.make(_parser_skips_untranslated_args_test_impl)

def _apple_test_config_settings(platform):
    """Config settings that analyze an Apple target off macOS."""
    return {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % platform)),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    }

def _spm_objc_module_test_impl(ctx):
    """Asserts provider presence, Clang module name, modulemap, and public headers."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    asserts.true(env, CcInfo in tut, "Expected CcInfo on %s" % tut.label)
    asserts.true(env, ObjcInfo in tut, "Expected ObjcInfo on %s" % tut.label)
    asserts.true(env, SwiftInfo in tut, "Expected SwiftInfo on %s" % tut.label)
    asserts.true(
        env,
        FlutterApplePluginInfo in tut,
        "Expected FlutterApplePluginInfo on %s" % tut.label,
    )

    if SwiftInfo not in tut:
        return analysistest.end(env)

    matching = [
        m
        for m in tut[SwiftInfo].direct_modules
        if m.name == ctx.attr.expected_module_name and m.clang != None
    ]
    asserts.equals(
        env,
        1,
        len(matching),
        "Expected one Clang module '%s' in direct_modules, got: %s" % (
            ctx.attr.expected_module_name,
            [m.name for m in tut[SwiftInfo].direct_modules],
        ),
    )
    if matching:
        clang = matching[0].clang
        asserts.true(env, clang.module_map != None, "Expected non-None module_map")
        if clang.module_map != None:
            map_path = clang.module_map.path if hasattr(clang.module_map, "path") else str(clang.module_map)
            asserts.true(
                env,
                map_path.endswith("module.modulemap"),
                "Expected module_map ending in 'module.modulemap', got %s" % map_path,
            )
        headers = [h.basename for h in clang.compilation_context.headers.to_list()]
        asserts.true(
            env,
            ctx.attr.expected_header_basename in headers,
            "Expected '%s' in Clang compilation_context headers, got: %s" % (
                ctx.attr.expected_header_basename,
                headers,
            ),
        )
    return analysistest.end(env)

def _spm_swift_consumer_test_impl(ctx):
    """Asserts transitive Clang module and SwiftCompile modulemap + header inputs."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    asserts.true(env, SwiftInfo in tut, "Expected SwiftInfo on %s" % tut.label)
    if SwiftInfo in tut:
        transitive_clang_names = [
            m.name
            for m in tut[SwiftInfo].transitive_modules.to_list()
            if m.clang != None
        ]
        asserts.true(
            env,
            ctx.attr.expected_module_name in transitive_clang_names,
            "Expected '%s' in transitive Clang modules, got: %s" % (
                ctx.attr.expected_module_name,
                transitive_clang_names,
            ),
        )

    compile_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "SwiftCompile"
    ]
    asserts.true(env, bool(compile_actions), "Expected a SwiftCompile action on %s" % tut.label)
    if compile_actions:
        input_basenames = [f.basename for f in compile_actions[0].inputs.to_list()]
        asserts.true(
            env,
            "module.modulemap" in input_basenames,
            "Expected 'module.modulemap' in SwiftCompile action inputs, got: %s" % input_basenames,
        )
        asserts.true(
            env,
            ctx.attr.expected_header_basename in input_basenames,
            "Expected '%s' in SwiftCompile action inputs, got: %s" % (
                ctx.attr.expected_header_basename,
                input_basenames,
            ),
        )
    return analysistest.end(env)

def _spm_headerless_objc_test_impl(ctx):
    """Asserts headerless ObjC target provides providers and no direct Clang module."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    asserts.true(env, CcInfo in tut, "Expected CcInfo on %s" % tut.label)
    asserts.true(env, ObjcInfo in tut, "Expected ObjcInfo on %s" % tut.label)
    asserts.true(env, SwiftInfo in tut, "Expected SwiftInfo on %s" % tut.label)
    asserts.true(
        env,
        FlutterApplePluginInfo in tut,
        "Expected FlutterApplePluginInfo on %s" % tut.label,
    )

    if SwiftInfo in tut:
        direct_clang = [m for m in tut[SwiftInfo].direct_modules if m.clang != None]
        asserts.equals(
            env,
            [],
            direct_clang,
            "Expected no direct Clang module for headerless ObjC target, got: %s" % [
                m.name
                for m in direct_clang
            ],
        )
    return analysistest.end(env)

def _spm_mixed_plugin_test_impl(ctx):
    """Asserts mixed plugin direct_modules and no duplicate synthesized Clang module."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    asserts.true(env, SwiftInfo in tut, "Expected SwiftInfo on %s" % tut.label)
    if SwiftInfo in tut:
        direct_names = [m.name for m in tut[SwiftInfo].direct_modules]
        asserts.equals(
            env,
            [ctx.attr.expected_mixed_module],
            direct_names,
            "Expected direct_modules to equal [%s], got: %s" % (
                ctx.attr.expected_mixed_module,
                direct_names,
            ),
        )
        objc_target_name = "_" + tut.label.name + "__objc"
        for m in tut[SwiftInfo].transitive_modules.to_list():
            if m.clang != None:
                asserts.true(
                    env,
                    m.name != objc_target_name and not m.name.endswith("__objc"),
                    "Transitive Clang module unexpectedly synthesized from %s: %s" % (
                        objc_target_name,
                        m.name,
                    ),
                )
    return analysistest.end(env)

_ios_spm_objc_module_test = analysistest.make(
    _spm_objc_module_test_impl,
    attrs = {
        "expected_header_basename": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
    },
    config_settings = _apple_test_config_settings("ios"),
)

_macos_spm_objc_module_test = analysistest.make(
    _spm_objc_module_test_impl,
    attrs = {
        "expected_header_basename": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
    },
    config_settings = _apple_test_config_settings("macos"),
)

_ios_spm_swift_consumer_test = analysistest.make(
    _spm_swift_consumer_test_impl,
    attrs = {
        "expected_header_basename": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
    },
    config_settings = _apple_test_config_settings("ios"),
)

_macos_spm_swift_consumer_test = analysistest.make(
    _spm_swift_consumer_test_impl,
    attrs = {
        "expected_header_basename": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
    },
    config_settings = _apple_test_config_settings("macos"),
)

_ios_spm_headerless_objc_test = analysistest.make(
    _spm_headerless_objc_test_impl,
    config_settings = _apple_test_config_settings("ios"),
)

_ios_spm_mixed_plugin_test = analysistest.make(
    _spm_mixed_plugin_test_impl,
    attrs = {
        "expected_mixed_module": attr.string(mandatory = True),
    },
    config_settings = _apple_test_config_settings("ios"),
)

def _register_spm_fixture_files(name):
    """Writes source and header fixtures for SPM plugin analysis tests."""
    hdr_file = name + "_spm_objc_plugin_value.h"
    objc_src = name + "_spm_objc_plugin_value.m"
    swift_src = name + "_spm_objc_swift_plugin.swift"
    headerless_src = name + "_spm_headerless.m"
    mixed_swift_src = name + "_spm_mixed.swift"
    mixed_objc_src = name + "_spm_mixed.m"
    mixed_hdr_src = name + "_spm_mixed.h"

    write_file(
        name = name + "_spm_objc_hdr_file",
        out = hdr_file,
        content = ["#pragma once", "int spm_answer(void);"],
    )
    write_file(
        name = name + "_spm_objc_src_file",
        out = objc_src,
        content = ["#include \"" + hdr_file + "\"", "int spm_answer(void) { return 42; }"],
    )
    write_file(
        name = name + "_spm_swift_src_file",
        out = swift_src,
        content = [
            "import Flutter",
            "import spm_objc_plugin_objc",
            "public class SpmSwiftPlugin: NSObject {}",
        ],
    )
    write_file(
        name = name + "_spm_headerless_src_file",
        out = headerless_src,
        content = ["int headerless_value(void) { return 1; }"],
    )
    write_file(
        name = name + "_spm_mixed_swift_src_file",
        out = mixed_swift_src,
        content = ["import Flutter", "public class SpmMixedPlugin: NSObject {}"],
    )
    write_file(
        name = name + "_spm_mixed_objc_src_file",
        out = mixed_objc_src,
        content = ["#import \"" + mixed_hdr_src + "\"", "int mixed_func(void) { return 3; }"],
    )
    write_file(
        name = name + "_spm_mixed_hdr_src_file",
        out = mixed_hdr_src,
        content = ["#pragma once"],
    )

    return struct(
        hdr_file = hdr_file,
        headerless_src = headerless_src,
        mixed_hdr_src = mixed_hdr_src,
        mixed_objc_src = mixed_objc_src,
        mixed_swift_src = mixed_swift_src,
        objc_src = objc_src,
        swift_src = swift_src,
    )

def _register_spm_plugin_analysis_tests(name):
    """Instantiate Apple analysis fixtures and test targets for local SPM packages."""
    files = _register_spm_fixture_files(name)
    tests = []
    for platform, objc_test, consumer_test in [
        ("ios", _ios_spm_objc_module_test, _ios_spm_swift_consumer_test),
        ("macos", _macos_spm_objc_module_test, _macos_spm_swift_consumer_test),
    ]:
        objc_target = "%s_%s_spm_objc_plugin_objc" % (name, platform)
        swift_target = "%s_%s_spm_objc_plugin_swift" % (name, platform)
        objc_test_name = "%s_%s_objc_module_test" % (name, platform)
        consumer_test_name = "%s_%s_swift_consumer_test" % (name, platform)

        flutter_apple_plugin_objc_library(
            name = objc_target,
            hdrs = [":" + files.hdr_file],
            module_name = "spm_objc_plugin_objc",
            platform = platform,
            srcs = [":" + files.objc_src],
        )
        flutter_apple_plugin_library(
            name = swift_target,
            deps = [":" + objc_target],
            module_name = "spm_objc_plugin",
            platform = platform,
            srcs = [":" + files.swift_src],
            tags = ["manual"],
        )
        objc_test(
            name = objc_test_name,
            expected_header_basename = files.hdr_file,
            expected_module_name = "spm_objc_plugin_objc",
            target_under_test = ":" + objc_target,
        )
        consumer_test(
            name = consumer_test_name,
            expected_header_basename = files.hdr_file,
            expected_module_name = "spm_objc_plugin_objc",
            target_under_test = ":" + swift_target,
        )
        tests.extend([":" + objc_test_name, ":" + consumer_test_name])

    headerless_target = name + "_headerless_spm_objc"
    headerless_test_name = name + "_headerless_objc_test"
    flutter_apple_plugin_objc_library(
        name = headerless_target,
        hdrs = [],
        module_name = "spm_headerless_objc",
        platform = "ios",
        srcs = [":" + files.headerless_src],
    )
    _ios_spm_headerless_objc_test(
        name = headerless_test_name,
        target_under_test = ":" + headerless_target,
    )
    tests.append(":" + headerless_test_name)

    mixed_target = name + "_mixed_spm_plugin"
    mixed_test_name = name + "_mixed_plugin_test"
    flutter_apple_plugin_library(
        name = mixed_target,
        module_name = "spm_mixed_plugin",
        platform = "ios",
        srcs = [":" + files.mixed_swift_src, ":" + files.mixed_objc_src, ":" + files.mixed_hdr_src],
        tags = ["manual"],
    )
    _ios_spm_mixed_plugin_test(
        name = mixed_test_name,
        expected_mixed_module = "spm_mixed_plugin",
        target_under_test = ":" + mixed_target,
    )
    tests.append(":" + mixed_test_name)
    return tests

def swiftpm_plugin_local_test_suite(name):
    """Registers the plugin-local target unit tests."""
    small_unittest_suite(
        name + "_unit",
        _image_picker_shape_test,
        _firebase_core_shape_test,
        _video_player_shape_test,
        _missing_directory_test,
        _binary_target_refusal_test,
        _parser_keeps_target_settings_test,
        _parser_skips_untranslated_args_test,
        _primary_only_keeps_base_shape_test,
        _transitive_default_dirs_test,
        _product_targets_in_manifest_order_test,
        _define_and_condition_select_test,
        _render_local_plugin_defines_test,
        _primary_conditional_dep_test,
        _binary_dependency_refusal_test,
        _xtool_appends_local_files_test,
        _byname_dependencies_test,
    )
    analysis_tests = _register_spm_plugin_analysis_tests(name)
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"] + analysis_tests,
    )
