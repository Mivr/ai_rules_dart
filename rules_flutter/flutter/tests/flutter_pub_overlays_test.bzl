"""Tests for per-hub plugin overlay root selection (root-wins).

A hub declared by module M consults the root module's overlay roots
first, then M's own roots (when M is not the root), then the bundled
`@rules_flutter//ext` root (appended by the extension, not here). A
module's overlays never reach a hub another non-root module declared,
and never the root's hubs.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_overlays.bzl", "hub_overlay_roots")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _root_hub_uses_only_root_roots_test_impl(ctx):
    """A root hub sees the root's roots even when a dependency overlays too."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["//:root_ext", "//:root_ext2"],
        hub_overlay_roots(["//:root_ext", "//:root_ext2"], ["//:dep_ext"], True),
    )
    return unittest.end(env)

root_hub_uses_only_root_roots_test = unittest.make(_root_hub_uses_only_root_roots_test_impl)

def _dep_hub_sees_root_first_test_impl(ctx):
    """A dependency's hub lists the root's roots before its own module's."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["//:root_ext", "//:dep_ext"],
        hub_overlay_roots(["//:root_ext"], ["//:dep_ext"], False),
    )
    return unittest.end(env)

dep_hub_sees_root_first_test = unittest.make(_dep_hub_sees_root_first_test_impl)

def _shared_package_prefers_the_root_overlay_test_impl(ctx):
    """With both modules overlaying one package, the root's root comes first.

    The spoke uses the first root holding a template for the package, so
    first position is what makes the root's overlay win over the
    dependency's.
    """
    env = unittest.begin(ctx)
    roots = hub_overlay_roots(["//:root_overlays"], ["//:dep_overlays"], False)
    asserts.equals(env, ["//:root_overlays", "//:dep_overlays"], roots)
    asserts.true(env, roots[0] == "//:root_overlays", "the root's overlay must win, got {}".format(roots))
    return unittest.end(env)

shared_package_prefers_the_root_overlay_test = unittest.make(_shared_package_prefers_the_root_overlay_test_impl)

def _dep_overlays_never_reach_other_hubs_test_impl(ctx):
    """One dependency's roots reach only its own hubs, and no root hub."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["//:root_ext"],
        hub_overlay_roots(["//:root_ext"], ["//:other_dep_ext"], True),
    )
    asserts.equals(
        env,
        ["//:dep_ext"],
        hub_overlay_roots([], ["//:dep_ext"], False),
    )
    return unittest.end(env)

dep_overlays_never_reach_other_hubs_test = unittest.make(_dep_overlays_never_reach_other_hubs_test_impl)

def _tag_order_survives_selection_test_impl(ctx):
    """Order inside one module stays tag order through selection."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["//:r1", "//:r2", "//:d1", "//:d2"],
        hub_overlay_roots(["//:r1", "//:r2"], ["//:d1", "//:d2"], False),
    )
    return unittest.end(env)

tag_order_survives_selection_test = unittest.make(_tag_order_survives_selection_test_impl)

def flutter_pub_overlays_test_suite(name):
    """Declares the overlay root-wins unit tests.

    Args:
        name: Test suite name.
    """
    small_unittest_suite(
        name,
        dep_hub_sees_root_first_test,
        dep_overlays_never_reach_other_hubs_test,
        root_hub_uses_only_root_roots_test,
        shared_package_prefers_the_root_overlay_test,
        tag_order_survives_selection_test,
    )
