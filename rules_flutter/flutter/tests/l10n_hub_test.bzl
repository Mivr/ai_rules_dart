"""Which hub's packages a project's generated localizations import.

A project's lock can have several `flutter.pub` hubs (an iOS plugin mode's
twins). The first one declared is the project's default, as for
`PUB_HUBS`; a target whose `deps` come from another of them gets a library
of the generated files over that hub's packages, so its closure holds one
copy of `flutter`, `flutter_localizations` and `intl`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_gen_l10n.bzl", "l10n_library_of")
load("//flutter/private:flutter_l10n_repo.bzl", "add_project_hub")

visibility(["//flutter/tests/..."])

def _hub(name):
    return struct(name = name, packages = ["flutter", "intl"])

def _first_declared_test_impl(ctx):
    """Two hubs on one lock, declared in either order: the first declared is the default."""
    env = unittest.begin(ctx)
    for order in (["deps", "deps_pods_wrong"], ["deps_pods_wrong", "deps"]):
        hubs = {}
        for name in order:
            add_project_hub(hubs, "", _hub(name))
        add_project_hub(hubs, "", _hub(order[0]))
        asserts.equals(env, order, [h.name for h in hubs[""]], "declaration order, each hub once")
    return unittest.end(env)

def _flutter(repo):
    return Label("@@%s//:flutter" % repo)

# Two hubs of one lock, in the index's shape: (canonical repo, deps).
_PROJECT = struct(hubs = [
    ("hub_b", [_flutter("hub_b")]),
    ("hub_a", [_flutter("hub_a")]),
])

def _target_hub_test_impl(ctx):
    """A target takes the library over the hub its own `deps` come from."""
    env = unittest.begin(ctx)
    asserts.equals(env, ("_l10n", [_flutter("hub_b")]), l10n_library_of(_PROJECT, [_flutter("hub_b")]))
    asserts.equals(env, ("_l10n_1", [_flutter("hub_a")]), l10n_library_of(_PROJECT, [Label("//flutter:defs.bzl"), _flutter("hub_a")]))
    asserts.equals(env, ("_l10n", [_flutter("hub_b")]), l10n_library_of(_PROJECT, [Label("//flutter:defs.bzl")]), "no hub in deps: the first declared")
    asserts.equals(env, ("_l10n", [_flutter("hub_b")]), l10n_library_of(_PROJECT, []), "a select(): the first declared")
    return unittest.end(env)

_first_declared_test = unittest.make(_first_declared_test_impl)
_target_hub_test = unittest.make(_target_hub_test_impl)

def l10n_hub_test_suite(name):
    """Tests the hub choice of the generated localizations.

    Args:
        name: The test suite name.
    """
    unittest.suite(name, _first_declared_test, _target_hub_test)
