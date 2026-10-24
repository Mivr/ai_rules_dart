"""Unit tests for the pub archive header scan's pure Starlark half."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/pub:pub_lock_package.bzl",
    _public_run = "run_pub_archive_scan",
)

# The spoke-facing names live on the public `pub_scan` module so
# `rules_flutter` reuses the same scan and walk; pin them here.
load(
    "//dart/pub:pub_scan.bzl",
    _public_check = "check_package_symlinks",
    _public_scanner = "PUB_SCANNER_LABEL",
    _public_scanner_windows = "PUB_SCANNER_WINDOWS_LABEL",
    _scan_run = "run_pub_archive_scan",
)

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:pub_archive_scan.bzl",
    "archive_entry_error",
    "archive_entry_path_escapes",
    "archive_path_error",
    "classify_archive_entry",
    "scan_error",
)

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_symlink.bzl", _walk_check = "check_package_symlinks")
load(":small_suite.bzl", "small_unittest_suite")

_PATH_CASES = {
    "/abs.dart": True,
    "../outside.dart": True,
    "lib/../../outside.dart": True,
    "..\\outside.dart": True,
    "lib/ok.dart": False,
    "lib/../lib/ok.dart": False,
    "lib/": False,
    "./lib/ok.dart": False,
}

def _classify_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(
        env,
        classify_archive_entry("lib/evil.dart", "1", "lib/ok.dart") != None,
        "a hard link is refused even when its target stays inside",
    )
    hard = classify_archive_entry("lib/evil.dart", "1", "../outside.txt")
    asserts.equals(env, ("hard-link", "lib/evil.dart", "../outside.txt"), (hard.kind, hard.path, hard.target), "a hard-link refusal names kind, path and target")
    asserts.true(
        env,
        classify_archive_entry("lib/evil.dart", "2", "/etc/passwd") != None,
        "an absolute symlink is refused",
    )
    link = classify_archive_entry("lib/evil.dart", "2", "../../outside.txt")
    asserts.equals(env, ("symlink", "lib/evil.dart", "../../outside.txt"), (link.kind, link.path, link.target), "a symlink refusal names kind, path and target")
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
    for name in sorted(_PATH_CASES.keys()):
        want = _PATH_CASES[name]
        got = classify_archive_entry(name, "0", "")
        asserts.equals(env, want, got != None and got.kind == "path", "entry path %r escapes: %s" % (name, want))
    return unittest.end(env)

def _escapes_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in sorted(_PATH_CASES.keys()):
        asserts.equals(env, _PATH_CASES[name], archive_entry_path_escapes(name), "path escape %r" % name)
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
    path = archive_path_error("evil_pkg", "../outside.dart")
    asserts.true(env, "evil_pkg" in path and "../outside.dart" in path, "path diagnostic names the package and path: %s" % path)
    asserts.true(
        env,
        path.startswith('pub package "evil_pkg": entry "../outside.dart" escapes the package'),
        "path diagnostic shares the walk diagnostic's vocabulary: %s" % path,
    )
    scan = scan_error("evil_pkg", "the tar archive is truncated")
    asserts.true(env, "evil_pkg" in scan and "the tar archive is truncated" in scan, "scan diagnostic names the package and detail: %s" % scan)
    return unittest.end(env)

def _reexport_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _walk_check, _public_check, "the public walk re-export is the walk function")
    asserts.equals(env, _scan_run, _public_run, "the spoke-facing scan re-export is the scanner call")
    asserts.equals(env, Label("@dart_pub_scanner//:scanner"), _public_scanner, "the scanner label names the shared repository")
    asserts.equals(env, Label("@dart_pub_scanner//:scanner.exe"), _public_scanner_windows, "the Windows scanner label names the shared repository")
    return unittest.end(env)

_t0_test = unittest.make(_classify_test_impl)
_t1_test = unittest.make(_escapes_test_impl)
_t2_test = unittest.make(_error_test_impl)
_t3_test = unittest.make(_reexport_test_impl)

def pub_archive_scan_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
    )
