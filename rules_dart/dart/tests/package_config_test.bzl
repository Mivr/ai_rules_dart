"""Tests that binary/test package_config generation sees the rule's own srcs.

A package whose metadata arrives via a `dart_library` façade (srcs = []) but
whose files arrive through the consuming rule's own `srcs` must still get a
`package_config.json` entry — root resolution has to scan dep sources AND the
rule's own inputs. Regression: only `dep_srcs` were scanned, so the façade
package was silently dropped and its `package:` imports failed to resolve.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//dart/..."])

def _package_config_listing(env):
    """Finds the action writing the package config and what it lists.

    A whole-program executable writes its `package_config.json` at analysis,
    so the content is there to read. A modular test's entry module has its
    worker write the config at execution from the `--record` arguments, so
    those are what it lists.

    Returns:
      `(found, listed, detail)`: whether an action writes a package config,
      whether the own-srcs package is in it, and what was read.
    """
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            if not out.basename.endswith(".package_config.json"):
                continue
            if action.content != None:
                return True, '"name": "pc_own_srcs_fixture"' in action.content, action.content
            argv = action.argv or []
            records = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--record"]
            return True, any([r.startswith("pc_own_srcs_fixture|") for r in records]), records
    return False, False, None

def _includes_own_srcs_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    found, listed, detail = _package_config_listing(env)
    asserts.true(env, found, "expected an action writing a package_config.json")
    asserts.true(env, listed, "own-srcs package missing from package_config: %s" % detail)
    return analysistest.end(env)

package_config_own_srcs_test = analysistest.make(_includes_own_srcs_package_test_impl)
