"""Unit tests for plugin define copts and static podspec `GCC_PREPROCESSOR_DEFINITIONS`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_apple_plugin_defines.bzl",
    "plugin_define_copts",
    "plugin_swift_define_copts",
)
load("//flutter/private:flutter_pub_apple.bzl", "apple_plugin_targets")
load("//flutter/private:flutter_pub_apple_local.bzl", "detect_apple_local_targets")
load(
    "//flutter/private:podspec_read.bzl",
    "read_plugin_podspec",
    "splice_apple_podspec_link_settings",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _copts_test_impl(ctx):
    """String-literal, whitespace and `$` defines survive objc_library tokenization."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["-DFOO=1", "-DFLAG", "-DA=B=C"], plugin_define_copts(["FOO=1", "FLAG", "A=B=C"]))
    quoted = "'-DLIBRARY_NAME=\"my-plugin\"'"
    asserts.equals(env, [quoted], plugin_define_copts(['LIBRARY_NAME="my-plugin"']))
    asserts.equals(env, [quoted], plugin_define_copts(['LIBRARY_NAME=\\"my-plugin\\"']))
    asserts.equals(env, [quoted], plugin_define_copts(["LIBRARY_NAME='\\\"my-plugin\\\"'"]))
    asserts.equals(env, [quoted], plugin_define_copts(["LIBRARY_NAME='\"my-plugin\"'"]))
    asserts.equals(env, [quoted], plugin_define_copts(['LIBRARY_NAME="\\"my-plugin\\""']))
    asserts.equals(
        env,
        ["'-DGREETING=\"hello world\"'"],
        plugin_define_copts(['GREETING=\\"hello world\\"']),
    )
    asserts.equals(env, ["'-DGREETING=\"hello world\"'"], plugin_define_copts(['GREETING="hello world"']))
    asserts.equals(env, ["'-DQ=\"a \\\"b\\\"\"'"], plugin_define_copts(['Q="a \\"b\\""']))
    asserts.equals(env, ["'-DCOST=\"$$5\"'"], plugin_define_copts(['COST="$5"']))
    asserts.equals(env, ["'-DTAB=\"a\tb\"'"], plugin_define_copts(['TAB="a\tb"']))
    return unittest.end(env)

_copts_test = unittest.make(_copts_test_impl)

def _dedupe_test_impl(ctx):
    """The last entry per macro name wins for ObjC and Swift copts alike."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["-DB=2", "-DA=3"], plugin_define_copts(["A=1", "B=2", "A=3"]))
    asserts.equals(env, ["-DFOO=0"], plugin_define_copts(["FOO", "FOO=0"]))
    asserts.equals(env, [], plugin_swift_define_copts(["FOO", "FOO=0"]))
    asserts.equals(env, ["-DFOO"], plugin_swift_define_copts(["FOO=0", "FOO"]))
    asserts.equals(env, ["-DFOO"], plugin_define_copts(["FOO=0", "FOO"]))
    return unittest.end(env)

_dedupe_test = unittest.make(_dedupe_test_impl)

def _spec(body, platform = "ios"):
    """Read the defines of a podspec whose `Pod::Spec` body is `body`."""
    text = "Pod::Spec.new do |s|\n%s\nend\n" % body
    return read_plugin_podspec(text, "ios/p.podspec", "p", platform).defines

def _podspec_reader_test_impl(ctx):
    """`pod_target_xcconfig` and `xcconfig` defines are read statically."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], _spec("  s.frameworks = 'UIKit'"))
    asserts.equals(
        env,
        ["FOO=1", 'LIBRARY_NAME=\\"my-plugin\\"', 'MSG="hi there"'],
        _spec(
            "  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => " +
            "'$(inherited) FOO=1 LIBRARY_NAME=\\\"my-plugin\\\" MSG=\"hi there\"', " +
            "'DEFINES_MODULE' => 'YES', 'OTHER_LDFLAGS' => '-ObjC' }",
        ),
    )
    asserts.equals(
        env,
        ["A=1", "B"],
        _spec("  s.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => ['A=1', '-DB', '${inherited}'] }"),
    )
    asserts.equals(
        env,
        ["A=1", "B"],
        _spec("  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => %w[A=1 B] }"),
    )
    asserts.equals(env, [], _spec("  s.user_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'USER=1' }"))
    asserts.equals(env, ["A=2", "B=2"], _spec(
        "  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'A=1' }\n" +
        "  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'A=2 B=2' }",
    ))
    asserts.equals(
        env,
        [],
        _spec("  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS[config=Debug]' => 'D=1' }"),
    )
    return unittest.end(env)

