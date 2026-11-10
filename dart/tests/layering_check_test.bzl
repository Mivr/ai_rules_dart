"""Analysis tests for the strict-layering check (`dart_import_check_aspect`).

The fixture in `layering_check_fixture/` has `user` depend on `mid`, which
depends on `leaf`, with `user` importing `package:leaf`. The tests pin what the
check's actions read and write, not that they fail: building `:user` is the
failing case, covered by `e2e/layering_check`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartImportCheckInfo", "DartInfo")
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect")

LayeringActionsInfo = provider(
    doc = "The actions registered for a target, as an aspect sees them.",
    fields = {"actions": "list[Action]: `target.actions` after `dart_import_check_aspect` ran."},
)

def _actions_aspect_impl(target, _ctx):
    """Exposes `target.actions` as a provider."""
    return [LayeringActionsInfo(actions = target.actions)]

_actions_aspect = aspect(
    implementation = _actions_aspect_impl,
    requires = [dart_import_check_aspect],
    doc = "Exposes the actions registered on a target, which `analysistest.target_actions` hides from aspects.",
)

def _flag_values(argv, flag):
    """The values that follow each occurrence of `flag` in `argv`."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _check_actions(env):
    """The `DartImportCheck` actions the aspect registered on the target under test."""
    target = analysistest.target_under_test(env)
    return [a for a in target[LayeringActionsInfo].actions if a.mnemonic == "DartImportCheck"]

def _kernel_actions(env):
    """The `DartKernel` actions registered on the target under test."""
    target = analysistest.target_under_test(env)
    return [a for a in target[LayeringActionsInfo].actions if a.mnemonic == "DartKernel"]

def _action_test_impl(ctx):
    """Checks the module compile action's argv and inputs."""
    env = analysistest.begin(ctx)
    actions = _check_actions(env)
    asserts.equals(env, 0, len(actions), "libraries register no DartImportCheck actions of their own")
    kernel_actions = _kernel_actions(env)
    asserts.equals(env, 1, len(kernel_actions), "one DartKernel action per checked library")
    if len(kernel_actions) != 1:
        return analysistest.end(env)
    action = kernel_actions[0]
    argv = action.argv
    direct = _flag_values(argv, "--direct-package")
    own = _flag_values(argv, "--own-package")
    for name in ctx.attr.expect_direct:
        asserts.true(env, name in direct, "argv names %s as a direct package: %s" % (name, argv))
    for name in ctx.attr.expect_absent:
        asserts.true(env, name not in direct, "argv does not name %s as a direct package: %s" % (name, argv))
    asserts.equals(env, 1, len(own), "argv names the target's own package once: %s" % argv)
    asserts.true(env, "--check-imports" in argv, "module compile runs with --check-imports: %s" % argv)
    inputs = [f.short_path for f in action.inputs.to_list()]
    for path in ctx.attr.expect_srcs:
        asserts.true(env, path in inputs, "%s is an input" % path)
    for path in ctx.attr.forbid_srcs:
        asserts.true(env, path not in inputs, "%s, a dependency's source, is not an input" % path)
    tool = [p for p in inputs if "kernel_module" in p]
    asserts.true(env, len(tool) > 0, "the module compile tool is an input: %s" % inputs)
    return analysistest.end(env)

layering_action_test = analysistest.make(
    _action_test_impl,
    attrs = {
        "expect_absent": attr.string_list(doc = "Package names argv must not list as direct."),
        "expect_direct": attr.string_list(doc = "Package names argv must list as direct."),
        "expect_srcs": attr.string_list(doc = "Short paths that must be inputs."),
        "forbid_srcs": attr.string_list(doc = "Short paths that must not be inputs."),
    },
    extra_target_under_test_aspects = [dart_import_check_aspect, _actions_aspect],
)

def _optout_test_impl(ctx):
    """Checks that a target with the feature disabled runs no check."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 0, len(_check_actions(env)), "a target with the feature disabled runs no check")
    kernel_actions = _kernel_actions(env)
    if len(kernel_actions) == 1:
        asserts.true(
            env,
            "--check-imports" not in kernel_actions[0].argv,
            "--check-imports is not passed when opted out: %s" % kernel_actions[0].argv,
        )
    return analysistest.end(env)

layering_optout_test = analysistest.make(
    _optout_test_impl,
    extra_target_under_test_aspects = [dart_import_check_aspect, _actions_aspect],
)

def _probe_impl(ctx):
    """Forwards the stamps the aspect collected on `deps`."""
    stamps = depset(transitive = [dep[DartImportCheckInfo].stamps for dep in ctx.attr.deps])
    return [
        DartImportCheckInfo(stamps = stamps),
        OutputGroupInfo(_validation = stamps),
    ]

layering_probe = rule(
    implementation = _probe_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "Libraries the check aspect is applied to through this attribute.",
            providers = [DartInfo],
            aspects = [dart_import_check_aspect],
        ),
    },
    doc = "Applies `dart_import_check_aspect` through an attribute and forwards the stamps it collects.",
)

def _probe_test_impl(ctx):
    """Checks the probe's stamp count and `_validation` group."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        ctx.attr.expect_stamps,
        len(target[DartImportCheckInfo].stamps.to_list()),
        "one stamp per library in the closure",
    )
    asserts.true(env, len(target[OutputGroupInfo]._validation.to_list()) > 0, "_validation is non-empty")
    return analysistest.end(env)

layering_probe_test = analysistest.make(
    _probe_test_impl,
    attrs = {"expect_stamps": attr.int(doc = "The expected number of stamps.", mandatory = True)},
)

def _binary_test_impl(ctx):
    """Checks an executable's `_validation` group and its own check action."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    validation = target[OutputGroupInfo]._validation.to_list()
    asserts.equals(env, ctx.attr.expect_stamps, len(validation), "the executable's own stamp and one per library")
    own_checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(own_checks), "the executable runs one check over its own sources")
    return analysistest.end(env)

layering_binary_test = analysistest.make(
    _binary_test_impl,
    attrs = {"expect_stamps": attr.int(doc = "The expected number of `_validation` stamps.", mandatory = True)},
)

def _library_no_import_check_test_impl(ctx):
    """Checks that a library with the check on registers no DartImportCheck action of its own."""
    env = analysistest.begin(ctx)
    actions = _check_actions(env)
    asserts.equals(
        env,
        0,
        len(actions),
        "library with layering check on registers no DartImportCheck action of its own",
    )
    return analysistest.end(env)

library_no_import_check_test = analysistest.make(
    _library_no_import_check_test_impl,
    extra_target_under_test_aspects = [dart_import_check_aspect, _actions_aspect],
)
