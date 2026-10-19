"""Unit tests for the pub symlink guard (`dart/pub/private/pub_symlink.bzl`)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_symlink.bzl", "is_absolute_symlink_target", "pub_symlink_error", "symlink_escapes_package")
load(":small_suite.bzl", "small_unittest_suite")

def _in_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, symlink_escapes_package("lib/a.dart", "b.dart"), "sibling target stays inside")
    asserts.false(env, symlink_escapes_package("lib/a.dart", "./b.dart"), "dot segment stays inside")
    asserts.false(env, symlink_escapes_package("lib/a.dart", "sub/b.dart"), "subdirectory stays inside")
    asserts.false(env, symlink_escapes_package("lib/a.dart", "../lib/b.dart"), "up-and-back stays inside")
    asserts.false(env, symlink_escapes_package("lib/sub/a.dart", "../../b.dart"), "climb to the root stays inside")
    asserts.false(env, symlink_escapes_package("a.dart", "b.dart"), "top-level sibling stays inside")
    asserts.false(env, symlink_escapes_package("lib/a.dart", "../other/b.dart"), "sibling directory stays inside")
    return unittest.end(env)

def _escaping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, symlink_escapes_package("a.dart", "../evil.dart"), "one level above the root escapes")
    asserts.true(env, symlink_escapes_package("lib/secret.dart", "../../evil.dart"), "two levels up from lib/ escapes")
    asserts.true(env, symlink_escapes_package("lib/sub/a.dart", "../../../evil.dart"), "three levels up escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "..\\..\\evil.dart"), "backslash separators escape the same way")
    asserts.true(env, symlink_escapes_package("lib/a.dart", ""), "an empty target is broken and escapes")
    return unittest.end(env)

def _absolute_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, symlink_escapes_package("lib/a.dart", "/etc/passwd"), "POSIX absolute target escapes")
    asserts.true(env, symlink_escapes_package("a.dart", "/etc/passwd"), "top-level absolute target escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "C:/secret.txt"), "Windows drive target escapes")
    asserts.true(env, is_absolute_symlink_target("/etc/passwd"))
    asserts.true(env, is_absolute_symlink_target("C:/secret.txt"))
    asserts.false(env, is_absolute_symlink_target("b.dart"))
    asserts.false(env, is_absolute_symlink_target("../evil.dart"))
    return unittest.end(env)

def _error_test_impl(ctx):
    env = unittest.begin(ctx)
    err = pub_symlink_error("evil_pkg", "lib/secret.dart", "../../evil.txt")
    asserts.true(env, "evil_pkg" in err, "diagnostic names the package: %s" % err)
    asserts.true(env, "lib/secret.dart" in err, "diagnostic names the link: %s" % err)
    asserts.true(env, "symlink" in err, "diagnostic says symlink: %s" % err)
    return unittest.end(env)

_t0_test = unittest.make(_in_package_test_impl)
_t1_test = unittest.make(_escaping_test_impl)
_t2_test = unittest.make(_absolute_test_impl)
_t3_test = unittest.make(_error_test_impl)

def pub_symlink_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
    )
