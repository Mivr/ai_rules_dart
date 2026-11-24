"""Unit tests for the CocoaPods Podfile.lock reader.

Each lock is the mapping `yaml_to_json` decodes the file to; YAML syntax
(tabs, flow collections, anchors, quoting) is the converter's business and is
covered by rules_dart's `yaml2json_test`.
"""

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

_SYNTHETIC_LOCK = {
    "PODS": [
        {"firebase_auth (5.1.0)": ["Firebase/Auth (= 12.19.3)", "Flutter"]},
        {"Firebase/Auth (12.19.3)": ["Firebase/CoreOnly"]},
        {"Firebase/CoreOnly (12.19.3)": ["FirebaseCore (= 12.19.3)"]},
        {"FirebaseCore (12.19.3)": None},
        "Flutter (1.0.0)",
        {
            "google_maps_flutter_ios (0.0.1)": ["Flutter", "GoogleMaps (= 10.15.0)"],
        },
        {"GoogleMaps (10.15.0)": None},
        {"google_sign_in_ios (0.0.1)": ["Flutter", "GoogleSignIn (= 9.0.0)"]},
        {"GoogleSignIn (9.0.0)": None},
        {"google_mlkit_commons (0.0.1)": ["Flutter", "MLKitVision (= 10.0.0)"]},
        {"MLKitVision (10.0.0)": None},
    ],
    "DEPENDENCIES": [
        "firebase_auth (from `.symlinks/plugins/firebase_auth/ios`)",
        "google_maps_flutter_ios (from `.symlinks/plugins/google_maps_flutter_ios/darwin`)",
        "google_sign_in_ios (from `.symlinks/plugins/google_sign_in_ios/macos`)",
        "google_mlkit_commons (from `.symlinks/plugins/google_mlkit_commons/ios`)",
    ],
    "EXTERNAL SOURCES": {
        "custom_git": {":git": "https://github.com/custom/git.git"},
        "firebase_auth": {":path": ".symlinks/plugins/firebase_auth/ios"},
        "google_maps_flutter_ios": {":path": ".symlinks/plugins/google_maps_flutter_ios/darwin"},
        "google_mlkit_commons": {":path": ".symlinks/plugins/google_mlkit_commons/ios"},
        "google_sign_in_ios": {":path": ".symlinks/plugins/google_sign_in_ios/macos"},
        "local_non_plugin": {":path": "../local/path"},
    },
    "CHECKOUT OPTIONS": {
        "custom_git": {":commit": "abcdef", ":git": "https://github.com/custom/git.git"},
        "custom_http": {":http": "https://example.com/archive.tar.gz"},
    },
    "SPEC REPOS": {
        "trunk": [
            "Firebase",
            "FirebaseCore",
            "GoogleMaps",
            "GoogleSignIn",
            "MLKitVision",
        ],
    },
    "SPEC CHECKSUMS": {
        "Firebase": "1111111111111111111111111111111111111111",
        "FirebaseCore": "2222222222222222222222222222222222222222",
        "GoogleMaps": "3333333333333333333333333333333333333333",
        "GoogleSignIn": "4444444444444444444444444444444444444444",
        "MLKitVision": "5555555555555555555555555555555555555555",
    },
    "PODFILE CHECKSUM": "9999999999999999999999999999999999999999",
    "COCOAPODS": "1.14.3",
}

def _synthetic_lock_parses_test_impl(ctx):
    """The synthetic lock reads with versions, positions and dependencies in order."""
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
            index = 0,
        ),
        res.pods.get("firebase_auth"),
    )
    asserts.equals(
        env,
        struct(
            version = "12.19.3",
            deps = [struct(name = "FirebaseCore", requirement = "= 12.19.3")],
            index = 2,
        ),
        res.pods.get("Firebase/CoreOnly"),
    )
    asserts.equals(env, struct(version = "12.19.3", deps = [], index = 3), res.pods.get("FirebaseCore"))
    asserts.equals(env, struct(version = "1.0.0", deps = [], index = 4), res.pods.get("Flutter"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "GoogleMaps", requirement = "= 10.15.0"),
            ],
            index = 5,
        ),
        res.pods.get("google_maps_flutter_ios"),
    )
    asserts.equals(env, struct(version = "10.15.0", deps = [], index = 6), res.pods.get("GoogleMaps"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "GoogleSignIn", requirement = "= 9.0.0"),
            ],
            index = 7,
        ),
        res.pods.get("google_sign_in_ios"),
    )
    asserts.equals(env, struct(version = "9.0.0", deps = [], index = 8), res.pods.get("GoogleSignIn"))
    asserts.equals(
        env,
        struct(
            version = "0.0.1",
            deps = [
                struct(name = "Flutter", requirement = ""),
                struct(name = "MLKitVision", requirement = "= 10.0.0"),
            ],
            index = 9,
        ),
        res.pods.get("google_mlkit_commons"),
    )
    asserts.equals(env, struct(version = "10.0.0", deps = [], index = 10), res.pods.get("MLKitVision"))
    return unittest.end(env)

