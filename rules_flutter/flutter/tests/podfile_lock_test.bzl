"""Unit tests for the CocoaPods Podfile.lock parser."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load(
    "//flutter/private:swiftpm_resolved.bzl",
    "pub_spoke_podfile_lock_attr",
    "pub_spoke_swiftpm_attrs",
    "pub_spoke_swiftpm_rule_attrs",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_LOCK_LABEL = "//app/ios:Podfile.lock"

_SYNTHETIC_LOCK = """PODS:
  - firebase_auth (5.1.0):
    - Firebase/Auth (= 12.19.3)
    - Flutter
  - "Firebase/Auth (12.19.3)":
    - Firebase/CoreOnly
  - Firebase/CoreOnly (12.19.3):
    - FirebaseCore (= 12.19.3)
  - FirebaseCore (12.19.3):
  - Flutter (1.0.0)
  - google_maps_flutter_ios (0.0.1):
    - Flutter
    - GoogleMaps (= 10.15.0)
  - GoogleMaps (10.15.0):
  - google_sign_in_ios (0.0.1):
    - Flutter
    - GoogleSignIn (= 9.0.0)
  - GoogleSignIn (9.0.0):
  - google_mlkit_commons (0.0.1):
    - Flutter
    - MLKitVision (= 10.0.0)
  - MLKitVision (10.0.0):

DEPENDENCIES:
  - firebase_auth (from `.symlinks/plugins/firebase_auth/ios`)
  - google_maps_flutter_ios (from `.symlinks/plugins/google_maps_flutter_ios/darwin`)
  - google_sign_in_ios (from `.symlinks/plugins/google_sign_in_ios/macos`)
  - google_mlkit_commons (from `.symlinks/plugins/google_mlkit_commons/ios`)

EXTERNAL SOURCES:
  custom_git:
    :git: "https://github.com/custom/git.git"
  firebase_auth:
    :path: ".symlinks/plugins/firebase_auth/ios"
  google_maps_flutter_ios:
    :path: ".symlinks/plugins/google_maps_flutter_ios/darwin"
  google_mlkit_commons:
    :path: ".symlinks/plugins/google_mlkit_commons/ios"
  google_sign_in_ios:
    :path: ".symlinks/plugins/google_sign_in_ios/macos"
  local_non_plugin:
    :path: "../local/path"

CHECKOUT OPTIONS:
  custom_git:
    :commit: "abcdef"
    :git: "https://github.com/custom/git.git"
  custom_http:
    :http: "https://example.com/archive.tar.gz"

SPEC REPOS:
  trunk:
    - Firebase
    - FirebaseCore
    - GoogleMaps
    - GoogleSignIn
    - MLKitVision

SPEC CHECKSUMS:
  Firebase: "1111111111111111111111111111111111111111"
  FirebaseCore: "2222222222222222222222222222222222222222"
  GoogleMaps: "3333333333333333333333333333333333333333"
  GoogleSignIn: "4444444444444444444444444444444444444444"
  MLKitVision: "5555555555555555555555555555555555555555"

PODFILE CHECKSUM: "9999999999999999999999999999999999999999"

COCOAPODS: 1.14.3
"""

def _synthetic_lock_parses_test_impl(ctx):
    """The synthetic lock parses with versions, lines and dependencies in order."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(env, "", res.error)
    asserts.equals(env, 11, len(res.pods))

    asserts.equals(
        env,
        struct(
            version = "5.1.0",
            deps = [
                struct(name = "Firebase/Auth", requirement = "= 12.19.3"),
                struct(name = "Flutter", requirement = ""),
            ],
            line = 2,
        ),
        res.pods.get("firebase_auth"),
    )
    asserts.equals(
        env,
        struct(
            version = "12.19.3",
            deps = [struct(name = "FirebaseCore", requirement = "= 12.19.3")],
            line = 7,
        ),
        res.pods.get("Firebase/CoreOnly"),
    )
    asserts.equals(env, struct(version = "12.19.3", deps = [], line = 9), res.pods.get("FirebaseCore"))
    asserts.equals(env, struct(version = "1.0.0", deps = [], line = 10), res.pods.get("Flutter"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "GoogleMaps", requirement = "= 10.15.0"),
            ],
            line = 11,
        ),
        res.pods.get("google_maps_flutter_ios"),
    )
    asserts.equals(env, struct(version = "10.15.0", deps = [], line = 14), res.pods.get("GoogleMaps"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "GoogleSignIn", requirement = "= 9.0.0"),
            ],
            line = 15,
        ),
        res.pods.get("google_sign_in_ios"),
    )
    asserts.equals(env, struct(version = "9.0.0", deps = [], line = 18), res.pods.get("GoogleSignIn"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "MLKitVision", requirement = "= 10.0.0"),
            ],
            line = 19,
        ),
        res.pods.get("google_mlkit_commons"),
    )
    asserts.equals(env, struct(version = "10.0.0", deps = [], line = 22), res.pods.get("MLKitVision"))
    return unittest.end(env)