_podspec_reader_test = unittest.make(_podspec_reader_test_impl)

def _podspec_scoping_test_impl(ctx):
    """Platform scope, merge, branches and Ruby interpolation follow the reader's rules."""
    env = unittest.begin(ctx)
    body = (
        "  s.ios.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'IOS_ONLY=1' }\n" +
        "  s.osx.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'MAC_ONLY=1' }\n" +
        "  s.pod_target_xcconfig.merge!({ 'GCC_PREPROCESSOR_DEFINITIONS' => 'MERGED=1' })\n" +
        "  s.test_spec 'T' do |t|\n" +
        "    t.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'TEST_ONLY=1' }\n" +
        "  end\n" +
        "  if ENV['X']\n" +
        "    s.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'THEN=1' }\n" +
        "  else\n" +
        "    s.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'ELSE=1' }\n" +
        "  end"
    )
    asserts.equals(env, ["IOS_ONLY=1", "MERGED=1", "THEN=1", "ELSE=1"], _spec(body, "ios"))
    asserts.equals(env, ["MAC_ONLY=1", "MERGED=1", "THEN=1", "ELSE=1"], _spec(body, "macos"))

    # Ruby interpolation (firebase_core style) is skipped without failing.
    interp = (
        "  library_version = '1'\n" +
        "  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => " +
        "\"$(inherited) LIBRARY_VERSION=\\\\\\\"#{library_version}\\\\\\\"\", 'DEFINES_MODULE' => 'YES' }\n" +
        "  s.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'X' + suffix }"
    )
    asserts.equals(env, [], _spec(interp))
    return unittest.end(env)

_podspec_scoping_test = unittest.make(_podspec_scoping_test_impl)

def _podspec(defines):
    """A minimal podspec struct carrying only `defines`."""
    return struct(frameworks = [], weak_frameworks = [], libraries = [], defines = defines)

def _block(text, name):
    """The attribute text of the target named `name` in rendered BUILD `text`."""
    marker = '    name = "%s",\n' % name
    tail = text.partition(marker)[2]
    return tail.partition("\n)")[0] if tail else ""

def _assert_xtool_frameworks(env):
    """A podspec with defines and frameworks gives `_xtool` the frameworks and no defines."""
    podspec = struct(frameworks = ["UIKit"], weak_frameworks = [], libraries = [], defines = ["A=1"])
    base = apple_plugin_targets("p", ["ios/Classes"], [], "ios")
    spliced = splice_apple_podspec_link_settings(base, "p", struct(ios_podspec = podspec, macos_podspec = None))
    xtool = _block(spliced, "p_apple_ios_xtool")
    asserts.true(env, 'sdk_frameworks = ["UIKit"],' in xtool, xtool)
    asserts.false(env, "plugin_defines" in xtool, xtool)
    apple = _block(spliced, "p_apple_ios")
    asserts.true(env, 'sdk_frameworks = ["UIKit"],' in apple, apple)
    asserts.true(env, 'plugin_defines = ["A=1"],' in apple, apple)

def _assert_xtool_no_refusal_trigger(env):
    """A generated `_xtool` block built from a podspec with defines carries no `plugin_defines`."""
    for platform in ("ios", "macos"):
        podspec = _podspec(["A=1", "B=2"])
        apple = struct(
            ios_podspec = podspec if platform == "ios" else None,
            macos_podspec = podspec if platform == "macos" else None,
        )
        base = apple_plugin_targets("p", [platform + "/Classes"], [], platform)
        text = splice_apple_podspec_link_settings(base, "p", apple)
        xtool = _block(text, "p_apple_%s_xtool" % platform)
        asserts.true(env, xtool != "", text)
        asserts.false(env, "plugin_defines" in xtool, xtool)

