"""Isolated configurations for analysis tests over `DartKernel` actions.

A modular `DartKernel` action (a `dart_library` module, or a modular
executable's entry module) declares `unused_inputs_list`
(`dart/private/dart_kernel.bzl`). Once Bazel runs the action, it prunes the
listed files from the in-memory action, and an analysis test that reads
`action.inputs` afterwards sees the pruned set: when the test is analysed
after a build of the same target in the same server, it fails on inputs the
action still declares. The rules are correct; the test reads a value that
execution rewrites.

Every analysis test that asserts on `DartKernel` inputs therefore passes the
settings below as its `analysistest.make` `config_settings`. They set
`//dart/tests:pruned_inputs_isolation`, a build setting no rule reads and no
build or CI job sets. The setting changes nothing about the actions, but it
puts the analysed target in a configuration no normal build ever uses, so the
actions a test inspects are never the ones a build executed: their inputs are
always the declared set, whether or not the same target already built.
"""

_ISOLATION = str(Label("//dart/tests:pruned_inputs_isolation"))

def pruned_inputs_settings(extra_settings = {}):
    """Returns the `config_settings` isolating a test from input pruning.

    Args:
      extra_settings: Further settings the test needs (for example the
        defines a comma test sets); the isolation setting is always added.

    Returns:
      The settings to pass as `analysistest.make` `config_settings`.
    """
    settings = dict(extra_settings)
    settings[_ISOLATION] = True
    return settings
