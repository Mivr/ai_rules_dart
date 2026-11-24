"""Which hub's packages an app, test or web app bundles with when `pub_packages` is unset.

The project's lock first: the hub whose lock is in the target's package, then
the one in the nearest enclosing package (a pub workspace member under its
root's lock); then the hub of the first dependency from one. Twin hubs of
one lock give the first declared (the index holds only that one); a package
holding two different locks gives none, so the first dependency decides.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_bundle.bzl", "hub_packages_of_deps", "hub_packages_of_package")

visibility(["//flutter/tests/..."])

_ROOT = Label("@@root_hub//packages")
_APP = Label("@@app_hub//packages")
_WORKSPACE = Label("@@workspace_hub//packages")

_BY_PACKAGE = {
    "": _ROOT,
    "apps/app": _APP,
    "workspace": _WORKSPACE,
    "two_locks": None,
}

def _same_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _APP, hub_packages_of_package(_BY_PACKAGE, "apps/app"), "the lock in the target's own package")
    asserts.equals(env, _ROOT, hub_packages_of_package(_BY_PACKAGE, ""), "the lock of the root package, for a target there")
    return unittest.end(env)

def _enclosing_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _WORKSPACE, hub_packages_of_package(_BY_PACKAGE, "workspace/packages/member"), "the nearest enclosing package's lock")
    asserts.equals(env, _APP, hub_packages_of_package(_BY_PACKAGE, "apps/app/sub"), "the nearest, not the root's")
    asserts.equals(env, _ROOT, hub_packages_of_package(_BY_PACKAGE, "apps/other"), "up to the root package's lock")
    asserts.equals(env, None, hub_packages_of_package({"apps/app": _APP}, "tools"), "no lock on the way")
    asserts.equals(env, None, hub_packages_of_package(_BY_PACKAGE, "two_locks/sub"), "two different locks: the first dependency decides")
    return unittest.end(env)

def _first_dependency_test_impl(ctx):
    env = unittest.begin(ctx)
    hubs = {"app_hub": _APP, "root_hub": _ROOT}
    deps = [Label("//flutter:defs.bzl"), Label("@@app_hub//:flutter"), Label("@@root_hub//:flutter")]
    asserts.equals(env, _APP, hub_packages_of_deps(hubs, deps), "the hub of the first dependency from one")
    asserts.equals(env, None, hub_packages_of_deps(hubs, [Label("//flutter:defs.bzl")]), "no dependency from a hub")
    return unittest.end(env)

_same_package_test = unittest.make(_same_package_test_impl)
_enclosing_package_test = unittest.make(_enclosing_package_test_impl)
_first_dependency_test = unittest.make(_first_dependency_test_impl)

def pub_packages_default_test_suite(name):
    """The three lookups of the `pub_packages` default.

    Args:
        name: The test suite name.
    """
    unittest.suite(
        name,
        _same_package_test,
        _enclosing_package_test,
        _first_dependency_test,
    )
