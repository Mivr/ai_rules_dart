"""Unit tests for flutter_pubspec.bzl's plain data.

Each fixture is a pubspec as `yaml_to_json` decodes it: booleans stay
booleans, empty values are None and every other scalar is its source text.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pubspec.bzl",
    "parse_flutter_block",
    "parse_flutter_plugin_block",
    "pubspec_file_roots",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

# Federated umbrella — only default_package per platform, no plugin classes.
_PATH_PROVIDER_PUBSPEC = {
    "name": "path_provider",
    "description": "Flutter plugin for getting commonly used locations on host platforms.",
    "version": "2.1.5",
    "environment": {"sdk": "^3.0.0"},
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {"default_package": "path_provider_android"},
                "ios": {"default_package": "path_provider_foundation"},
                "linux": {"default_package": "path_provider_linux"},
                "macos": {"default_package": "path_provider_foundation"},
                "windows": {"default_package": "path_provider_windows"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Federated implementation — implements + dartPluginClass on its platform.
_PATH_PROVIDER_FOUNDATION_PUBSPEC = {
    "name": "path_provider_foundation",
    "flutter": {
        "plugin": {
            "implements": "path_provider",
            "platforms": {
                "ios": {"dartPluginClass": "PathProviderFoundation"},
                "macos": {"dartPluginClass": "PathProviderFoundation"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Monolithic plugin — direct platforms with pluginClass / dartPluginClass /
# package / fileName, no implements/default_package.
_PACKAGE_INFO_PLUS_PUBSPEC = {
    "name": "package_info_plus",
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {
                    "package": "dev.fluttercommunity.plus.packageinfo",
                    "pluginClass": "PackageInfoPlugin",
                },
                "ios": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "linux": {"dartPluginClass": "PackageInfoPlusLinuxPlugin"},
                "macos": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "web": {
                    "pluginClass": "PackageInfoPlusWebPlugin",
                    "fileName": "src/package_info_plus_web.dart",
                },
                "windows": {"dartPluginClass": "PackageInfoPlusWindowsPlugin"},
            },
        },
    },
}

# Federated impl with both pluginClass and dartPluginClass + fileName.
_URL_LAUNCHER_MACOS_PUBSPEC = {
    "name": "url_launcher_macos",
    "flutter": {
        "plugin": {
            "implements": "url_launcher",
            "platforms": {
                "macos": {
                    "pluginClass": "UrlLauncherPlugin",
                    "fileName": "url_launcher_macos.dart",
                    "dartPluginClass": "UrlLauncherMacOS",
                },
            },
        },
    },
}

# Non-plugin package (e.g. path_provider_platform_interface).
_NO_PLUGIN_PUBSPEC = {
    "name": "path_provider_platform_interface",
    "dependencies": {"flutter": {"sdk": "flutter"}, "plugin_platform_interface": "^2.1.0"},
}

# cupertino_icons — flutter.fonts only.
_CUPERTINO_ICONS_PUBSPEC = {
    "name": "cupertino_icons",
    "version": "1.0.9",
    "flutter": {
        "fonts": [
            {
                "family": "CupertinoIcons",
                "fonts": [{"asset": "assets/CupertinoIcons.ttf"}],
            },
        ],
    },
}

# Hypothetical font with weight + style attributes.
_FONT_WITH_VARIANTS_PUBSPEC = {
    "name": "example",
    "flutter": {
        "fonts": [
            {
                "family": "Roboto",
                "fonts": [
                    {"asset": "fonts/Roboto-Regular.ttf"},
                    {"asset": "fonts/Roboto-Bold.ttf", "weight": "700"},
                    {
                        "asset": "fonts/Roboto-Italic.ttf",
                        "weight": "400",
                        "style": "italic",
                    },
                ],
            },
        ],
    },
}

# Asset-shipping package (flutter_localized_locales-style).
_LOCALES_PUBSPEC = {"name": "flutter_localized_locales", "flutter": {"assets": ["data/"]}}

# Modern map-form assets with flavors + platforms.
_MAP_FORM_ASSETS_PUBSPEC = {
    "name": "example",
    "flutter": {
        "assets": [
            {
                "path": "assets/foo.png",
                "flavors": ["prod"],
                "platforms": ["ios", "android"],
            },
            "assets/bar.png",
        ],
    },
}

# Shaders + material design flag.
_MATERIAL_AND_SHADERS_PUBSPEC = {
    "name": "example",
    "flutter": {"uses-material-design": True, "shaders": ["shaders/ink_sparkle.frag"]},
}

# ---------------------------------------------------------------------------
# parse_flutter_plugin_block
# ---------------------------------------------------------------------------

def _umbrella_default_package_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block(_PATH_PROVIDER_PUBSPEC)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, False, result.ffi_plugin)
    asserts.equals(env, 5, len(result.platforms))
    asserts.equals(env, "path_provider_android", result.platforms["android"]["default_package"])
    asserts.equals(env, "path_provider_foundation", result.platforms["macos"]["default_package"])
    asserts.equals(env, "path_provider_windows", result.platforms["windows"]["default_package"])

    asserts.true(env, "pluginClass" not in result.platforms["macos"])
    asserts.true(env, "dartPluginClass" not in result.platforms["macos"])
    return unittest.end(env)

def _federated_impl_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block(_PATH_PROVIDER_FOUNDATION_PUBSPEC)
    asserts.true(env, result.present)
    asserts.equals(env, "path_provider", result.implements)
    asserts.equals(env, 2, len(result.platforms))
    asserts.equals(env, "PathProviderFoundation", result.platforms["macos"]["dartPluginClass"])
    asserts.equals(env, "PathProviderFoundation", result.platforms["ios"]["dartPluginClass"])

    asserts.true(env, "default_package" not in result.platforms["macos"])
    return unittest.end(env)

def _monolithic_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block(_PACKAGE_INFO_PLUS_PUBSPEC)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, 6, len(result.platforms))

    asserts.equals(env, "dev.fluttercommunity.plus.packageinfo", result.platforms["android"]["package"])
    asserts.equals(env, "PackageInfoPlugin", result.platforms["android"]["pluginClass"])

    asserts.equals(env, "FPPPackageInfoPlusPlugin", result.platforms["ios"]["pluginClass"])

    asserts.equals(env, "PackageInfoPlusLinuxPlugin", result.platforms["linux"]["dartPluginClass"])
    asserts.equals(env, "PackageInfoPlusWindowsPlugin", result.platforms["windows"]["dartPluginClass"])

    asserts.equals(env, "PackageInfoPlusWebPlugin", result.platforms["web"]["pluginClass"])
    asserts.equals(env, "src/package_info_plus_web.dart", result.platforms["web"]["fileName"])
    return unittest.end(env)

def _impl_with_filename_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block(_URL_LAUNCHER_MACOS_PUBSPEC)
    asserts.true(env, result.present)
    asserts.equals(env, "url_launcher", result.implements)
    macos = result.platforms["macos"]
    asserts.equals(env, "UrlLauncherPlugin", macos["pluginClass"])
    asserts.equals(env, "url_launcher_macos.dart", macos["fileName"])
    asserts.equals(env, "UrlLauncherMacOS", macos["dartPluginClass"])
    return unittest.end(env)

def _no_plugin_block_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block(_NO_PLUGIN_PUBSPEC)
    asserts.equals(env, False, result.present)
    asserts.equals(env, 0, len(result.platforms))
    asserts.equals(env, "", result.implements)
    asserts.equals(env, False, result.ffi_plugin)
    return unittest.end(env)

def _non_mapping_plugin_test_impl(ctx):
    """A scalar `flutter.plugin` is no plugin block: not present, not an FFI plugin."""
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block({"flutter": {"plugin": True}})
    asserts.equals(env, False, result.present)
    asserts.equals(env, False, result.ffi_plugin)
    asserts.equals(env, 0, len(result.platforms))
    asserts.equals(env, "", result.implements)
    return unittest.end(env)

def _empty_pubspec_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_plugin_block({})
    asserts.equals(env, False, result.present)
    asserts.equals(env, False, result.ffi_plugin)
    asserts.equals(env, 0, len(result.platforms))
    return unittest.end(env)

# ---------------------------------------------------------------------------
# pubspec_file_roots
# ---------------------------------------------------------------------------

# The `flutter.licenses` key (a name buildifier reads as a rule attribute).
_LICENSES = "licenses"

def _roots(flutter):
    return pubspec_file_roots({"name": "example", "flutter": flutter})

def _font_and_dir_roots_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, struct(dirs = ["assets"], files = [], whole = False), pubspec_file_roots(_CUPERTINO_ICONS_PUBSPEC))
    asserts.equals(env, struct(dirs = ["fonts"], files = [], whole = False), pubspec_file_roots(_FONT_WITH_VARIANTS_PUBSPEC))
    asserts.equals(env, struct(dirs = ["data"], files = [], whole = False), pubspec_file_roots(_LOCALES_PUBSPEC))
    asserts.equals(env, struct(dirs = ["assets"], files = [], whole = False), pubspec_file_roots(_MAP_FORM_ASSETS_PUBSPEC))
    asserts.equals(env, struct(dirs = ["shaders"], files = [], whole = False), pubspec_file_roots(_MATERIAL_AND_SHADERS_PUBSPEC))
    return unittest.end(env)

def _nested_and_top_level_roots_test_impl(ctx):
    env = unittest.begin(ctx)

    # The leading plain directories; a top-level file by its name.
    asserts.equals(env, struct(dirs = ["a/b", "a/b/2.0x", "c"], files = ["NOTICE.txt", "x.png"], whole = False), _roots({
        "assets": ["a/b/x.png", "x.png", "c/", {"path": "a/b/2.0x/y.png"}],
        _LICENSES: ["NOTICE.txt"],
    }))

    # A query, fragment or dot segment ends the directories it names.
    asserts.equals(env, struct(dirs = ["a"], files = [], whole = False), _roots({"assets": [{"path": "a/b?.png"}, "a/./c.png"]}))

    # Deferred components' assets count.
    asserts.equals(env, struct(dirs = ["d"], files = [], whole = False), _roots({
        "deferred-components": [{"name": "c", "assets": ["d/e.png"]}],
    }))
    return unittest.end(env)

def _whole_package_roots_test_impl(ctx):
    env = unittest.begin(ctx)
    whole = struct(dirs = [], files = [], whole = True)
    for entry in ["../secret.txt", "a/../../x", "a/%2E%2E/x", "a/b%20c.png", "a\\b.png", "./a.png", "/abs.png"]:
        asserts.equals(env, whole, _roots({"assets": [entry]}), entry)
    asserts.equals(env, whole, _roots({_LICENSES: ["../LICENSE"]}))

    # A shader at the root includes the root's files.
    asserts.equals(env, whole, _roots({"shaders": ["ripple.frag"]}))
    return unittest.end(env)

def _malformed_section_names_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    # The tool reports a malformed section; nothing is named here.
    none = struct(dirs = [], files = [], whole = False)
    asserts.equals(env, none, pubspec_file_roots({"name": "foo"}))
    asserts.equals(env, none, _roots({"assets": "assets/a.txt", "fonts": [{"family": "F", "fonts": "x"}]}))
    asserts.equals(env, none, pubspec_file_roots({"name": "foo", "flutter": "yes"}))
    return unittest.end(env)

# ---------------------------------------------------------------------------
# parse_flutter_block
# ---------------------------------------------------------------------------

def _parse_flutter_block_test_impl(ctx):
    env = unittest.begin(ctx)
    flutter = parse_flutter_block(_PATH_PROVIDER_PUBSPEC)
    asserts.true(env, "plugin" in flutter)
    asserts.equals(env, {}, parse_flutter_block({}))
    asserts.equals(env, {}, parse_flutter_block({"flutter": None}))
    asserts.equals(env, {}, parse_flutter_block({"flutter": "text"}))
    return unittest.end(env)

_t0_test = unittest.make(_umbrella_default_package_test_impl)
_t1_test = unittest.make(_federated_impl_test_impl)
_t2_test = unittest.make(_monolithic_plugin_test_impl)
_t3_test = unittest.make(_impl_with_filename_test_impl)
_t4_test = unittest.make(_no_plugin_block_test_impl)
_t5_test = unittest.make(_empty_pubspec_test_impl)
_t6_test = unittest.make(_font_and_dir_roots_test_impl)
_t7_test = unittest.make(_nested_and_top_level_roots_test_impl)
_t8_test = unittest.make(_whole_package_roots_test_impl)
_t9_test = unittest.make(_malformed_section_names_nothing_test_impl)
_t12_test = unittest.make(_parse_flutter_block_test_impl)
_t18_test = unittest.make(_non_mapping_plugin_test_impl)

def flutter_pubspec_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t12_test,
        _t18_test,
    )