def _splice_test_impl(ctx):
    """Podspec defines splice into one `plugin_defines`; user entries override."""
    env = unittest.begin(ctx)
    podspec_apple = struct(ios_podspec = _podspec(["A=1", "B=2"]), macos_podspec = None)
    base = apple_plugin_targets("p", ["ios/Classes"], [], "ios")
    spliced = splice_apple_podspec_link_settings(base, "p", podspec_apple)
    asserts.equals(env, 1, spliced.count('    plugin_defines = ["A=1", "B=2"],'))
    asserts.equals(env, 1, spliced.count("plugin_defines = "))
    asserts.false(env, "plugin_defines" in _block(spliced, "p_apple_ios_xtool"), spliced)
    asserts.true(env, "plugin_defines" in _block(spliced, "p_apple_ios"), spliced)

    none_apple = struct(ios_podspec = _podspec([]), macos_podspec = None)
    asserts.equals(env, base, splice_apple_podspec_link_settings(base, "p", none_apple))

    user = apple_plugin_targets("p", ["ios/Classes"], [], "ios", ['B="x y"', "C"])
    merged = splice_apple_podspec_link_settings(user, "p", podspec_apple)
    asserts.equals(env, 2, merged.count("plugin_defines = "))
    asserts.equals(env, 1, merged.count('    plugin_defines = ["A=1", "B=\\"x y\\"", "C"],'))

    # The user's own value still reaches the xtool target untouched (its refusal applies).
    asserts.true(env, '    plugin_defines = ["B=\\"x y\\"", "C"],' in _block(merged, "p_apple_ios_xtool"), merged)
    _assert_xtool_frameworks(env)
    _assert_xtool_no_refusal_trigger(env)
    return unittest.end(env)

_splice_test = unittest.make(_splice_test_impl)

_LOCAL_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "px", platforms: [.iOS("15.0")],
  products: [.library(name: "px", targets: ["px"])],
  targets: [
    .target(name: "px", dependencies: ["px_objc"], path: "Sources/px"),
    .target(name: "px_objc", path: "Sources/px_objc"),
  ]
)
"""

def _local_ctx(user_defines):
    """A mock spoke context holding a two-target `ios/px/Package.swift` plugin."""
    src = "ios/px/Sources/px_objc/local.m"
    files = {"ios/px/Package.swift": _LOCAL_MANIFEST, src: "// objc\n"}
    dirs = {"ios/px/Sources/px_objc": [src]}

    def _path(rel):
        """A mock path node for `rel`."""
        p = str(rel)
        is_dir = p in dirs
        return struct(
            exists = p in files or is_dir,
            is_dir = is_dir,
            basename = p.rpartition("/")[2],
            readdir = lambda: [struct(basename = c.rpartition("/")[2], is_dir = False) for c in dirs.get(p, [])],
        )

    return struct(attr = struct(plugin_defines = user_defines), path = _path, read = lambda rel: files[str(rel)])

def _local_targets_test_impl(ctx):
    """Reached local sibling targets get podspec defines merged before user defines."""
    env = unittest.begin(ctx)
    apple = struct(
        macos_srcs = [],
        ios_srcs = ["ios/px/Sources/px"],
        ios_podspec = _podspec(["A=1", "B=2"]),
        macos_podspec = None,
    )
    rendered = detect_apple_local_targets(_local_ctx([]), "px", apple).ios
    asserts.true(env, 'plugin_defines = ["A=1", "B=2"],' in rendered.text, rendered.text)
    overridden = detect_apple_local_targets(_local_ctx(["B=9"]), "px", apple).ios
    asserts.true(env, 'plugin_defines = ["A=1", "B=9"],' in overridden.text, overridden.text)
    asserts.equals(env, 1, overridden.text.count("plugin_defines = "))
    plain = detect_apple_local_targets(_local_ctx([]), "px", struct(macos_srcs = [], ios_srcs = apple.ios_srcs)).ios
    asserts.false(env, "plugin_defines" in plain.text)
    return unittest.end(env)

_local_targets_test = unittest.make(_local_targets_test_impl)

def podspec_xcconfig_defines_test_suite(name):
    """Declares the define-copts and podspec xcconfig unit tests.

    Args:
        name: Name of the `test_suite` and prefix of its member targets.
    """
    small_unittest_suite(
        name,
        _copts_test,
        _dedupe_test,
        _podspec_reader_test,
        _podspec_scoping_test,
        _splice_test,
        _local_targets_test,
    )