def _quoted_subspec_test_impl(ctx):
    """A quoted Name/Subspec entry parses to the same name a bare entry does."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.true(env, "Firebase/Auth" in res.pods)
    asserts.equals(env, "12.19.3", res.pods["Firebase/Auth"].version)
    asserts.equals(env, 5, res.pods["Firebase/Auth"].line)

    bare_lock = "PODS:\n  - Firebase/Auth (12.19.3):\n    - Firebase/CoreOnly\n"
    bare_res = read_podfile_lock(bare_lock, _LOCK_LABEL)
    asserts.true(env, bare_res.ok)
    asserts.equals(env, bare_res.pods["Firebase/Auth"].version, res.pods["Firebase/Auth"].version)
    asserts.equals(env, bare_res.pods["Firebase/Auth"].deps, res.pods["Firebase/Auth"].deps)

    single_lock = (
        "PODS:\n" +
        "  - 'Firebase/Auth (12.19.3)':\n" +
        "    - 'Firebase/CoreOnly'\n" +
        '    - "AppAuth (~> 1.7, >= 1.7.4)"\n' +
        '  - "!ProtoCompiler (3.25.1)"\n'
    )
    single_res = read_podfile_lock(single_lock, _LOCK_LABEL)
    asserts.true(env, single_res.ok)
    asserts.equals(
        env,
        [
            struct(name = "Firebase/CoreOnly", requirement = ""),
            struct(name = "AppAuth", requirement = "~> 1.7, >= 1.7.4"),
        ],
        single_res.pods["Firebase/Auth"].deps,
    )
    asserts.equals(env, struct(version = "3.25.1", deps = [], line = 5), single_res.pods.get("!ProtoCompiler"))
    return unittest.end(env)

def _plugin_pods_test_impl(ctx):
    """Plugin paths with /ios, /darwin and /macos land in plugin_pods; others do not."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "firebase_auth", res.plugin_pods.get("firebase_auth"))
    asserts.equals(env, "google_maps_flutter_ios", res.plugin_pods.get("google_maps_flutter_ios"))
    asserts.equals(env, "google_sign_in_ios", res.plugin_pods.get("google_sign_in_ios"))
    asserts.equals(env, "google_mlkit_commons", res.plugin_pods.get("google_mlkit_commons"))
    asserts.false(env, "local_non_plugin" in res.plugin_pods)
    asserts.false(env, "custom_git" in res.plugin_pods)

    extra_paths = (
        "EXTERNAL SOURCES:\n" +
        "  CustomPodName:\n" +
        "    :path: .symlinks/plugins/my_pub_pkg/ios\n" +
        "  android_pod:\n" +
        "    :path: .symlinks/plugins/my_pub_pkg/android\n" +
        "  nested_pod:\n" +
        "    :path: .symlinks/plugins/my_pub_pkg/ios/sub\n" +
        "  dotdot_pod:\n" +
        "    :path: .symlinks/plugins/../ios\n"
    )
    extra_res = read_podfile_lock(extra_paths, _LOCK_LABEL)
    asserts.true(env, extra_res.ok)
    asserts.equals(env, {"CustomPodName": "my_pub_pkg"}, extra_res.plugin_pods)
    return unittest.end(env)

