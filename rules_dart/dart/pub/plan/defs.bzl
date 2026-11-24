"""A test that a shipped pub plan plans exactly the hosted entries of its lock."""

load("//dart:defs.bzl", "dart_test")

def pub_plan_test(name, locks, **kwargs):
    """Checks each plan against its lock (`bazel run @rules_dart//dart/pub/plan -- check`).

    A plan that misses an entry of its lock costs a request in every module
    that uses the lock; one that names an entry the lock does not pin is
    stale. Either fails this test, naming the entry and the command that
    regenerates the plan.

    Args:
      name: The test name.
      locks: Dict of `pubspec.lock` label to the label of its plan file.
      **kwargs: Passed to `dart_test` (`size`, `tags`, ...).
    """
    args = []
    data = []
    for lock in sorted(locks.keys()):
        args.extend(["$(rlocationpath %s)" % lock, "$(rlocationpath %s)" % locks[lock]])
        data.extend([lock, locks[lock]])
    dart_test(
        name = name,
        main = Label("//dart/pub/plan:test/plan_test.dart"),
        args = args,
        data = data,
        deps = [
            Label("//dart/pub/plan:plan_lib"),
            Label("//dart/runfiles"),
            Label("@ext_pub_deps//:test"),
        ],
        size = kwargs.pop("size", "small"),
        **kwargs
    )
