"""Unit tests for the resolution-variant rule in the asset manifest.

The rule is flutter_tools': the ratio comes from the file's immediate parent
directory, and any directory whose name ends in `<number>x` is a variant.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_asset_bundle.bzl", "build_asset_manifest", "detect_dpr")
load("//flutter/private:flutter_pub_assets.bzl", "is_asset_variant_dir")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _dprs(manifest, key):
    """The (asset, dpr) pairs of one manifest key, dpr None when absent."""
    return [(v["asset"], v.get("dpr")) for v in manifest[key]]

def _open_numbers_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/a.png",
        "assets/2.5x/a.png",
        "assets/0.75x/a.png",
    ])
    asserts.equals(env, ["assets/a.png"], sorted(manifest.keys()))
    asserts.equals(env, [
        ("assets/a.png", None),
        ("assets/0.75x/a.png", 0.75),
        ("assets/2.5x/a.png", 2.5),
    ], sorted(_dprs(manifest, "assets/a.png"), key = lambda p: (p[1] != None, p[1] or 0.0)))
    return unittest.end(env)

def _variant_only_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/1.0x/a.png", "assets/2.x/a.png"])
    asserts.equals(env, ["assets/a.png"], sorted(manifest.keys()))
    asserts.equals(env, [1.0, 2.0], sorted([d for _a, d in _dprs(manifest, "assets/a.png")]))
    return unittest.end(env)

def _parent_only_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/2x/sub/a.png", "assets/sub/a.png"])
    asserts.equals(env, ["assets/2x/sub/a.png", "assets/sub/a.png"], sorted(manifest.keys()))
    asserts.equals(env, [("assets/2x/sub/a.png", None)], _dprs(manifest, "assets/2x/sub/a.png"))
    asserts.equals(env, [("assets/sub/a.png", None)], _dprs(manifest, "assets/sub/a.png"))
    base, dpr = detect_dpr("assets/2x/sub/a.png")
    asserts.equals(env, "assets/2x/sub/a.png", base)
    asserts.equals(env, None, dpr)
    return unittest.end(env)

def _pub_keys_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "packages/pkg_assets/img/a.png",
        "packages/pkg_assets/img/2.5x/a.png",
        "packages/pkg_assets/img/0.75x/a.png",
        "packages/pkg_assets/img/2x/sub/a.png",
    ])
    asserts.equals(env, [
        "packages/pkg_assets/img/2x/sub/a.png",
        "packages/pkg_assets/img/a.png",
    ], sorted(manifest.keys()))
    dprs = [d for _a, d in _dprs(manifest, "packages/pkg_assets/img/a.png")]
    asserts.equals(env, [None, 2.5, 0.75], dprs[:1] + sorted(dprs[1:], reverse = True))
    return unittest.end(env)

def _seven_names_test_impl(ctx):
    env = unittest.begin(ctx)
    names = {"1.5x": 1.5, "2x": 2.0, "2.0x": 2.0, "3x": 3.0, "3.0x": 3.0, "4x": 4.0, "4.0x": 4.0}
    for name, want in names.items():
        manifest = build_asset_manifest(["assets/a.png", "assets/%s/a.png" % name])
        asserts.equals(env, ["assets/a.png"], sorted(manifest.keys()), name)
        want_pairs = [("assets/a.png", None), ("assets/%s/a.png" % name, want)]
        asserts.equals(env, want_pairs, _dprs(manifest, "assets/a.png"), name)
    return unittest.end(env)

def _dir_names_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["2x", "2.0x", "1.5x", "2.5x", "0.75x", "1.0x", "2.x", "10x"]:
        asserts.true(env, is_asset_variant_dir(name), name)
    for name in ["sub", "x", "foo", "2xx", ".x", "2x3"]:
        asserts.false(env, is_asset_variant_dir(name), name)
    return unittest.end(env)

_t0_test = unittest.make(_open_numbers_test_impl)
_t1_test = unittest.make(_variant_only_test_impl)
_t2_test = unittest.make(_parent_only_test_impl)
_t3_test = unittest.make(_pub_keys_test_impl)
_t4_test = unittest.make(_seven_names_test_impl)
_t5_test = unittest.make(_dir_names_test_impl)

def asset_variants_test_suite(name):
    """Registers the asset-variant unit tests.

    Args:
        name: The `test_suite` name.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
