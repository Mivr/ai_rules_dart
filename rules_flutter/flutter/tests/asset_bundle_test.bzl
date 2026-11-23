"""Unit tests for flutter_asset_bundle.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_asset_bundle.bzl", "build_asset_manifest", "detect_dpr")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _detect_dpr_no_variant_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, None, dpr)
    return unittest.end(env)

def _detect_dpr_2x_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/2.0x/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, 2.0, dpr)
    return unittest.end(env)

def _detect_dpr_3x_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/3.0x/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, 3.0, dpr)
    return unittest.end(env)

def _detect_dpr_shorthand_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("images/2x/photo.jpg")
    asserts.equals(env, "images/photo.jpg", base)
    asserts.equals(env, 2.0, dpr)
    return unittest.end(env)

def _manifest_basic_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/icon.png"])
    asserts.true(env, "assets/icon.png" in manifest, "should have base key")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, "assets/icon.png", variants[0]["asset"])
    return unittest.end(env)

def _manifest_with_variants_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/icon.png",
        "assets/2.0x/icon.png",
        "assets/3.0x/icon.png",
    ])
    asserts.true(env, "assets/icon.png" in manifest, "should group under base path")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 3, len(variants))

    # The 1x (base) variant should be first.
    asserts.equals(env, "assets/icon.png", variants[0]["asset"])
    return unittest.end(env)

def _manifest_variant_only_test_impl(ctx):
    """A DPR variant with no 1x base should still work."""
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/2.0x/icon.png"])
    asserts.true(env, "assets/icon.png" in manifest, "should use base as key")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, 2.0, variants[0]["dpr"])
    return unittest.end(env)

def _manifest_decodes_keys_test_impl(ctx):
    """Manifest keys and variants decode, copies stay encoded.

    Mirrors `_createAssetManifest` (flutter_tools 3.47.7 `asset.dart:923-929`):
    the bundle files stay under their encoded keys, while every manifest key
    and variant path is `Uri.decodeFull` of its key.
    """
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "2.0x/a%20b.png",
        "a%20b.png",
        "ca" + "f%C3%A9.png",
        "pct%25.png",
    ])
    asserts.equals(
        env,
        ["a b.png", "ca" + "f" + "\303\251" + ".png", "pct%.png"],
        sorted(manifest.keys()),
    )
    variants = manifest["a b.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "a b.png", variants[0]["asset"])
    asserts.equals(env, "2.0x/a b.png", variants[1]["asset"])
    asserts.equals(env, 2.0, variants[1]["dpr"])
    asserts.equals(env, "pct%.png", manifest["pct%.png"][0]["asset"])
    asserts.equals(
        env,
        "ca" + "f" + "\303\251" + ".png",
        manifest["ca" + "f" + "\303\251" + ".png"][0]["asset"],
    )
    return unittest.end(env)

def _manifest_empty_segment_test_impl(ctx):
    """An empty-segment entry keys the raw path with flutter_tools' variants.

    Oracle-checked against flutter_tools 3.47.7 (`ManifestAssetBundle.build`
    over files `a/b.png`, `a/2.0x/b.png`): entry `a//b.png` manifests as
    `a//b.png` <- [`a//b.png`, `a/b.png`, `a/2.0x/b.png` dpr 2.0], and no
    key names the undeclared collapsed file. Copies still read the
    collapsed file, so the bundle holds both spellings.
    """
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "packages/hpkg/a//b.png",
        "packages/hpkg/a/2.0x/b.png",
    ])
    asserts.equals(env, ["packages/hpkg/a//b.png"], sorted(manifest.keys()))
    variants = manifest["packages/hpkg/a//b.png"]
    asserts.equals(env, 3, len(variants))
    asserts.equals(env, "packages/hpkg/a//b.png", variants[0]["asset"])
    asserts.false(env, "dpr" in variants[0], "raw variant has no variant dir")
    asserts.equals(env, "packages/hpkg/a/b.png", variants[1]["asset"])
    asserts.false(env, "dpr" in variants[1], "collapsed variant has no variant dir")
    asserts.equals(env, "packages/hpkg/a/2.0x/b.png", variants[2]["asset"])
    asserts.equals(env, 2.0, variants[2]["dpr"])
    return unittest.end(env)

def _manifest_empty_segment_variant_dir_test_impl(ctx):
    """An empty segment inside a variant directory keeps its own dpr.

    Oracle-checked against flutter_tools 3.47.7: entry `a//2.0x/b.png`
    manifests as `a//2.0x/b.png` <- [`a//2.0x/b.png` dpr 2.0,
    `a/2.0x/b.png` dpr 2.0] — each variant carries the dpr parsed from its
    own parent directory, never a phantom `a//b.png` key.
    """
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["packages/hpkg/a//2.0x/b.png"])
    asserts.equals(env, ["packages/hpkg/a//2.0x/b.png"], sorted(manifest.keys()))
    variants = manifest["packages/hpkg/a//2.0x/b.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "packages/hpkg/a//2.0x/b.png", variants[0]["asset"])
    asserts.equals(env, 2.0, variants[0]["dpr"])
    asserts.equals(env, "packages/hpkg/a/2.0x/b.png", variants[1]["asset"])
    asserts.equals(env, 2.0, variants[1]["dpr"])
    return unittest.end(env)

def _manifest_empty_segment_no_variants_test_impl(ctx):
    """An empty-segment entry without variants still lists the collapsed file.

    Oracle-checked against flutter_tools 3.47.7: entry `e//em.png` (only
    `e/em.png` on disk) manifests as `e//em.png` <- [`e//em.png`,
    `e/em.png`].
    """
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["e//em.png"])
    asserts.equals(env, ["e//em.png"], sorted(manifest.keys()))
    variants = manifest["e//em.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "e//em.png", variants[0]["asset"])
    asserts.equals(env, "e/em.png", variants[1]["asset"])
    return unittest.end(env)

_t0_test = unittest.make(_detect_dpr_no_variant_test_impl)
_t1_test = unittest.make(_detect_dpr_2x_test_impl)
_t2_test = unittest.make(_detect_dpr_3x_test_impl)
_t3_test = unittest.make(_detect_dpr_shorthand_test_impl)
_t4_test = unittest.make(_manifest_basic_test_impl)
_t5_test = unittest.make(_manifest_with_variants_test_impl)
_t6_test = unittest.make(_manifest_variant_only_test_impl)
_t7_test = unittest.make(_manifest_decodes_keys_test_impl)
_t8_test = unittest.make(_manifest_empty_segment_test_impl)
_t9_test = unittest.make(_manifest_empty_segment_variant_dir_test_impl)
_t10_test = unittest.make(_manifest_empty_segment_no_variants_test_impl)

def asset_bundle_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
    )
