"""Unit tests for the pub archive header scan (`dart/pub/private/pub_archive_scan.bzl`)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:pub_archive_scan.bzl",
    "archive_entry_error",
    "classify_archive_entry",
    "scan_archive_bytes",
)
# The spoke-facing re-exports live on the public `pub_lock_package` module so
# `rules_flutter` can reuse the same scan; pin them to the scanner functions.
load(
    "//dart/pub:pub_lock_package.bzl",
    _public_refuse_archive_bytes = "refuse_archive_bytes",
    _public_scan_archive_bytes = "scan_archive_bytes",
)
load(
    ":pub_archive_fixtures.bzl",
    "CLEAN_BASE256",
    "CLEAN_DEVICES",
    "CLEAN_FIXED",
    "CLEAN_FNAME",
    "CLEAN_GNU_LONGNAME",
    "CLEAN_MULTI",
    "CLEAN_NULPAD",
    "CLEAN_NULTYPE",
    "CLEAN_PAX",
    "CLEAN_PLAIN",
    "CLEAN_PLAIN_PAX",
    "CLEAN_PREFIX",
    "CLEAN_STORED",
    "CLEAN_USTAR",
    "EVIL_ABS",
    "EVIL_ESC",
    "EVIL_ESC_PLAIN",
    "EVIL_GNU_TARGET",
    "EVIL_HARD_ABS",
    "EVIL_HARD_IN",
    "EVIL_HARD_OUT",
    "EVIL_HARD_PLAIN",
    "EVIL_PAX_GLOBAL",
    "EVIL_PAX_TARGET",
)
load(":small_suite.bzl", "small_unittest_suite")

_CLEANS = {
    "ustar": CLEAN_USTAR,
    "prefix": CLEAN_PREFIX,
    "gnu-longname": CLEAN_GNU_LONGNAME,
    "pax": CLEAN_PAX,
    "stored-deflate": CLEAN_STORED,
    "fixed-huffman": CLEAN_FIXED,
    "multi-member": CLEAN_MULTI,
    "fname-header": CLEAN_FNAME,
    "nul-padded": CLEAN_NULPAD,
    "plain-tar": CLEAN_PLAIN,
    "nul-typeflag": CLEAN_NULTYPE,
    "base256-size": CLEAN_BASE256,
    "devices": CLEAN_DEVICES,
    "plain-pax": CLEAN_PLAIN_PAX,
}

_EVILS = {
    "hard-link-out": (EVIL_HARD_OUT, ("hard-link", "lib/evil.dart", "../outside.txt")),
    "hard-link-in": (EVIL_HARD_IN, ("hard-link", "lib/evil.dart", "lib/ok.dart")),
    "hard-link-abs": (EVIL_HARD_ABS, ("hard-link", "lib/evil.dart", "/etc/passwd")),
    "abs-symlink": (EVIL_ABS, ("symlink", "lib/evil.dart", "/etc/passwd")),
    "escaping-symlink": (EVIL_ESC, ("symlink", "lib/evil.dart", "../../outside.txt")),
    "gnu-longlink": (EVIL_GNU_TARGET, ("symlink", "lib/evil.dart", "../../outside.txt")),
    "pax-linkpath": (EVIL_PAX_TARGET, ("symlink", "lib/evil.dart", "../../outside.txt")),
    "pax-global-linkpath": (EVIL_PAX_GLOBAL, ("symlink", "lib/evil.dart", "/etc/global")),
    "plain-hard-link": (EVIL_HARD_PLAIN, ("hard-link", "pkg/lib/evil.dart", "../outside.txt")),
    "plain-escaping-symlink": (EVIL_ESC_PLAIN, ("symlink", "pkg/lib/evil.dart", "../../../outside.txt")),
}

def _clean_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in sorted(_CLEANS.keys()):
        asserts.true(
            env,
            scan_archive_bytes(_CLEANS[name], "test_pkg") == None,
            "clean %s archive scans clean" % name,
        )
    return unittest.end(env)

def _evil_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in sorted(_EVILS.keys()):
        data, want = _EVILS[name]
        got = scan_archive_bytes(data, "test_pkg")
        asserts.true(env, got != None, "evil %s archive is refused" % name)
        if got != None:
            asserts.equals(env, want, (got.kind, got.path, got.target), "evil %s refusal names kind, path and target" % name)
    return unittest.end(env)

def _classify_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(
        env,
        classify_archive_entry("lib/evil.dart", "1", "lib/ok.dart") != None,
        "a hard link is refused even when its target stays inside",
    )
    asserts.true(
        env,
        scan_archive_bytes(CLEAN_PLAIN, "test_pkg") == None,
        "an in-package symlink through a plain tar scans clean",
    )
    asserts.true(
        env,
        classify_archive_entry("lib/a.dart", "2", "b.dart") == None,
        "an in-package symlink classifies clean",
    )
    asserts.true(
        env,
        classify_archive_entry("lib/a.dart", "0", "/etc/passwd") == None,
        "a regular file classifies clean whatever its link field holds",
    )
    asserts.true(
        env,
        classify_archive_entry("dev/null", "3", "") == None,
        "a device entry classifies clean",
    )
    return unittest.end(env)

def _error_test_impl(ctx):
    env = unittest.begin(ctx)
    hard = archive_entry_error("evil_pkg", "lib/evil.dart", "hard-link", "../outside.txt")
    asserts.true(env, "evil_pkg" in hard, "hard-link diagnostic names the package: %s" % hard)
    asserts.true(env, "lib/evil.dart" in hard, "hard-link diagnostic names the path: %s" % hard)
    asserts.true(env, "hard-link" in hard, "hard-link diagnostic names the kind: %s" % hard)
    asserts.true(env, "../outside.txt" in hard, "hard-link diagnostic names the raw target: %s" % hard)
    link = archive_entry_error("evil_pkg", "lib/evil.dart", "symlink", "/etc/passwd")
    asserts.true(env, "evil_pkg" in link and "lib/evil.dart" in link, "symlink diagnostic names the package and path: %s" % link)
    asserts.true(env, "symlink" in link and "/etc/passwd" in link, "symlink diagnostic names the kind and raw target: %s" % link)
    asserts.true(
        env,
        link.startswith('pub package "evil_pkg": symlink "lib/evil.dart" escapes the package'),
        "symlink diagnostic shares the walk diagnostic's prefix so one grep matches either guard: %s" % link,
    )
    return unittest.end(env)

def _reexport_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _public_scan_archive_bytes, scan_archive_bytes, "the public scan re-export is the scanner function")
    asserts.true(
        env,
        _public_refuse_archive_bytes(CLEAN_PLAIN, "test_pkg") == None,
        "the public refuse wrapper stays silent on a clean archive",
    )
    return unittest.end(env)

_t0_test = unittest.make(_clean_test_impl)
_t1_test = unittest.make(_evil_test_impl)
_t2_test = unittest.make(_classify_test_impl)
_t3_test = unittest.make(_error_test_impl)
_t4_test = unittest.make(_reexport_test_impl)

def pub_archive_scan_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
    )
