"""Unit tests of the lock pin checks and the hub's package resolution.

Each lock is the mapping `yaml_to_json` decodes it to, projected with
`lock_packages` as the pub extension does.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo")
load("//dart/pub:extensions.bzl", "resolve_pub_packages")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_package_sha256_error", "trim_gzip_trailing_nulls")
load("//dart/pub:yaml.bzl", "lock_packages")
load("//dart/pub/private:pin_checks.bzl", "is_valid_sha256", "lock_package_error")
load("//dart/pub/private:pub_repository.bzl", "pub_package_sha256_error")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

_COLLECTION_SHA = "ee67cb0715911d28db6bf4af1026078bd6f0128b07a5f66fb2ed94ef6783c09a"
_PATH_190_SHA = "087ce49c3f0dc39180befefc60fdb4acd8f8620e5682fe2476afd0b3688bb4af"
_PATH_191_SHA = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"
_ALT_SHA = "0000000000000000000000000000000000000000000000000000000000000000"

_SAMPLE_LOCK = {
    "packages": {
        "collection": {
            "dependency": "direct main",
            "description": {
                "name": "collection",
                "sha256": "ee67cb0715911d28db6bf4af1026078bd6f0128b07a5f66fb2ed94ef6783c09a",
                "url": "https://pub.dev",
            },
            "source": "hosted",
            "version": "1.18.0",
        },
        "meta": {
            "dependency": "transitive",
            "description": {
                "name": "meta",
                "sha256": "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9",
                "url": "https://pub.dev",
            },
            "source": "hosted",
            "version": "1.11.0",
        },
        "flutter": {
            "dependency": "direct main",
            "description": "flutter",
            "source": "sdk",
            "version": "0.0.0",
        },
    },
    "sdks": {"dart": ">=3.0.0 <4.0.0"},
}

def _lock_package_missing_sha256_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = lock_packages(_SAMPLE_LOCK)
    asserts.equals(env, None, lock_package_error("collection", parsed["collection"], "//:pubspec.lock"))
    asserts.equals(env, None, lock_package_error("flutter", parsed["flutter"], "//:pubspec.lock"))
    asserts.true(env, is_valid_sha256(_COLLECTION_SHA))
    asserts.true(env, is_valid_sha256("  " + _COLLECTION_SHA + "\n"))
    asserts.false(env, is_valid_sha256(""))
    asserts.false(env, is_valid_sha256("   "))
    asserts.false(env, is_valid_sha256("abc123"))
    asserts.false(env, is_valid_sha256(_COLLECTION_SHA.upper()))
    asserts.false(env, is_valid_sha256(_COLLECTION_SHA[:63]))
    asserts.false(env, is_valid_sha256(_COLLECTION_SHA + "0"))
    asserts.false(env, is_valid_sha256("g" + _COLLECTION_SHA[1:]))

    unpinned_lock = {
        "packages": {
            "collection": {
                "dependency": "direct main",
                "description": {"name": "collection", "url": "https://pub.dev"},
                "source": "hosted",
                "version": "1.18.0",
            },
            "empty_sha": {
                "dependency": "direct main",
                "description": {"name": "empty_sha", "sha256": None, "url": "https://pub.dev"},
                "source": "hosted",
                "version": "2.0.0",
            },
            "whitespace_sha": {
                "dependency": "direct main",
                "description": {
                    "name": "whitespace_sha",
                    "sha256": "   ",
                    "url": "https://pub.dev",
                },
                "source": "hosted",
                "version": "1.9.0",
            },
            "short_sha": {
                "dependency": "direct main",
                "description": {
                    "name": "short_sha",
                    "sha256": "abc123",
                    "url": "https://pub.dev",
                },
                "source": "hosted",
                "version": "1.0.0",
            },
            "upper_sha": {
                "dependency": "direct main",
                "description": {
                    "name": "upper_sha",
                    "sha256": "EE67CB0715911D28DB6BF4AF1026078BD6F0128B07A5F66FB2ED94EF6783C09A",
                    "url": "https://pub.dev",
                },
                "source": "hosted",
                "version": "1.0.0",
            },
        },
    }
    unpinned = lock_packages(unpinned_lock)
    asserts.equals(
        env,
        'pub package "collection" 1.18.0 in //:pubspec.lock has no sha256. Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock.',
        lock_package_error("collection", unpinned["collection"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "empty_sha" 2.0.0 in //:pubspec.lock has no sha256. Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock.',
        lock_package_error("empty_sha", unpinned["empty_sha"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "whitespace_sha" 1.9.0 in //:pubspec.lock has no sha256. Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock.',
        lock_package_error("whitespace_sha", unpinned["whitespace_sha"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "short_sha" 1.0.0 in //:pubspec.lock has invalid sha256 "abc123": expected 64 lowercase hex digits.',
        lock_package_error("short_sha", unpinned["short_sha"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "upper_sha" 1.0.0 in //:pubspec.lock has invalid sha256 "EE67CB0715911D28DB6BF4AF1026078BD6F0128B07A5F66FB2ED94EF6783C09A": expected 64 lowercase hex digits.',
        lock_package_error("upper_sha", unpinned["upper_sha"], "//:pubspec.lock"),
    )
    asserts.equals(env, None, pub_lock_package_sha256_error("collection", "1.18.0", _COLLECTION_SHA))
    asserts.equals(env, None, pub_lock_package_sha256_error("collection", "1.18.0", "  " + _COLLECTION_SHA + "  "))
    asserts.equals(
        env,
        'pub_lock_package "collection" (1.18.0) requires a non-empty sha256.',
        pub_lock_package_sha256_error("collection", "1.18.0", ""),
    )
    asserts.equals(
        env,
        'pub_lock_package "collection" (1.18.0) requires a non-empty sha256.',
        pub_lock_package_sha256_error("collection", "1.18.0", "   "),
    )
    asserts.equals(
        env,
        'pub_lock_package "collection" (1.18.0) has invalid sha256 "abc123": expected 64 lowercase hex digits.',
        pub_lock_package_sha256_error("collection", "1.18.0", "abc123"),
    )
    asserts.equals(env, None, pub_package_sha256_error("collection", "1.18.0", _COLLECTION_SHA))
    asserts.equals(env, None, pub_package_sha256_error("collection", "1.18.0", "  " + _COLLECTION_SHA + "  "))
    asserts.equals(
        env,
        'pub_package "collection" (1.18.0) requires a non-empty sha256.',
        pub_package_sha256_error("collection", "1.18.0", ""),
    )
    asserts.equals(
        env,
        'pub_package "collection" (1.18.0) requires a non-empty sha256.',
        pub_package_sha256_error("collection", "1.18.0", "   "),
    )
    asserts.equals(
        env,
        'pub_package "collection" (1.18.0) has invalid sha256 "abc123": expected 64 lowercase hex digits.',
        pub_package_sha256_error("collection", "1.18.0", "abc123"),
    )
    return unittest.end(env)

def _lock_package_missing_resolved_ref_test_impl(ctx):
    env = unittest.begin(ctx)
    git_lock = {
        "packages": {
            "pinned_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": "0123456789abcdef0123456789abcdef01234567",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.0.0",
            },
            "unpinned_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.0.0",
            },
            "null_ref_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": None,
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.2.3",
            },
            "whitespace_ref_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": "   ",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.2.3",
            },
        },
    }
    parsed = lock_packages(git_lock)
    asserts.equals(env, None, lock_package_error("pinned_git", parsed["pinned_git"], "//:pubspec.lock"))
    asserts.equals(
        env,
        'pub package "unpinned_git" 1.0.0 in //:pubspec.lock has no resolved-ref. Run `dart pub get` and commit the lock.',
        lock_package_error("unpinned_git", parsed["unpinned_git"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "null_ref_git" 1.2.3 in //:pubspec.lock has no resolved-ref. Run `dart pub get` and commit the lock.',
        lock_package_error("null_ref_git", parsed["null_ref_git"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "whitespace_ref_git" 1.2.3 in //:pubspec.lock has no resolved-ref. Run `dart pub get` and commit the lock.',
        lock_package_error("whitespace_ref_git", parsed["whitespace_ref_git"], "//:pubspec.lock"),
    )
    return unittest.end(env)

def _lock_package_invalid_resolved_ref_test_impl(ctx):
    env = unittest.begin(ctx)
    git_lock = {
        "packages": {
            "branch_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": "main",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.0.0",
            },
            "short_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": "deadbeef",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.0.0",
            },
            "tag_git": {
                "dependency": "direct main",
                "description": {
                    "path": ".",
                    "ref": "main",
                    "resolved-ref": "v1.2.3",
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.0.0",
            },
        },
    }
    parsed = lock_packages(git_lock)
    asserts.equals(
        env,
        'pub package "branch_git" 1.0.0 in //:pubspec.lock has invalid resolved-ref "main": expected 40 lowercase hex digits.',
        lock_package_error("branch_git", parsed["branch_git"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "short_git" 1.0.0 in //:pubspec.lock has invalid resolved-ref "deadbeef": expected 40 lowercase hex digits.',
        lock_package_error("short_git", parsed["short_git"], "//:pubspec.lock"),
    )
    asserts.equals(
        env,
        'pub package "tag_git" 1.0.0 in //:pubspec.lock has invalid resolved-ref "v1.2.3": expected 40 lowercase hex digits.',
        lock_package_error("tag_git", parsed["tag_git"], "//:pubspec.lock"),
    )
    return unittest.end(env)

_GIT_REF = "0123456789abcdef0123456789abcdef01234567"

def _path_lock(sha256, version):
    """A decoded lock holding only hosted `path` at `version` with `sha256`."""
    return {
        "packages": {
            "path": {
                "dependency": "direct main",
                "description": {"name": "path", "sha256": sha256, "url": "https://pub.dev"},
                "source": "hosted",
                "version": version,
            },
        },
    }

def _resolve_pub_packages_isolated_git_test_impl(ctx):
    env = unittest.begin(ctx)
    git_lock = lock_packages({
        "packages": {
            "git_dep": {
                "dependency": "direct main",
                "description": {
                    "path": "pkgs/git_dep",
                    "ref": "main",
                    "resolved-ref": _GIT_REF,
                    "url": "https://example.com/repo.git",
                },
                "source": "git",
                "version": "1.2.3",
            },
        },
    })

    # A git entry in an isolated hub stays out of the global registry and is
    # pinned by the hub itself.
    res = resolve_pub_packages(
        [],
        [struct(name = "tool_deps", lock = "//:tool.lock", packages = git_lock, on_version_conflict = "error", isolated = True)],
    )
    asserts.equals(env, None, res.error)
    asserts.equals(env, 0, len(res.resolved_git))
    asserts.true(env, "tool_deps" in res.isolated_git_packages)
    git_pkg = res.isolated_git_packages["tool_deps"]["git_dep"]
    asserts.equals(env, "1.2.3", git_pkg.version)
    asserts.equals(env, "https://example.com/repo.git", git_pkg.url)
    asserts.equals(env, _GIT_REF, git_pkg.resolved_ref)
    asserts.equals(env, "pkgs/git_dep", git_pkg.path)
    asserts.true(env, "git_dep" in res.hub_packages["tool_deps"])

    # The same git package in a shared hub still joins the global registry
    # while the isolated hub keeps its own pin.
    res_both = resolve_pub_packages(
        [],
        [
            struct(name = "tool_deps", lock = "//:tool.lock", packages = git_lock, on_version_conflict = "error", isolated = True),
            struct(name = "app_deps", lock = "//:app.lock", packages = git_lock, on_version_conflict = "error", isolated = False),
        ],
    )
    asserts.equals(env, None, res_both.error)
    asserts.equals(env, _GIT_REF, res_both.resolved_git["git_dep"].resolved_ref)
    asserts.equals(env, _GIT_REF, res_both.isolated_git_packages["tool_deps"]["git_dep"].resolved_ref)
    asserts.true(env, "git_dep" in res_both.hub_packages["app_deps"])

    return unittest.end(env)

def _resolve_pub_packages_conflict_test_impl(ctx):
    env = unittest.begin(ctx)

    ext_lock = lock_packages(_path_lock(_PATH_191_SHA, "1.9.1"))

    # 1. A lower-version lock entry with whitespace-only sha256 fails even when
    # upgraded to ext_pub_deps's higher version.
    ws_lock = lock_packages(_path_lock("   ", "1.9.0"))
    res_ws = resolve_pub_packages(
        [],
        [
            struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade"),
            struct(name = "user_deps", lock = "//:pubspec.lock", packages = ws_lock, on_version_conflict = "upgrade"),
        ],
    )
    asserts.true(env, res_ws.error != None and 'pub package "path" 1.9.0 in //:pubspec.lock has no sha256.' in res_ws.error)

    # 2. A lower-version lock entry with non-64-hex sha256 fails even when
    # upgraded to ext_pub_deps's higher version.
    bad_hex_lock = lock_packages(_path_lock("badhex", "1.9.0"))
    res_bad_hex = resolve_pub_packages(
        [],
        [
            struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade"),
            struct(name = "user_deps", lock = "//:pubspec.lock", packages = bad_hex_lock, on_version_conflict = "upgrade"),
        ],
    )
    asserts.true(env, res_bad_hex.error != None and 'pub package "path" 1.9.0 in //:pubspec.lock has invalid sha256' in res_bad_hex.error)

    # 3. Same version across two locks with different 64-hex sha256 fails.
    conflict_same_ver_lock = lock_packages(_path_lock(_ALT_SHA, "1.9.1"))
    res_same_ver = resolve_pub_packages(
        [],
        [
            struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade"),
            struct(name = "user_deps", lock = "//:pubspec.lock", packages = conflict_same_ver_lock, on_version_conflict = "upgrade"),
        ],
    )
    asserts.true(env, res_same_ver.error != None and 'Package "path" (1.9.1) has conflicting sha256 checksums across lock files' in res_same_ver.error)

    # 4. Two lower-version locks disagreeing on sha256 for 1.9.0 fail even when
    # superseded by 1.9.1 in a third lock.
    lock_190_a = lock_packages(_path_lock(_PATH_190_SHA, "1.9.0"))
    lock_190_b = lock_packages(_path_lock(_ALT_SHA, "1.9.0"))
    res_superseded_conflict = resolve_pub_packages(
        [],
        [
            struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade"),
            struct(name = "deps_a", lock = "//:lock_a.lock", packages = lock_190_a, on_version_conflict = "upgrade"),
            struct(name = "deps_b", lock = "//:lock_b.lock", packages = lock_190_b, on_version_conflict = "upgrade"),
        ],
    )
    asserts.true(env, res_superseded_conflict.error != None and 'Package "path" (1.9.0) has conflicting sha256 checksums across lock files' in res_superseded_conflict.error)

    # 5. Conflicting sha256 between pub.package() and pub.from_lock() for the
    # same version fails.
    res_explicit_lock_conflict = resolve_pub_packages(
        [struct(name = "path", version = "1.9.1", sha256 = _ALT_SHA, deps = [])],
        [struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade")],
    )
    asserts.true(env, res_explicit_lock_conflict.error != None and 'Package "path" (1.9.1) has conflicting sha256 checksums between pub.package()' in res_explicit_lock_conflict.error)

    # 6. Duplicate pub.package() declarations where the second has whitespace or
    # conflicting sha256 fail.
    res_dup_pkg_ws = resolve_pub_packages(
        [
            struct(name = "path", version = "1.9.1", sha256 = _PATH_191_SHA, deps = []),
            struct(name = "path", version = "1.9.1", sha256 = "   ", deps = []),
        ],
        [],
    )
    asserts.equals(env, 'pub_package "path" (1.9.1) requires a non-empty sha256.', res_dup_pkg_ws.error)

    res_dup_pkg_conflict = resolve_pub_packages(
        [
            struct(name = "path", version = "1.9.1", sha256 = _PATH_191_SHA, deps = []),
            struct(name = "path", version = "1.9.1", sha256 = _ALT_SHA, deps = []),
        ],
        [],
    )
    asserts.true(env, res_dup_pkg_conflict.error != None and 'Package "path" (1.9.1) has conflicting sha256 checksums across pub.package() declarations' in res_dup_pkg_conflict.error)

    # 7. Valid upgrade across locks with valid 64-hex sha256s succeeds.
    res_ok = resolve_pub_packages(
        [],
        [
            struct(name = "ext_pub_deps", lock = "//dart/ext:pubspec.lock", packages = ext_lock, on_version_conflict = "upgrade"),
            struct(name = "deps_a", lock = "//:lock_a.lock", packages = lock_190_a, on_version_conflict = "upgrade"),
        ],
    )
    asserts.equals(env, None, res_ok.error)
    asserts.equals(env, "1.9.1", res_ok.resolved["path"].version)
    asserts.equals(env, _PATH_191_SHA, res_ok.resolved["path"].sha256)

    return unittest.end(env)

def _trim_gzip_trailing_nulls_test_impl(ctx):
    env = unittest.begin(ctx)

    # `nested@1.0.0` gzip trailer: CRC32 48cd5f2d + ISIZE 00ce0000 (52,736 bytes).
    nested_stream = "\037\213\010\000body\110\315\137\055\000\316\000\000"
    asserts.equals(env, nested_stream, trim_gzip_trailing_nulls(nested_stream))
    asserts.equals(
        env,
        nested_stream,
        trim_gzip_trailing_nulls(nested_stream + ("\0" * 868)),
    )

    # Uncompressed tar size >= 64 KiB (ISIZE = 0x00010400 -> 1 trailing NUL in trailer).
    medium_stream = "\037\213\010\000body\001\002\003\004\000\004\001\000"
    asserts.equals(env, medium_stream, trim_gzip_trailing_nulls(medium_stream))
    asserts.equals(
        env,
        medium_stream,
        trim_gzip_trailing_nulls(medium_stream + ("\0" * 512)),
    )

    # Uncompressed tar size an exact multiple of 64 KiB (ISIZE = 0x00010000).
    aligned_stream = "\037\213\010\000" + ("x" * 1024) + "\253\267\114\106\000\000\001\000"
    asserts.equals(
        env,
        aligned_stream,
        trim_gzip_trailing_nulls(aligned_stream + ("\0" * 512)),
    )
    return unittest.end(env)

def _pub_lock_package_extracted_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartInfo]
    srcs = [f.short_path for f in info.transitive_srcs.to_list()]
    asserts.true(
        env,
        any([p.endswith("/lib/collection.dart") for p in srcs]),
        "pub_lock_package extracts lib/collection.dart from real pub archive: %s" % srcs,
    )
    pkgs = {p.package_name: p for p in info.transitive_packages.to_list()}
    asserts.true(env, "collection" in pkgs, "collection package record is present")
    return analysistest.end(env)

_pub_lock_package_extracted_test = analysistest.make(_pub_lock_package_extracted_test_impl)

_missing_sha256_test = unittest.make(_lock_package_missing_sha256_test_impl)
_missing_resolved_ref_test = unittest.make(_lock_package_missing_resolved_ref_test_impl)
_invalid_resolved_ref_test = unittest.make(_lock_package_invalid_resolved_ref_test_impl)
_isolated_git_test = unittest.make(_resolve_pub_packages_isolated_git_test_impl)
_conflict_test = unittest.make(_resolve_pub_packages_conflict_test_impl)
_trim_gzip_trailing_nulls_test = unittest.make(_trim_gzip_trailing_nulls_test_impl)

def pin_checks_test_suite(name):
    """Declares the pin check and package resolution tests.

    Args:
        name: The test suite name.
    """
    _pub_lock_package_extracted_test(
        name = name + "_pub_lock_package_extracted_test",
        target_under_test = "@ext_pub_deps//:collection",
        size = "small",
    )
    small_unittest_suite(
        name + "_unit",
        _missing_sha256_test,
        _missing_resolved_ref_test,
        _invalid_resolved_ref_test,
        _isolated_git_test,
        _conflict_test,
        _trim_gzip_trailing_nulls_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_pub_lock_package_extracted_test",
        ],
    )
