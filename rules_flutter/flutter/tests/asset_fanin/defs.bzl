"""Fan-in benchmark fixture (COV-63): bundle analysis cost vs dep count.

`asset_fanin_pool` declares one weighted base library carrying `p`
generated pub contributions (half font families, half plain assets) and a
fixed pool of thin libraries that each depend only on the base. The two
measured bundles live in the `narrow/` and `wide/` subpackages, declared
with `asset_fanin_narrow` (one thin dep) and `asset_fanin_wide` (every
thin dep), so that touching one bundle's BUILD file re-analyses only that
bundle. Analysis cost must be linear in the contributions a bundle ships,
so `wide - narrow` must not grow with `p`. Every target is `manual`: the
pool at `p = 6000` stays out of `//...` builds.
"""

load("//flutter:defs.bzl", "flutter_asset_bundle", "flutter_library")

visibility(["//flutter/tests/..."])

def _declare_weight(name, count):
    """Declares `count` generated files and returns the base's pub attrs.

    Args:
        name: Prefix for the genrule targets.
        count: Total generated contributions (even counts only).

    Returns:
        A `(font_files, fonts_json, pkg_assets)` triple for the base.
    """
    font_files = {}
    families = []
    pkg_assets = {}
    for i in range(0, count, 2):
        ttf = "%s_%d.ttf" % (name, i)
        txt = "%s_%d.txt" % (name, i)
        native.genrule(
            name = "%s_ttf_%d" % (name, i),
            outs = [ttf],
            cmd = "echo weight > $@",
            tags = ["manual"],
        )
        native.genrule(
            name = "%s_txt_%d" % (name, i),
            outs = [txt],
            cmd = "echo weight > $@",
            tags = ["manual"],
        )
        font_files[":%s_ttf_%d" % (name, i)] = "gen/%s" % ttf
        families.append('{"family":"Fam%d","fonts":[{"asset":"gen/%s"}]}' % (i, ttf))
        pkg_assets[":%s_txt_%d" % (name, i)] = "gen/%s" % txt
    return (font_files, "[" + ",".join(families) + "]", pkg_assets)

def asset_fanin_pool(name, p = 6000, thin_count = 300):
    """Declares the weighted base and the fixed thin-dep pool.

    Args:
        name: Prefix for the base and every thin library.
        p: Generated weight contributions on the base (even counts only).
        thin_count: Thin libraries, each depending only on the base.
    """
    font_files, fonts_json, pkg_assets = _declare_weight(name + "_w", p)
    base = name + "_base"
    flutter_library(
        name = base,
        srcs = ["stub.dart"],
        font_files = font_files,
        fonts_json = fonts_json,
        pkg_assets = pkg_assets,
        tags = ["manual"],
    )
    for i in range(thin_count):
        flutter_library(
            name = "%s_thin_%d" % (name, i),
            srcs = ["stub.dart"],
            deps = [":" + base],
            tags = ["manual"],
        )

def asset_fanin_narrow(name, pool, stem):
    """Declares the narrow bundle over one thin dep from the pool.

    Args:
        name: Name of the bundle target.
        pool: Label of the package holding the pool.
        stem: Name prefix the pool was declared with.
    """
    flutter_asset_bundle(
        name = name,
        tags = ["manual"],
        deps = [pool + ":" + stem + "_thin_0"],
    )

def asset_fanin_wide(name, pool, stem, thin_count = 300):
    """Declares the wide bundle over every thin dep in the pool.

    Args:
        name: Name of the bundle target.
        pool: Label of the package holding the pool.
        stem: Name prefix the pool was declared with.
        thin_count: Thin libraries the bundle takes; matches the pool.
    """
    flutter_asset_bundle(
        name = name,
        tags = ["manual"],
        deps = [pool + ":" + stem + "_thin_%d" % i for i in range(thin_count)],
    )
