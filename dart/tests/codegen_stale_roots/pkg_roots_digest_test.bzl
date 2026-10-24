"""Unit tests for `pkg_roots_stage_digest` (the codegen stage-root digest).

The digest names the `<name>.pkg_roots.<digest>` directory a codegen action
stages its declared entry set under. These tests pin the construction's core
promise with duck-typed `struct` fakes (the digest reads only
`package_name`/`lib_root` off packages and `short_path`/`is_directory` off
files): the same declared set digests the same, any change to the set
digests differently, and neither package nor file order leaks in.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:common.bzl", "pkg_roots_stage_digest")

def _pkg(package_name, lib_root):
    return struct(package_name = package_name, lib_root = lib_root)

def _file(short_path, is_directory = False):
    return struct(short_path = short_path, is_directory = is_directory)

def _base_packages():
    return [_pkg("dep_a", "pkgs/dep_a"), _pkg("dep_b", "pkgs/dep_b")]

def _base_by_pkg():
    return {
        "dep_a": [_file("pkgs/dep_a/lib/a.dart"), _file("pkgs/dep_a/lib/src/b.dart")],
        "dep_b": [_file("pkgs/dep_b/lib/c.dart")],
    }

def _assert_hex(env, digest):
    asserts.equals(env, 16, len(digest), "digest must be 16 hex chars, got %s" % digest)
    int(digest, 16)  # aborts the test unless every char is hex

def _digest_deterministic_test_impl(ctx):
    env = unittest.begin(ctx)
    first = pkg_roots_stage_digest(_base_packages(), _base_by_pkg())
    second = pkg_roots_stage_digest(_base_packages(), _base_by_pkg())
    _assert_hex(env, first)
    asserts.equals(env, first, second, "the same declared set must digest the same")
    return unittest.end(env)

_digest_deterministic_test = unittest.make(_digest_deterministic_test_impl)

def _digest_sensitive_test_impl(ctx):
    env = unittest.begin(ctx)
    base = pkg_roots_stage_digest(_base_packages(), _base_by_pkg())

    by_pkg = _base_by_pkg()
    by_pkg["dep_a"] = by_pkg["dep_a"] + [_file("pkgs/dep_a/lib/d.dart")]
    asserts.false(
        env,
        pkg_roots_stage_digest(_base_packages(), by_pkg) == base,
        "an added file must change the digest",
    )

    by_pkg = _base_by_pkg()
    by_pkg["dep_a"] = [by_pkg["dep_a"][0]]
    asserts.false(
        env,
        pkg_roots_stage_digest(_base_packages(), by_pkg) == base,
        "a dropped file must change the digest",
    )

    by_pkg = _base_by_pkg()
    by_pkg["dep_b"] = [_file("pkgs/dep_b/lib/renamed.dart")]
    asserts.false(
        env,
        pkg_roots_stage_digest(_base_packages(), by_pkg) == base,
        "a renamed file must change the digest",
    )

    asserts.false(
        env,
        pkg_roots_stage_digest([_pkg("dep_a", "pkgs/dep_a"), _pkg("dep_b", "pkgs/elsewhere")], _base_by_pkg()) == base,
        "a changed lib_root must change the digest",
    )

    moved_by_pkg = {"dep_a": _base_by_pkg()["dep_a"], "dep_c": _base_by_pkg()["dep_b"]}
    asserts.false(
        env,
        pkg_roots_stage_digest([_pkg("dep_a", "pkgs/dep_a"), _pkg("dep_c", "pkgs/dep_b")], moved_by_pkg) == base,
        "a renamed package must change the digest",
    )

    asserts.false(
        env,
        pkg_roots_stage_digest([_pkg("dep_a", "pkgs/dep_a")], _base_by_pkg()) == base,
        "a dropped package must change the digest",
    )

    by_pkg = _base_by_pkg()
    by_pkg["dep_c"] = [_file("pkgs/dep_c/lib/e.dart")]
    asserts.false(
        env,
        pkg_roots_stage_digest(_base_packages() + [_pkg("dep_c", "pkgs/dep_c")], by_pkg) == base,
        "an added package must change the digest",
    )

    only_files = {"only": [_file("pkgs/only/tree")]}
    only_dir = {"only": [_file("pkgs/only/tree", is_directory = True)]}
    only_pkg = [_pkg("only", "pkgs/only")]
    asserts.false(
        env,
        pkg_roots_stage_digest(only_pkg, only_files) == pkg_roots_stage_digest(only_pkg, only_dir),
        "a file and a directory at one path must digest differently",
    )
    return unittest.end(env)

_digest_sensitive_test = unittest.make(_digest_sensitive_test_impl)

def _digest_order_stable_test_impl(ctx):
    env = unittest.begin(ctx)
    base = pkg_roots_stage_digest(_base_packages(), _base_by_pkg())
    reversed_by_pkg = {
        "dep_b": [_file("pkgs/dep_b/lib/c.dart")],
        "dep_a": [_file("pkgs/dep_a/lib/src/b.dart"), _file("pkgs/dep_a/lib/a.dart")],
    }
    asserts.equals(
        env,
        base,
        pkg_roots_stage_digest([_pkg("dep_b", "pkgs/dep_b"), _pkg("dep_a", "pkgs/dep_a")], reversed_by_pkg),
        "package and file order must not leak into the digest",
    )
    return unittest.end(env)

_digest_order_stable_test = unittest.make(_digest_order_stable_test_impl)

def _digest_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    empty = pkg_roots_stage_digest([], {})
    _assert_hex(env, empty)
    asserts.equals(
        env,
        empty,
        pkg_roots_stage_digest([_pkg("", ""), _pkg("", "pkgs/nowhere")], {"orphan": [_file("pkgs/nowhere/lib/x.dart")]}),
        "nameless packages and unowned files must digest as the empty set",
    )
    return unittest.end(env)

_digest_empty_test = unittest.make(_digest_empty_test_impl)

def pkg_roots_digest_suite(name):
    """Instantiates the stage-digest unit tests. Returns their test labels.

    Args:
      name: Prefix for the generated test names.

    Returns:
      The list of test labels for a `test_suite`'s `tests`.
    """
    _digest_deterministic_test(name = name + "_deterministic")
    _digest_sensitive_test(name = name + "_sensitive")
    _digest_order_stable_test(name = name + "_order_stable")
    _digest_empty_test(name = name + "_empty")
    return [
        ":" + name + "_deterministic",
        ":" + name + "_sensitive",
        ":" + name + "_order_stable",
        ":" + name + "_empty",
    ]