def _subspec_and_requirement_test_impl(ctx):
    """A Name/Subspec entry and a requirement with spaces and commas read whole."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.true(env, "Firebase/Auth" in res.pods)
    asserts.equals(env, "12.19.3", res.pods["Firebase/Auth"].version)
    asserts.equals(env, 1, res.pods["Firebase/Auth"].index)

    lock = {
        "PODS": [
            {"Firebase/Auth (12.19.3)": ["Firebase/CoreOnly", "AppAuth (~> 1.7, >= 1.7.4)"]},
            "!ProtoCompiler (3.25.1)",
        ],
    }
    res = read_podfile_lock(lock, _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(
        env,
        [
            struct(name = "Firebase/CoreOnly", requirement = ""),
            struct(name = "AppAuth", requirement = "~> 1.7, >= 1.7.4"),
        ],
        res.pods["Firebase/Auth"].deps,
    )
    asserts.equals(env, struct(version = "3.25.1", deps = [], index = 1), res.pods.get("!ProtoCompiler"))
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

    extra_paths = {
        "EXTERNAL SOURCES": {
            "CustomPodName": {":path": ".symlinks/plugins/my_pub_pkg/ios"},
            "android_pod": {":path": ".symlinks/plugins/my_pub_pkg/android"},
            "nested_pod": {":path": ".symlinks/plugins/my_pub_pkg/ios/sub"},
            "dotdot_pod": {":path": ".symlinks/plugins/../ios"},
            "list_pod": {":path": ["a", "b"]},
        },
    }
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

    precedence_lock = {
        "CHECKOUT OPTIONS": {
            "first_in_checkout": {":svn": "https://svn.example.com/repo"},
            "hg_pod": {":hg": "https://hg.example.com/repo"},
        },
        "EXTERNAL SOURCES": {
            "first_in_checkout": {":git": "https://github.com/example/repo.git"},
            "podspec_only": {":podspec": "https://example.com/Foo.podspec"},
            "quoted_sym": {":git": "https://github.com/foo.git"},
        },
    }
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

    url_repo_lock = {
        "SPEC REPOS": {"https://github.com/CocoaPods/Specs.git": ["CustomPod", "!ProtoCompiler"]},
        "SPEC CHECKSUMS": {"CustomPod": "AbCdEf0123456789", "!ProtoCompiler": "0011223344556677"},
    }
    url_res = read_podfile_lock(url_repo_lock, _LOCK_LABEL)
    asserts.true(env, url_res.ok)
    asserts.equals(env, "https://github.com/CocoaPods/Specs.git", url_res.spec_repos.get("CustomPod"))
    asserts.equals(env, "https://github.com/CocoaPods/Specs.git", url_res.spec_repos.get("!ProtoCompiler"))
    asserts.equals(env, "AbCdEf0123456789", url_res.checksums.get("CustomPod"))
    asserts.equals(env, "0011223344556677", url_res.checksums.get("!ProtoCompiler"))
    return unittest.end(env)

def _refusals_top_level_test_impl(ctx):
    """An unknown top-level key or a PODS value that is not a list is refused."""
    env = unittest.begin(ctx)
    for lock in [
        {"UNKNOWN_KEY": "foo"},
        {"UNKNOWN_KEY": ["a", "b"]},
        {"PODS": [], "UNKNOWN_KEY": None},
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock top level): "UNKNOWN_KEY" is not a Podfile.lock top-level key rules_flutter reads.' % _LOCK_LABEL,
            res.error,
        )

    res = read_podfile_lock({"PODS": {"foo (1.0)": None}}, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        '%s (Podfile.lock PODS): PODS is not a list of "<name> (<version>)" entries.' % _LOCK_LABEL,
        res.error,
    )
    return unittest.end(env)

def _refusals_pods_entries_test_impl(ctx):
    """Refusals for malformed PODS entries and duplicates name the entry."""
    env = unittest.begin(ctx)

    for position, bad_text, lock in [
        (1, "bad_entry", {"PODS": ["bad_entry"]}),
        (1, "bad name (1.0)", {"PODS": [{"bad name (1.0)": None}]}),
        (1, "foo (= 1.0)", {"PODS": [{"foo (= 1.0)": None}]}),
        (1, "foo (1.0):", {"PODS": ["foo (1.0):"]}),
        (1, "Flutter (1.0.0) - SomeDep", {"PODS": ["Flutter (1.0.0) - SomeDep"]}),
        (1, "foo", {"PODS": ["foo"]}),
        (2, '["a","b"]', {"PODS": ["ok (1.0)", ["a", "b"]]}),
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock PODS entry %d): "%s" is not a "<name> (<version>):" PODS entry.' % (
                _LOCK_LABEL,
                position,
                bad_text,
            ),
            res.error,
        )

    for dup_lock in [
        {"PODS": [{"foo (1.0)": None}, {"foo (2.0)": None}]},
        {"PODS": ["foo (1.0)", {"foo (1.0)": None}]},
    ]:
        res = read_podfile_lock(dup_lock, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(env, _LOCK_LABEL + ' (Podfile.lock PODS entry 2): PODS lists "foo" twice.', res.error)

    res = read_podfile_lock({"PODS": [{"foo (1.0)": "bar"}]}, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock PODS entry 1): "foo" lists its dependencies as something other than a list.',
        res.error,
    )
    return unittest.end(env)

def _refusals_pods_deps_test_impl(ctx):
    """Refusals for malformed PODS dependencies name the entry and the dependency."""
    env = unittest.begin(ctx)

    for bad_text in [
        "bar (bad req",
        "Firebase/Auth = 12.19.3",
        "Flutter 1.0.0",
        "bar ()",
    ]:
        res = read_podfile_lock({"PODS": [{"foo (1.0)": [bad_text]}]}, _LOCK_LABEL)
        asserts.false(env, res.ok)
        asserts.equals(
            env,
            '%s (Podfile.lock PODS entry 1): "%s" is not a "<name> (<requirement>)" PODS dependency.' % (
                _LOCK_LABEL,
                bad_text,
            ),
            res.error,
        )

    return unittest.end(env)

def _empty_and_ignored_sections_test_impl(ctx):
    """An empty lock or one with only ignored keys reads with empty maps."""
    env = unittest.begin(ctx)
    for content in [
        {},
        {"PODS": []},
        {"PODS": None},
        {"DEPENDENCIES": ["Flutter"], "PODFILE CHECKSUM": "abc", "COCOAPODS": "1.14.3"},
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
    """A dependency-free entry reads with an empty deps list, with or without a colon."""
    env = unittest.begin(ctx)
    for lock in [
        {"PODS": [{"pod_bigint_plugin (0.0.1)": None}]},
        {"PODS": ["pod_bigint_plugin (0.0.1)"]},
        {"PODS": [{"pod_bigint_plugin (0.0.1)": None}], "COCOAPODS": "1.14.3"},
    ]:
        res = read_podfile_lock(lock, _LOCK_LABEL)
        asserts.true(env, res.ok)
        asserts.equals(env, "", res.error)
        asserts.equals(
            env,
            struct(version = "0.0.1", deps = [], index = 0),
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
_subspec_and_requirement_test = unittest.make(_subspec_and_requirement_test_impl)
_plugin_pods_test = unittest.make(_plugin_pods_test_impl)
_checkout_options_test = unittest.make(_checkout_options_test_impl)
_spec_repos_and_checksums_test = unittest.make(_spec_repos_and_checksums_test_impl)
_refusals_top_level_test = unittest.make(_refusals_top_level_test_impl)
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
        _subspec_and_requirement_test,
        _plugin_pods_test,
        _checkout_options_test,
        _spec_repos_and_checksums_test,
        _refusals_top_level_test,
        _refusals_pods_entries_test,
        _refusals_pods_deps_test,
        _empty_and_ignored_sections_test,
        _dependency_free_entry_test,
        _pub_spoke_podfile_lock_attrs_test,
    )
