"""Unit tests for the pub symlink guard (`dart/pub/private/pub_symlink.bzl`)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:pub_symlink.bzl",
    "is_absolute_symlink_target",
    "package_relpath",
    "pub_symlink_error",
    "realpath_escapes_root",
    "symlink_escapes_package",
    "walk_symlink_entries",
)
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
    asserts.false(env, symlink_escapes_package("lib/a.dart", "sub//b.dart"), "doubled separators stay inside")
    asserts.false(env, symlink_escapes_package("lib/a.dart", "sub/./b.dart"), "inner dot stays inside")
    return unittest.end(env)

def _escaping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, symlink_escapes_package("a.dart", "../evil.dart"), "one level above the root escapes")
    asserts.true(env, symlink_escapes_package("lib/secret.dart", "../../evil.dart"), "two levels up from lib/ escapes")
    asserts.true(env, symlink_escapes_package("lib/sub/a.dart", "../../../evil.dart"), "three levels up escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "..\\..\\evil.dart"), "backslash separators escape the same way")
    asserts.true(env, symlink_escapes_package("lib/a.dart", ""), "an empty target is broken and escapes")
    asserts.false(env, symlink_escapes_package("lib/a.dart", ".."), "climbing exactly to the root stays inside")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "../.."), "climbing past the parent escapes")
    return unittest.end(env)

def _absolute_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, symlink_escapes_package("lib/a.dart", "/etc/passwd"), "POSIX absolute target escapes")
    asserts.true(env, symlink_escapes_package("a.dart", "/etc/passwd"), "top-level absolute target escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "C:/secret.txt"), "Windows drive target escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "C:secret.txt"), "drive-relative target escapes")
    asserts.true(env, symlink_escapes_package("lib/a.dart", "\\\\host\\share\\evil.txt"), "UNC target escapes")
    asserts.true(env, is_absolute_symlink_target("/etc/passwd"))
    asserts.true(env, is_absolute_symlink_target("C:/secret.txt"))
    asserts.true(env, is_absolute_symlink_target("\\\\host\\share"))
    asserts.false(env, is_absolute_symlink_target("b.dart"))
    asserts.false(env, is_absolute_symlink_target("../evil.dart"))
    return unittest.end(env)

def _error_test_impl(ctx):
    env = unittest.begin(ctx)
    err = pub_symlink_error("evil_pkg", "lib/secret.dart", "../../evil.txt")
    asserts.true(env, "evil_pkg" in err, "diagnostic names the package: %s" % err)
    asserts.true(env, "lib/secret.dart" in err, "diagnostic names the link: %s" % err)
    asserts.true(env, "symlink" in err, "diagnostic says symlink: %s" % err)
    resolved = pub_symlink_error("evil_pkg", "lib/evil.dart", "/tmp/evil/outside.txt")
    asserts.true(env, "evil_pkg" in resolved and "lib/evil.dart" in resolved and "symlink" in resolved, "resolved-target diagnostic names the package and link: %s" % resolved)
    broken = pub_symlink_error("evil_pkg", "lib/evil.dart", "(broken symlink)")
    asserts.true(env, "symlink" in broken and "lib/evil.dart" in broken, "dangling-link diagnostic names the link: %s" % broken)
    return unittest.end(env)

def _relpath_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "lib/a.dart", package_relpath("/root", "/root/lib/a.dart"), "entry under the root cuts to rel")
    asserts.equals(env, "a.dart", package_relpath("/root", "/root/a.dart"), "top-level entry cuts to rel")
    asserts.true(env, package_relpath("/root", "/root") == None, "the root itself has no rel")
    asserts.true(env, package_relpath("/root", "/root2/x.dart") == None, "a sibling prefix is not under the root")
    asserts.true(env, package_relpath("/root", "/other/x.dart") == None, "an outside entry is not under the root")
    return unittest.end(env)

def _escapes_root_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, realpath_escapes_root("/root", "/root"), "the root itself is inside")
    asserts.false(env, realpath_escapes_root("/root", "/root/lib/a.dart"), "a nested target is inside")
    asserts.false(env, realpath_escapes_root("/root", "/root/sub"), "a link-to-dir target is inside")
    asserts.true(env, realpath_escapes_root("/root", "/outside.txt"), "a host target is outside")
    asserts.true(env, realpath_escapes_root("/root", "/root2/x.dart"), "a sibling prefix is outside")
    asserts.true(env, realpath_escapes_root("/root", "/"), "the filesystem root is outside")
    return unittest.end(env)

def _fake_entry(abs, exists = True, is_dir = False, real = None):
    return struct(abs = abs, exists = exists, is_dir = is_dir, real = real if real != None else abs)

def _walk_rels(fs, root):
    out = []
    walk_symlink_entries(lambda d: fs.get(d, []), root, root, out)
    return sorted([link.rel for link in out])

def _walk_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], _walk_rels({}, "/root"), "an empty tree holds no links")
    asserts.equals(
        env,
        [],
        _walk_rels({"/root": [_fake_entry("/root/lib", is_dir = True)], "/root/lib": [_fake_entry("/root/lib/a.dart")]}, "/root"),
        "plain nested dirs hold no links",
    )
    asserts.equals(
        env,
        ["lib/l.dart"],
        _walk_rels({"/root": [_fake_entry("/root/lib/l.dart", real = "/root/lib/a.dart")]}, "/root"),
        "a file link is listed",
    )
    asserts.equals(
        env,
        ["lib/dangling.dart"],
        _walk_rels({"/root": [_fake_entry("/root/lib/dangling.dart", exists = False)]}, "/root"),
        "a dangling link is listed",
    )
    asserts.equals(
        env,
        ["lib/loop1.dart", "lib/loop2.dart"],
        _walk_rels({"/root": [
            _fake_entry("/root/lib/loop1.dart", exists = False),
            _fake_entry("/root/lib/loop2.dart", exists = False),
        ]}, "/root"),
        "a link loop is listed as dangling",
    )
    asserts.equals(
        env,
        ["lib/dir_link"],
        _walk_rels(
            {
                "/root": [_fake_entry("/root/lib/dir_link", is_dir = True, real = "/root/lib/sub")],
                "/root/lib/dir_link": [_fake_entry("/root/lib/dir_link/sneaky.dart")],
            },
            "/root",
        ),
        "a link to a dir is listed but never descended into",
    )
    asserts.equals(
        env,
        ["lib/nested/deep.dart"],
        _walk_rels(
            {
                "/root": [_fake_entry("/root/lib", is_dir = True)],
                "/root/lib": [_fake_entry("/root/lib/nested", is_dir = True)],
                "/root/lib/nested": [_fake_entry("/root/lib/nested/deep.dart", real = "/root/lib/a.dart")],
            },
            "/root",
        ),
        "a nested link is found through real dirs",
    )
    return unittest.end(env)

_t0_test = unittest.make(_in_package_test_impl)
_t1_test = unittest.make(_escaping_test_impl)
_t2_test = unittest.make(_absolute_test_impl)
_t3_test = unittest.make(_error_test_impl)
_t4_test = unittest.make(_relpath_test_impl)
_t5_test = unittest.make(_escapes_root_test_impl)
_t6_test = unittest.make(_walk_test_impl)

def pub_symlink_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
    )
