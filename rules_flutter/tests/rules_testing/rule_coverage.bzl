"""Shared `rules_testing` assertions for per-rule analysis tests.

Every public rule and macro has a direct analysis test whose subject is that
rule or macro: a test that a provider field or an action disappeared fails, so
`bazel test //...` cannot stay green while a rule loses one. The assertions
the tests share live here, so each test states only what its rule documents.

A rule that registers no action of its own carries a
`# rule_test_coverage: no-actions` marker above its definition; its test calls
`expect_no_actions`, so the marker cannot outlive the fact it records.
"""

load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "TestingAspectInfo")

visibility(["//tests/..."])

def expect_action(env, target, mnemonic, args = [], inputs = [], output = None):
    """Asserts `target` registers a `mnemonic` action carrying `args` and `inputs`.

    Args:
        env: The `rules_testing` test environment.
        target: The target under test.
        mnemonic: The mnemonic of the action the rule documents.
        args: Arguments the action's argv must contain, each an exact element.
        inputs: Basenames of files the action's inputs must contain.
        output: Optional basename of an output file to distinguish actions.

    Returns:
        The `rules_testing` action subject, for further assertions.
    """
    matching_actions = [a for a in target[TestingAspectInfo].actions if a.mnemonic == mnemonic]
    if output:
        matching_actions = [
            a
            for a in matching_actions
            if any([out.basename == output or out.short_path == output for out in a.outputs.to_list()])
        ]
    if not matching_actions:
        fail("No action with mnemonic '%s' found on %s" % (mnemonic, target.label))
    action = env.expect.that_action(matching_actions[0])
    argv = action.argv()
    for arg in args:
        argv.contains(arg)
    for basename in inputs:
        action.inputs().contains_predicate(matching.file_basename_equals(basename))
    return action

def expect_argv_suffixes(action, suffixes):
    """Asserts an action's argv has an element ending in each of `suffixes`.

    For arguments that carry a configuration-dependent output path, where only
    the tail of the path is the rule's contract.

    Args:
        action: A `rules_testing` action subject, from `expect_action`.
        suffixes: The required argument suffixes.
    """
    argv = action.argv()
    for suffix in suffixes:
        argv.contains_predicate(matching.str_endswith(suffix))

def expect_no_actions(env, target):
    """Asserts `target` registers no action of its own.

    The proof behind a `# rule_test_coverage: no-actions` marker: the rule
    only forwards or assembles providers, so its test asserts those instead.

    Args:
        env: The `rules_testing` test environment.
        target: The target under test.
    """
    actions = target[TestingAspectInfo].actions if TestingAspectInfo in target else []
    env.expect.that_collection(
        [action.mnemonic for action in actions],
        expr = "actions of %s" % target.label,
    ).contains_exactly([])

def expect_default_outputs(env, target, basenames):
    """Asserts `target`'s `DefaultInfo.files` holds a file named each of `basenames`.

    Args:
        env: The `rules_testing` test environment.
        target: The target under test.
        basenames: The required output basenames.
    """
    outputs = env.expect.that_target(target).default_outputs()
    for basename in basenames:
        outputs.contains_predicate(matching.file_basename_equals(basename))
