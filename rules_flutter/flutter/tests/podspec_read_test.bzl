"""Unit and analysis tests for static CocoaPods .podspec reading and wiring (POD-12)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:ios.bzl", "flutter_apple_plugin_library")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    "weak_sdk_frameworks_xtool_refusal",
)
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "detect_apple_plugin_sources",
)
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "apply_apple_native_deps",
)
load(
    "//flutter/private:podspec_read.bzl",
    "detect_apple_podspecs",
    "podspec_unsupported_field_error",
    "read_plugin_podspec",
    "resolve_podspec_privacy_path",
    "splice_apple_podspec_link_settings",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_WEBRTC_PODSPEC = """\
Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc'
  s.version          = '0.9.24'
  s.summary          = 'Flutter WebRTC plugin to do real-time media'
  s.homepage         = 'https://github.com/flutter-webrtc/flutter-webrtc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CloudWebRtc' => 'danieldafen@live.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.platform         = :ios, '11.0'
  s.libraries        = 'c++', 'libsqlite3'
  s.frameworks       = ['AVFoundation', 'AudioToolbox']
  s.weak_frameworks  = 'MetricKit'
end
"""

_INAPPWEBVIEW_PODSPEC = """\
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_inappwebview_ios.podspec` to validate before publishing.
#
#
Pod::Spec.new do |s|
  s.name             = 'flutter_inappwebview_ios'
  s.version          = '1.1.2'
  s.summary          = 'A Flutter plugin for iOS'
  s.description      = <<-DESC
A Flutter plugin that allows you to add an inline webview and open an in-app browser window.
                       DESC
  s.homepage         = 'https://github.com/pichillilorenzo/flutter_inappwebview'
  s.license          = { :type => 'Apache 2.0', :file => '../LICENSE' }
  s.author           = { 'Lorenzo Pichilli' => 'profile.pichillilorenzo@gmail.com' }
  s.source           = { :http => 'https://example.com/flutter_inappwebview_ios-1.1.2.zip' }
  s.resources = 'Storyboards/**/*.storyboard'
  s.resource_bundles = {
    'flutter_inappwebview_ios_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
  s.libraries = 'swiftCoreGraphics'
end
"""

_VALUE_FORMS_PODSPEC = """\
=begin
Block comment with end and s.vendored_frameworks = 'Ignored.xcframework'
=end
Pod::Spec.new do |spec|
  spec.description = <<~'EOF'
    end
    spec.resources = 'Ignored/**/*.png'
  EOF
  spec.framework = "AVFoundation"
  spec.frameworks += %w[CoreMedia AudioToolbox]
  spec.frameworks = %w(
    CoreVideo
    Metal
  )
  spec.ios.frameworks = [
    'Security', # inline comment
    "Vision",
  ]
  spec.weak_framework = %q[MetricKit]
  spec.weak_frameworks = %W[CoreHaptics LinkPresentation]
  spec.library = %Q[c++]
  spec.libraries = %w{libz sqlite3}
  spec.libraries = 'resolv', 'libxml2'
  spec.weak_frameworks = 'ARKit' if ENV['ARKIT']
  spec.resource = './Direct/PrivacyInfo.xcprivacy'
  spec.resources = []
  spec.resource_bundles = {}
  spec.resource_bundles = {
    'p1' => ['Resources/PrivacyInfo.xcprivacy'],
    "#{spec.module_name}_Privacy" => "Extra/PrivacyInfo.xcprivacy",
    'p2' => %w[Sub/PrivacyInfo.xcprivacy],
  }
end
"""

_SCOPING_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'scoping_test'
  s.frameworks = 'AVFoundation'
  s.test_spec 'Tests' do |test_spec| test_spec.resources = 'Fixtures/*' end
  s.test_spec 'MoreTests' do |ts|
    ts.vendored_frameworks = 'Tests/Mock.framework'
    ts.frameworks = 'XCTest'
  end
  s.ios.app_spec 'App' do |app_spec|
    app_spec.resources = 'App/Resources/**/*.png'
    app_spec.vendored_libraries = 'App/libmock.a'
  end
  s.test_spec('Brace') { |ts| ts.resources = 'Brace/*' }
  s.subspec 'Core' do |ss| ss.frameworks = 'CoreLocation' end
  s.osx.subspec 'MacOnly' do |ms|
    ms.vendored_frameworks = 'Mac.xcframework'
  end
  if ENV['BT']
    s.frameworks = 'CoreBluetooth'
  elsif ENV['LOC']
    s.frameworks = 'CoreMotion'
  else
    s.frameworks = 'CoreTelephony'
  end
end
"""

_PLATFORM_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'platform_test'
  s.frameworks = 'SharedFramework'
  s.ios.frameworks = 'UIKit'
  s.osx.frameworks = 'AppKit'
  s.macos.weak_frameworks = 'MetricKit'
  s.tvos.vendored_frameworks = 'TVOnly.xcframework'
end
"""

def _make_mock_repo_ctx(files, dirs = None):
    """Build a mock repository `ctx` supporting both `readdir` and file-map lookups."""
    dirs_map = dirs if dirs != None else {}

    def _path(rel):
        """Return a mock path node for `rel`."""
        p = str(rel)
        is_dir = p in dirs_map
        base = p.rpartition("/")[2] if "/" in p else p
        if dirs != None:
            return struct(
                exists = (p in files) or is_dir,
                is_dir = is_dir,
                basename = base,
                readdir = lambda: [
                    struct(
                        basename = c.rpartition("/")[2] if "/" in c else c,
                        is_dir = c in dirs_map,
                    )
                    for c in dirs_map.get(p, [])
                ],
            )
        return struct(exists = p in files, basename = base)

    def _read(rel):
        """Read `rel` from `files`."""
        return files[str(rel)]

    return struct(
        attr = struct(
            hub_name = "deps",
            ios_native_deps = None,
            lock_packages = [],
            package_resolved = None,
            package_sha256 = None,
            plugin_native_deps = None,
            podfile_lock = None,
            pubspec_lock = None,
        ),
        path = _path,
        read = _read,
    )

def _webrtc_and_normalization_test_impl(ctx):
    """Verify `flutter_webrtc` podspec shape and `lib` prefix normalization."""
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_WEBRTC_PODSPEC, "ios/flutter_webrtc.podspec", "flutter_webrtc", "ios")
    asserts.equals(env, ["AVFoundation", "AudioToolbox"], res.frameworks)
    asserts.equals(env, ["MetricKit"], res.weak_frameworks)
    asserts.equals(env, ["c++", "sqlite3"], res.libraries)
    asserts.equals(env, [], res.privacy_manifests)

    norm_spec = """\
Pod::Spec.new do |s|
  s.libraries = ['libz', 'z', 'c++', 'sqlite3', 'libsqlite3', 'resolv', 'swiftCoreGraphics', 'lib', 'libz']
end
"""
    norm = read_plugin_podspec(norm_spec, "ios/norm.podspec", "norm", "ios")
    asserts.equals(env, ["z", "c++", "sqlite3", "resolv", "swiftCoreGraphics", "lib"], norm.libraries)
    return unittest.end(env)

_webrtc_and_normalization_test = unittest.make(_webrtc_and_normalization_test_impl)

def _all_value_forms_test_impl(ctx):
    """Verify every accepted string, array, `%w[...]`, `%q[...]`, `+=`, modifier, and hash form."""
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_VALUE_FORMS_PODSPEC, "ios/forms.podspec", "forms", "ios")
    asserts.equals(
        env,
        ["AVFoundation", "CoreMedia", "AudioToolbox", "CoreVideo", "Metal", "Security", "Vision"],
        res.frameworks,
    )
    asserts.equals(env, ["MetricKit", "CoreHaptics", "LinkPresentation", "ARKit"], res.weak_frameworks)
    asserts.equals(env, ["c++", "z", "sqlite3", "resolv", "xml2"], res.libraries)
    asserts.equals(
        env,
        [
            "./Direct/PrivacyInfo.xcprivacy",
            "Resources/PrivacyInfo.xcprivacy",
            "Extra/PrivacyInfo.xcprivacy",
            "Sub/PrivacyInfo.xcprivacy",
        ],
        res.privacy_manifests,
    )
    asserts.equals(
        env,
        "ios/Direct/PrivacyInfo.xcprivacy",
        resolve_podspec_privacy_path("ios", "./Direct/PrivacyInfo.xcprivacy", "forms", "ios/forms.podspec"),
    )
    return unittest.end(env)

_all_value_forms_test = unittest.make(_all_value_forms_test_impl)

def _scoping_and_platforms_test_impl(ctx):
    """Verify single-line and multi-line `test_spec`/`app_spec` skipping, unioning, and platform scopes."""
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_SCOPING_PODSPEC, "ios/scoping_test.podspec", "scoping_test", "ios")
    asserts.equals(
        env,
        ["AVFoundation", "CoreLocation", "CoreBluetooth", "CoreMotion", "CoreTelephony"],
        res.frameworks,
    )

    ios_res = read_plugin_podspec(_PLATFORM_PODSPEC, "ios/platform_test.podspec", "platform_test", "ios")
    asserts.equals(env, ["SharedFramework", "UIKit"], ios_res.frameworks)
    asserts.equals(env, [], ios_res.weak_frameworks)

    macos_res = read_plugin_podspec(_PLATFORM_PODSPEC, "macos/platform_test.podspec", "platform_test", "macos")
    asserts.equals(env, ["SharedFramework", "AppKit"], macos_res.frameworks)
    asserts.equals(env, ["MetricKit"], macos_res.weak_frameworks)
    return unittest.end(env)

_scoping_and_platforms_test = unittest.make(_scoping_and_platforms_test_impl)

def _legacy_privacy_and_darwin_discovery_test_impl(ctx):
    """Verify legacy `ios/Resources/PrivacyInfo.xcprivacy` merging, missing-path skip, and `darwin/` discovery."""
    env = unittest.begin(ctx)
    podspec_text = """\
Pod::Spec.new do |s|
  s.frameworks = %w[AVFoundation]
  s.weak_frameworks = 'MetricKit'
  s.libraries = 'c++'
  s.resource_bundles = {
    'legacy_privacy' => ['Resources/PrivacyInfo.xcprivacy'],
    "#{s.module_name}_Privacy" => 'Stale/PrivacyInfo.xcprivacy'
  }
end
"""
    files = {
        "ios/Classes/LegacyPlugin.swift": "import Flutter\n",
        "ios/legacy_pkg.podspec": podspec_text,
        "ios/Resources/PrivacyInfo.xcprivacy": "<plist/>",
    }
    dirs = {
        "ios": ["ios/Classes", "ios/Resources", "ios/legacy_pkg.podspec"],
        "ios/Classes": ["ios/Classes/LegacyPlugin.swift"],
        "ios/Resources": ["ios/Resources/PrivacyInfo.xcprivacy"],
    }
    mock_ctx = _make_mock_repo_ctx(files, dirs = dirs)
    plugin_block = struct(platforms = {"ios": {"pluginClass": "LegacyPlugin"}})
    detected = detect_apple_plugin_sources(mock_ctx, "legacy_pkg", plugin_block)
    asserts.equals(env, ["ios/Resources/PrivacyInfo.xcprivacy"], detected.ios_manifests)
    asserts.equals(env, ["AVFoundation"], detected.ios_podspec.frameworks)

    # Stub ctx without `.readdir` still discovers `<dir>/<plugin>.podspec` and merges manifests.
    stub_ctx = _make_mock_repo_ctx(files, dirs = None)
    stub_pods = detect_apple_podspecs(stub_ctx, "legacy_pkg", [], ["ios/Classes"], False, False)
    asserts.equals(env, ["ios/Resources/PrivacyInfo.xcprivacy"], stub_pods.ios_manifests)

    # Shared `darwin/` podspec discovery when `ios/` has no `.podspec`.
    darwin_files = {
        "darwin/shared_pkg.podspec": "Pod::Spec.new do |s|\n  s.resources = 'Resources/PrivacyInfo.xcprivacy'\nend\n",
        "darwin/Resources/PrivacyInfo.xcprivacy": "<plist/>",
    }
    darwin_ctx = _make_mock_repo_ctx(darwin_files, dirs = None)
    darwin_pods = detect_apple_podspecs(darwin_ctx, "shared_pkg", [], ["ios/Classes"], False, False)
    asserts.equals(env, ["darwin/Resources/PrivacyInfo.xcprivacy"], darwin_pods.ios_manifests)

    # Rendered spoke BUILD wires sdk_frameworks, weak_sdk_frameworks, and sdk_dylibs; empty omits all three.
    base_targets = apple_plugin_targets("legacy_pkg", ["ios/Classes"], [], "ios")
    wired = apply_apple_native_deps(mock_ctx, "legacy_pkg", detected, base_targets)
    asserts.true(env, 'sdk_frameworks = ["AVFoundation"],' in wired)
    asserts.true(env, 'weak_sdk_frameworks = ["MetricKit"],' in wired)
    asserts.true(env, 'sdk_dylibs = ["c++"],' in wired)

    empty_apple = struct(ios_podspec = None, macos_podspec = None)
    unchanged = splice_apple_podspec_link_settings(base_targets, "legacy_pkg", empty_apple)
    asserts.equals(env, base_targets, unchanged)
    return unittest.end(env)

_legacy_privacy_and_darwin_discovery_test = unittest.make(_legacy_privacy_and_darwin_discovery_test_impl)

def _error_message_wording_test_impl(ctx):
    """Verify exact Message 5 wording and `xtool` `weak_sdk_frameworks` refusal helper."""
    env = unittest.begin(ctx)
    msg = podspec_unsupported_field_error(
        "flutter_inappwebview_ios",
        "ios/flutter_inappwebview_ios.podspec",
        17,
        "resources",
        "'Storyboards/**/*.storyboard'",
    )
    expected = (
        'Flutter plugin "flutter_inappwebview_ios": ios/flutter_inappwebview_ios.podspec:17 ' +
        "declares resources ('Storyboards/**/*.storyboard'), which rules_flutter does not build for plugins. " +
        "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
    )
    asserts.equals(env, expected, msg)

    xtool_msg = weak_sdk_frameworks_xtool_refusal("my_plugin")
    asserts.true(env, "my_plugin" in xtool_msg and "weak_sdk_frameworks" in xtool_msg and "xtool" in xtool_msg)
    return unittest.end(env)

_error_message_wording_test = unittest.make(_error_message_wording_test_impl)

def _plugin_macro_surface_test_impl(ctx):
    """Verify pure-Swift and ObjC SDK `linkopts` on `flutter_apple_plugin_library`."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["-ObjC", "-framework", "AVFoundation", "-weak_framework", "MetricKit", "-lc++"],
        ctx.attr.swift_linkopts,
    )
    asserts.equals(
        env,
        ["-framework", "AVFoundation", "-weak_framework", "MetricKit", "-lsqlite3"],
        ctx.attr.objc_linkopts,
    )
    return unittest.end(env)

_plugin_macro_surface_test = unittest.make(
    _plugin_macro_surface_test_impl,
    attrs = {
        "objc_linkopts": attr.string_list(mandatory = True),
        "swift_linkopts": attr.string_list(mandatory = True),
    },
)

def _podspec_failure_probe_impl(ctx):
    """Invoke podspec parsing, multiple-podspec scan, or spoke dep wiring for `analysistest` failure checks."""
    mode = ctx.attr.mode
    if mode == "parse":
        read_plugin_podspec(ctx.attr.text, ctx.attr.path, ctx.attr.plugin, ctx.attr.platform)
    elif mode == "multi":
        mock_ctx = _make_mock_repo_ctx(
            {"ios/zeta.podspec": "", "ios/alpha.podspec": ""},
            dirs = {"ios": ["ios/zeta.podspec", "ios/alpha.podspec"]},
        )
        detect_apple_podspecs(mock_ctx, ctx.attr.plugin, [], ["ios/Classes"], False, False)
    elif mode == "before_deps":
        mock_ctx = _make_mock_repo_ctx({"ios/flutter_inappwebview_ios.podspec": _INAPPWEBVIEW_PODSPEC})
        mock_with_bad_pod = struct(
            attr = struct(
                hub_name = "deps",
                ios_native_deps = "//:missing.json",
                lock_packages = [],
                package_resolved = None,
                package_sha256 = None,
                plugin_native_deps = '{"flutter_inappwebview_ios": ["//override:target"]}',
                podfile_lock = "//:Podfile.lock",
                pubspec_lock = None,
            ),
            path = mock_ctx.path,
            read = mock_ctx.read,
        )
        build_txt = apple_plugin_targets("flutter_inappwebview_ios", ["ios/Classes"], [], "ios")
        apply_apple_native_deps(
            mock_with_bad_pod,
            "flutter_inappwebview_ios",
            struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
            build_txt,
        )
    return [DefaultInfo(files = depset())]

_podspec_failure_probe = rule(
    implementation = _podspec_failure_probe_impl,
    attrs = {
        "mode": attr.string(default = "parse"),
        "path": attr.string(default = "ios/probe.podspec"),
        "platform": attr.string(default = "ios"),
        "plugin": attr.string(mandatory = True),
        "text": attr.string(default = ""),
    },
)

def _expect_failure_test_impl(ctx):
    """Assert that target analysis failed with every expected substring."""
    env = analysistest.begin(ctx)
    for exp in ctx.attr.expected_messages:
        asserts.expect_failure(env, exp)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_messages": attr.string_list(mandatory = True),
    },
)

podspec_failure_probe = _podspec_failure_probe
podspec_expect_failure_test = _expect_failure_test

def _pure_swift_ccinfo_test_impl(ctx):
    """Assert that a pure-Swift `flutter_apple_plugin_library` propagates SDK link flags in `CcInfo`."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    flags = [
        flag
        for li in tut[CcInfo].linking_context.linker_inputs.to_list()
        for flag in li.user_link_flags
    ]
    for expected_flag in ("-framework", "AVFoundation", "-weak_framework", "MetricKit", "-lc++"):
        asserts.true(
            env,
            expected_flag in flags,
            "Expected %s in CcInfo user_link_flags, got %s" % (expected_flag, flags),
        )
    return analysistest.end(env)

_pure_swift_ccinfo_test = analysistest.make(
    _pure_swift_ccinfo_test_impl,
    config_settings = {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    },
)

def _fail_case(suffix, plugin, text, expected, mode = "parse", path = ""):
    """Build one negative podspec test case struct."""
    spec_path = path if path else ("ios/%s.podspec" % plugin)
    return struct(suffix = suffix, mode = mode, plugin = plugin, path = spec_path, text = text, expected = expected)

_MSG5_TAIL = (
    ", which rules_flutter does not build for plugins. " +
    "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
)

_FAILURE_CASES = [
    _fail_case(
        "inappwebview",
        "flutter_inappwebview_ios",
        _INAPPWEBVIEW_PODSPEC,
        [
            'Flutter plugin "flutter_inappwebview_ios": ios/flutter_inappwebview_ios.podspec:17 ' +
            "declares resources ('Storyboards/**/*.storyboard')" + _MSG5_TAIL,
        ],
    ),
    _fail_case(
        "vendored_fw",
        "vendored_fw",
        "Pod::Spec.new do |s|\n  s.name = 'vendored_fw'\n  s.vendored_frameworks = 'Frameworks/Foo.xcframework'\nend\n",
        [
            'Flutter plugin "vendored_fw": ios/vendored_fw.podspec:3 ' +
            "declares vendored_frameworks ('Frameworks/Foo.xcframework')" + _MSG5_TAIL,
        ],
    ),
    _fail_case(
        "vendored_lib",
        "vendored_lib",
        "Pod::Spec.new do |s|\n  s.name = 'vendored_lib'\n  s.vendored_libraries = 'Libraries/libfoo.a'\nend\n",
        [
            'Flutter plugin "vendored_lib": ios/vendored_lib.podspec:3 ' +
            "declares vendored_libraries ('Libraries/libfoo.a')" + _MSG5_TAIL,
        ],
    ),
    _fail_case(
        "bad_bundles",
        "bad_bundles",
        "Pod::Spec.new do |s|\n  s.name = 'bad_bundles'\n  s.resource_bundles = {'Assets' => ['Assets/*.png']}\nend\n",
        [
            'Flutter plugin "bad_bundles": ios/bad_bundles.podspec:3 ' +
            "declares resource_bundles ({'Assets' => ['Assets/*.png']})" + _MSG5_TAIL,
        ],
    ),
    _fail_case(
        "empty_bundle_list",
        "empty_b",
        "Pod::Spec.new do |s|\n  s.resource_bundles = {'Empty' => []}\nend\n",
        ['Flutter plugin "empty_b": ios/empty_b.podspec:2 declares resource_bundles', "flutter.plugin_overlays"],
    ),
    _fail_case(
        "non_literal_interp",
        "interp_pkg",
        'Pod::Spec.new do |s|\n  s.frameworks = "#{dynamic_fw}"\nend\n',
        ['Flutter plugin "interp_pkg": ios/interp_pkg.podspec:2 declares frameworks ("#{dynamic_fw}")'],
    ),
    _fail_case(
        "pct_w_interp",
        "pct_pkg",
        "Pod::Spec.new do |s|\n  s.weak_frameworks = %W[#{dynamic_fw}]\nend\n",
        ['Flutter plugin "pct_pkg": ios/pct_pkg.podspec:2 declares weak_frameworks (%W[#{dynamic_fw}])'],
    ),
    _fail_case(
        "non_literal_var",
        "var_pkg",
        "Pod::Spec.new do |s|\n  s.libraries = extra_libs\nend\n",
        ['Flutter plugin "var_pkg": ios/var_pkg.podspec:2 declares libraries (extra_libs)'],
    ),
    _fail_case(
        "traversal_privacy",
        "trav_pkg",
        "Pod::Spec.new do |s|\n  s.resources = '../PrivacyInfo.xcprivacy'\nend\n",
        ['Flutter plugin "trav_pkg": ios/trav_pkg.podspec:2 declares resources (\'../PrivacyInfo.xcprivacy\')'],
    ),
    _fail_case(
        "abs_privacy",
        "abs_pkg",
        "Pod::Spec.new do |s|\n  s.resource_bundles = {'p' => ['/etc/PrivacyInfo.xcprivacy']}\nend\n",
        ['Flutter plugin "abs_pkg": ios/abs_pkg.podspec:2 declares resource_bundles', "/etc/PrivacyInfo.xcprivacy"],
    ),
    _fail_case(
        "multi_podspec_sorted",
        "multi_pkg",
        "",
        ['Flutter plugin "multi_pkg": multiple podspecs found in ios: alpha.podspec, zeta.podspec'],
        mode = "multi",
    ),
    _fail_case(
        "before_deps_order",
        "flutter_inappwebview_ios",
        "",
        ['Flutter plugin "flutter_inappwebview_ios": ios/flutter_inappwebview_ios.podspec:17 declares resources'],
        mode = "before_deps",
    ),
]

def _declare_failure_probes(name):
    """Declare negative podspec parsing, discovery, and ordering `analysistest` targets."""
    test_names = []
    for case in _FAILURE_CASES:
        probe_name = "%s_%s_probe" % (name, case.suffix)
        test_name = "%s_%s_failure_test" % (name, case.suffix)
        _podspec_failure_probe(
            name = probe_name,
            mode = case.mode,
            path = case.path,
            plugin = case.plugin,
            text = case.text,
            tags = ["manual"],
        )
        _expect_failure_test(
            name = test_name,
            target_under_test = ":" + probe_name,
            expected_messages = case.expected,
        )
        test_names.append(":" + test_name)
    return test_names

def _declare_plugin_library_tests(name):
    """Declare `flutter_apple_plugin_library` pure-Swift, ObjC, and `xtool` tests."""
    write_file(
        name = name + "_swift_src",
        out = name + "_PureSwift.swift",
        content = ["import Flutter", "public class PureSwiftPlugin {}"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_objc_src",
        out = name + "_ObjcPlugin.m",
        content = ["int podspec_objc_symbol(void) { return 0; }"],
        tags = ["manual"],
    )
    swift_plugin = name + "_pure_swift_plugin"
    flutter_apple_plugin_library(
        name = swift_plugin,
        srcs = [name + "_PureSwift.swift"],
        module_name = "pure_swift_plugin",
        platform = "ios",
        linkopts = ["-ObjC"],
        sdk_frameworks = ["AVFoundation"],
        weak_sdk_frameworks = ["MetricKit"],
        sdk_dylibs = ["c++"],
        tags = ["manual"],
    )
    objc_plugin = name + "_objc_plugin"
    flutter_apple_plugin_library(
        name = objc_plugin,
        srcs = [name + "_ObjcPlugin.m"],
        module_name = "objc_plugin",
        platform = "ios",
        sdk_frameworks = ["AVFoundation"],
        weak_sdk_frameworks = ["MetricKit"],
        sdk_dylibs = ["sqlite3"],
        tags = ["manual"],
    )
    xtool_weak_plugin = name + "_xtool_weak_plugin"
    flutter_apple_plugin_library(
        name = xtool_weak_plugin,
        srcs = [name + "_PureSwift.swift"],
        module_name = "xtool_weak_plugin",
        platform = "ios",
        backend = "xtool",
        weak_sdk_frameworks = ["MetricKit"],
        target_compatible_with = [],
        tags = ["manual"],
    )
    after = native.existing_rules()
    swift_target = after[swift_plugin]
    objc_inner = after["_" + objc_plugin + "__objc"]
    _plugin_macro_surface_test(
        name = name + "_plugin_macro_surface_test",
        swift_linkopts = [str(x) for x in swift_target.get("linkopts", [])],
        objc_linkopts = [str(x) for x in objc_inner.get("linkopts", [])],
    )
    _pure_swift_ccinfo_test(
        name = name + "_pure_swift_ccinfo_test",
        target_under_test = ":" + swift_plugin,
    )
    _expect_failure_test(
        name = name + "_xtool_weak_refusal_analysis_test",
        target_under_test = ":" + xtool_weak_plugin,
        expected_messages = [xtool_weak_plugin, "weak_sdk_frameworks", "xtool"],
    )
    return [
        ":" + name + "_plugin_macro_surface_test",
        ":" + name + "_pure_swift_ccinfo_test",
        ":" + name + "_xtool_weak_refusal_analysis_test",
    ]

def podspec_read_test_suite(name):
    """Defines CocoaPods podspec reader unit and analysis tests.

    Args:
        name: Name prefix for the declared test targets.
    """
    small_unittest_suite(
        name + "_unit",
        _webrtc_and_normalization_test,
        _all_value_forms_test,
        _scoping_and_platforms_test,
        _legacy_privacy_and_darwin_discovery_test,
        _error_message_wording_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"] + _declare_plugin_library_tests(name) + _declare_failure_probes(name),
    )