def _checkout_options_test_impl(ctx):
    """CHECKOUT OPTIONS and EXTERNAL SOURCES record external source kinds by first mention."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "git", res.checkout.get("custom_git"))
    asserts.equals(env, "http", res.checkout.get("custom_http"))

    precedence_lock = (
        "CHECKOUT OPTIONS:\n" +
        "  first_in_checkout:\n" +
        "    :svn: https://svn.example.com/repo\n" +
        "  hg_pod:\n" +
        "    :hg: https://hg.example.com/repo\n" +
        "EXTERNAL SOURCES:\n" +
        "  first_in_checkout:\n" +
        "    :git: https://github.com/example/repo.git\n" +
        "  podspec_only:\n" +
        "    :podspec: https://example.com/Foo.podspec\n" +
        "  quoted_sym:\n" +
        '    ":git": "https://github.com/foo.git"\n'
    )
    p_res = read_podfile_lock(precedence_lock, _LOCK_LABEL)
    asserts.true(env, p_res.ok)
    asserts.equals(
        env,
        {
            "first_in_checkout": "svn",
            "hg_pod": "hg",
            "quoted_sym": "git",
        },
        p_res.checkout,
    )
    return unittest.end(env)

def _spec_repos_and_checksums_test_impl(ctx):
    """spec_repos and checksums hold the values written in the lock."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "trunk", res.spec_repos.get("Firebase"))
    asserts.equals(env, "trunk", res.spec_repos.get("FirebaseCore"))
    asserts.equals(env, "trunk", res.spec_repos.get("GoogleMaps"))
    asserts.equals(env, "1111111111111111111111111111111111111111", res.checksums.get("Firebase"))
    asserts.equals(env, "5555555555555555555555555555555555555555", res.checksums.get("MLKitVision"))

    url_repo_lock = (
        "SPEC REPOS:\n" +
        "  https://github.com/CocoaPods/Specs.git:\n" +
        "    - CustomPod\n" +
        '    - "!ProtoCompiler"\n' +
        "SPEC CHECKSUMS:\n" +
        "  CustomPod: AbCdEf0123456789\n" +
        '  "!ProtoCompiler": "0011223344556677"\n'
    )
    url_res = read_podfile_lock(url_repo_lock, _LOCK_LABEL)
    asserts.true(env, url_res.ok)
    asserts.equals(env, "https://github.com/CocoaPods/Specs.git", url_res.spec_repos.get("CustomPod"))
    asserts.equals(env, "https://github.com/CocoaPods/Specs.git", url_res.spec_repos.get("!ProtoCompiler"))
    asserts.equals(env, "AbCdEf0123456789", url_res.checksums.get("CustomPod"))
    asserts.equals(env, "0011223344556677", url_res.checksums.get("!ProtoCompiler"))
    return unittest.end(env)

