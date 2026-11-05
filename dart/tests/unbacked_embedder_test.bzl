"""Unit tests for `unbacked_embedder_in_closure` (the Flutter embedder coverage check).

`unbacked_embedder_in_closure` says whether a target's closure holds a
`lib/_embedder.yaml` that the embedder SDK summary does not cover. It reads only
`struct` fields off its `DartInfo` (`package_name`/`lib_root` off the packages
and `short_path` off the resources) so duck-typed fakes drive it. A resource is
unbacked when it is a root `lib/_embedder.yaml` or a nested
`<pkg>/lib/_embedder.yaml` and no `sky_engine` package record names it. The
root and the nested form are asserted as two independent cases, so neither half
of the path check can be dropped unseen.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_analyzer_summary.bzl", "unbacked_embedder_in_closure")

visibility(["//dart/..."])

_SUMMARY = struct(path = "embedder_sdk.dill")

def _pkg(package_name, lib_root = ""):
    """A fake `DartPackageInfo` record."""
    return struct(package_name = package_name, lib_root = lib_root)

def _resource(short_path):
    """A fake resource `File`."""
    return struct(short_path = short_path)

def _info(packages, resources):
    """A fake `DartInfo` whose closure holds `packages` and `resources`."""
    return struct(
        transitive_packages = depset(packages),
        transitive_resources = depset(resources),
    )

def _root_unbacked_test_impl(ctx):
    """A root `lib/_embedder.yaml` that no `sky_engine` names is unbacked."""
    env = unittest.begin(ctx)
    info = _info([], [_resource("lib/_embedder.yaml")])
    asserts.true(
        env,
        unbacked_embedder_in_closure(info, _SUMMARY),
        "a root lib/_embedder.yaml absent from sky_embedders must be unbacked",
    )
    return unittest.end(env)

_root_unbacked_test = unittest.make(_root_unbacked_test_impl)

def _nested_unbacked_test_impl(ctx):
    """A nested `<pkg>/lib/_embedder.yaml` that no `sky_engine` names is unbacked."""
    env = unittest.begin(ctx)
    info = _info([], [_resource("third_party/other/lib/_embedder.yaml")])
    asserts.true(
        env,
        unbacked_embedder_in_closure(info, _SUMMARY),
        "a nested <pkg>/lib/_embedder.yaml absent from sky_embedders must be unbacked",
    )
    return unittest.end(env)

_nested_unbacked_test = unittest.make(_nested_unbacked_test_impl)

def _backed_test_impl(ctx):
    """An embedder that `sky_engine` names is backed, whether root or nested."""
    env = unittest.begin(ctx)
    root = _info([_pkg("sky_engine")], [_resource("lib/_embedder.yaml")])
    asserts.false(
        env,
        unbacked_embedder_in_closure(root, _SUMMARY),
        "a root lib/_embedder.yaml named by sky_embedders must be backed",
    )
    nested = _info(
        [_pkg("sky_engine", "third_party/sky_engine")],
        [_resource("third_party/sky_engine/lib/_embedder.yaml")],
    )
    asserts.false(
        env,
        unbacked_embedder_in_closure(nested, _SUMMARY),
        "a nested <pkg>/lib/_embedder.yaml named by sky_embedders must be backed",
    )
    return unittest.end(env)

_backed_test = unittest.make(_backed_test_impl)

def _no_summary_test_impl(ctx):
    """Without an embedder SDK summary any embedder is unbacked; with no embedder none is."""
    env = unittest.begin(ctx)
    asserts.true(
        env,
        unbacked_embedder_in_closure(_info([_pkg("sky_engine")], []), None),
        "a sky_engine without an embedder SDK summary must be unbacked",
    )
    asserts.false(
        env,
        unbacked_embedder_in_closure(_info([_pkg("other")], [_resource("lib/other.yaml")]), _SUMMARY),
        "a closure without an embedder must not be unbacked",
    )
    return unittest.end(env)

_no_summary_test = unittest.make(_no_summary_test_impl)

def unbacked_embedder_test_suite(name):
    """Declares the `unbacked_embedder_in_closure` unit tests and their `test_suite`.

    Args:
      name: Name of the generated `test_suite`; test names derive from it.
    """
    _root_unbacked_test(name = name + "_root", size = "small")
    _nested_unbacked_test(name = name + "_nested", size = "small")
    _backed_test(name = name + "_backed", size = "small")
    _no_summary_test(name = name + "_no_summary", size = "small")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_root",
            ":" + name + "_nested",
            ":" + name + "_backed",
            ":" + name + "_no_summary",
        ],
    )