def _refusals_syntax_test_impl(ctx):
    """Refusals for tabs, unknown keys, flow syntax and anchors name line and detail."""
    env = unittest.begin(ctx)
    tab_detail = "an indentation tab is not part of the Podfile.lock YAML subset rules_flutter reads."
    flow_detail = "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads."

    for line_num, lock in [
        (2, "PODS:\n\t- firebase_auth (5.1.0):\n"),
        (2, "PODS:\n  \t- firebase_auth (5.1.0):\n"),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(env, "%s (Podfile.lock line %d): %s" % (_LOCK_LABEL, line_num, tab_detail), res.error)

    for line_num, key, lock in [
        (1, "UNKNOWN_KEY", "UNKNOWN_KEY:\n  foo\n"),
        (1, "UNKNOWN_KEY", "'UNKNOWN_KEY':\n  foo\n"),
        (1, "UNKNOWN_KEY", "UNKNOWN_KEY: [a, b]\n"),
        (1, "PODS", "PODS\n"),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock line %d): "%s" is not a Podfile.lock top-level key rules_flutter reads.' % (
                _LOCK_LABEL,
                line_num,
                key,
            ),
            res.error,
        )

    for line_num, lock in [
        (1, "PODS: []\n"),
        (1, "&anchor PODS:\n"),
        (2, "PODS:\n  - [a, b]\n"),
        (2, "PODS:\n  - &anchor foo\n"),
        (2, 'PODS:\n  - "Firebase/Auth (12.19.3)": [Flutter]\n'),
        (3, "EXTERNAL SOURCES:\n  foo:\n    :path: [a, b]\n"),
        (3, "CHECKOUT OPTIONS:\n  foo:\n    :commit: *alias\n"),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(env, "%s (Podfile.lock line %d): %s" % (_LOCK_LABEL, line_num, flow_detail), res.error)

    return unittest.end(env)

def _refusals_pods_entries_test_impl(ctx):
    """Refusals for malformed PODS entries, colon-less entries with deps, and duplicates."""
    env = unittest.begin(ctx)

    for line_num, bad_text, lock in [
        (2, "- bad_entry", "PODS:\n  - bad_entry\n"),
        (2, "foo (1.0):", "PODS:\n  foo (1.0):\n"),
        (2, "- foo (1.0):", "PODS:\n- foo (1.0):\n"),
        (2, "- foo (1.0):", "PODS:\n   - foo (1.0):\n"),
        (4, "- baz (2.0):", "PODS:\n  - foo (1.0):\n    - bar\n   - baz (2.0):\n"),
        (2, "- bad name (1.0):", "PODS:\n  - bad name (1.0):\n"),
        (2, "- foo (= 1.0):", "PODS:\n  - foo (= 1.0):\n"),
        (2, '- "foo (1.0):', 'PODS:\n  - "foo (1.0):\n'),
        (2, '- "foo (1.0):"', 'PODS:\n  - "foo (1.0):"\n'),
        (2, "- Flutter (1.0.0)", "PODS:\n  - Flutter (1.0.0)\n    - SomeDep\n"),
        (2, '- "Flutter (1.0.0)"', 'PODS:\n  - "Flutter (1.0.0)"\n    - SomeDep\n'),
        (3, "- bad (1.0)", "PODS:\n  - Flutter (1.0.0)\n- bad (1.0)\n"),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock line %d): "%s" is not a "<name> (<version>):" PODS entry.' % (
                _LOCK_LABEL,
                line_num,
                bad_text,
            ),
            res.error,
        )

    for dup_lock in [
        "PODS:\n  - foo (1.0):\n  - foo (2.0):\n",
        'PODS:\n  - foo (1.0)\n  - "foo (1.0)":\n',
    ]:
        res = read_podfile_lock(dup_lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(env, _LOCK_LABEL + ' (Podfile.lock line 3): PODS lists "foo" twice.', res.error)

    return unittest.end(env)

def _refusals_pods_deps_test_impl(ctx):
    """Refusals for malformed PODS dependency lines."""
    env = unittest.begin(ctx)

    for bad_text, lock in [
        ("- bar (bad req", "PODS:\n  - foo (1.0):\n    - bar (bad req\n"),
        ("- bar", "PODS:\n  - foo (1.0):\n      - bar\n"),
        ("- Firebase/Auth = 12.19.3", "PODS:\n  - foo (1.0):\n    - Firebase/Auth = 12.19.3\n"),
        ("- Flutter 1.0.0", "PODS:\n  - foo (1.0):\n    - Flutter 1.0.0\n"),
        ("- bar ()", "PODS:\n  - foo (1.0):\n    - bar ()\n"),
        ('- "Flutter', 'PODS:\n  - foo (1.0):\n    - "Flutter\n'),
        ("Flutter", "PODS:\n  - foo (1.0):\n    Flutter\n"),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock line 3): "%s" is not a "<name> (<requirement>)" PODS dependency.' % (
                _LOCK_LABEL,
                bad_text,
            ),
            res.error,
        )

    return unittest.end(env)

def _empty_and_ignored_sections_test_impl(ctx):
    """An empty file or a file with only ignored keys parses with empty maps."""
    env = unittest.begin(ctx)
    for content in [
        "",
        "\n  \n",
        "DEPENDENCIES:\n  - Flutter\nPODFILE CHECKSUM: abc\nCOCOAPODS: 1.14.3\n",
    ]:
        res = read_podfile_lock(content, _LOCK_LABEL)
        asserts.true(env, res.ok)
        asserts.equals(env, "", res.error)
        asserts.equals(env, {}, res.pods)
        asserts.equals(env, {}, res.plugin_pods)
        asserts.equals(env, {}, res.spec_repos)
        asserts.equals(env, {}, res.checksums)
        asserts.equals(env, {}, res.checkout)
    return unittest.end(env)

def _dependency_free_entry_test_impl(ctx):
    """A dependency-free entry parses with an empty deps list."""
    env = unittest.begin(ctx)
    for lock in [
        "PODS:\n  - pod_bigint_plugin (0.0.1):\n",
        "PODS:\n  - pod_bigint_plugin (0.0.1)\n",
        "PODS:\n  - pod_bigint_plugin (0.0.1):\nCOCOAPODS: 1.14.3\n",
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.true(env, res.ok)
        asserts.equals(env, "", res.error)
        asserts.equals(
            env,
            struct(version = "0.0.1", deps = [], line = 2),
            res.pods.get("pod_bigint_plugin"),
        )
    return unittest.end(env)

def _pub_spoke_podfile_lock_attrs_test_impl(ctx):
    """Spoke rules declare podfile_lock and pub_spoke_swiftpm_attrs forwards it."""
    env = unittest.begin(ctx)
    rule_attrs = pub_spoke_swiftpm_rule_attrs({})
    asserts.true(env, "podfile_lock" in rule_attrs)
    asserts.equals(env, pub_spoke_podfile_lock_attr, rule_attrs["podfile_lock"])

    attrs_unset = pub_spoke_swiftpm_attrs(struct(swift_package_resolved = None, ios_podfile_lock = None))
    asserts.equals(env, None, attrs_unset.podfile_lock)

    attrs_set = pub_spoke_swiftpm_attrs(struct(
        swift_package_resolved = None,
        ios_podfile_lock = "//app/ios:Podfile.lock",
    ))
    asserts.equals(env, "//app/ios:Podfile.lock", str(attrs_set.podfile_lock))

    attrs_ext = pub_spoke_swiftpm_attrs(
        struct(name = "deps", swift_package_resolved = None, ios_podfile_lock = "//app/ios:Podfile.lock"),
        include_ios_native_deps = True,
    )
    asserts.equals(env, "//app/ios:Podfile.lock", str(attrs_ext.podfile_lock))
    asserts.equals(env, "@deps//:ios_native_deps.json", str(attrs_ext.ios_native_deps))
    return unittest.end(env)

_synthetic_lock_parses_test = unittest.make(_synthetic_lock_parses_test_impl)
_quoted_subspec_test = unittest.make(_quoted_subspec_test_impl)
_plugin_pods_test = unittest.make(_plugin_pods_test_impl)
_checkout_options_test = unittest.make(_checkout_options_test_impl)
_spec_repos_and_checksums_test = unittest.make(_spec_repos_and_checksums_test_impl)
_refusals_syntax_test = unittest.make(_refusals_syntax_test_impl)
_refusals_pods_entries_test = unittest.make(_refusals_pods_entries_test_impl)
_refusals_pods_deps_test = unittest.make(_refusals_pods_deps_test_impl)
_empty_and_ignored_sections_test = unittest.make(_empty_and_ignored_sections_test_impl)
_dependency_free_entry_test = unittest.make(_dependency_free_entry_test_impl)
_pub_spoke_podfile_lock_attrs_test = unittest.make(_pub_spoke_podfile_lock_attrs_test_impl)

def podfile_lock_test_suite(name):
    """Defines the CocoaPods Podfile.lock unit test suite.

    Args:
        name: Name of the test suite.
    """
    small_unittest_suite(
        name,
        _synthetic_lock_parses_test,
        _quoted_subspec_test,
        _plugin_pods_test,
        _checkout_options_test,
        _spec_repos_and_checksums_test,
        _refusals_syntax_test,
        _refusals_pods_entries_test,
        _refusals_pods_deps_test,
        _empty_and_ignored_sections_test,
        _dependency_free_entry_test,
        _pub_spoke_podfile_lock_attrs_test,
    )
