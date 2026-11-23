"""Analysis tests: a `dart_test` writes its coverage map only under `bazel coverage`.

With coverage off the test registers no coverage-map action and ships no map. With
coverage on, one action maps the test's whole source closure, and reads it lazily.
`coverage_map_of` builds a `dart_test` with coverage on and exposes its map, so an
execution test can compare the written JSON.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//dart/..."])

_MAP_SUFFIX = ".coverage_map.json"

def _map_outputs(target):
    """The coverage-map Files among the outputs of the actions of `target`."""
    return [
        f
        for action in target.actions
        for f in action.outputs.to_list()
        if f.basename.endswith(_MAP_SUFFIX)
    ]

def _coverage_off_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.false(env, "DartCoverageMap" in mnemonics, "a coverage-map action is registered: %s" % mnemonics)
    asserts.equals(env, [], _map_outputs(struct(actions = analysistest.target_actions(env))))
    runfiles = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.equals(env, [], [p for p in runfiles if p.endswith(_MAP_SUFFIX)])
    asserts.false(
        env,
        "RULES_DART_COVERAGE_MAP" in target[RunEnvironmentInfo].environment,
        "the launcher is told of a coverage map",
    )
    return analysistest.end(env)

coverage_off_test = analysistest.make(
    _coverage_off_test_impl,
    doc = "A `dart_test` built without coverage has no coverage map.",
)

def _coverage_on_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartCoverageMap"]
    asserts.equals(env, 1, len(actions))
    if len(actions) != 1:
        return analysistest.end(env)
    inputs = [f.short_path for f in actions[0].inputs.to_list()]
    for want in ctx.attr.expected_inputs:
        asserts.true(env, want in inputs, "%s is not an input of the map action: %s" % (want, inputs))
    outputs = [f.basename for f in actions[0].outputs.to_list()]
    asserts.equals(env, [ctx.attr.expected_output], outputs)
    runfiles = [f.basename for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(env, ctx.attr.expected_output in runfiles, "the map is not in the runfiles")
    return analysistest.end(env)

coverage_on_test = analysistest.make(
    _coverage_on_test_impl,
    config_settings = {
        "//command_line_option:collect_code_coverage": True,
    },
    attrs = {
        "expected_inputs": attr.string_list(
            doc = "Short paths of every source of the closure.",
            mandatory = True,
        ),
        "expected_output": attr.string(
            doc = "Basename of the map the action writes.",
            mandatory = True,
        ),
    },
    doc = "A `dart_test` built with coverage maps every source of its closure in one action.",
)

def _coverage_transition_impl(settings, attr):
    _ = settings, attr
    return {"//command_line_option:collect_code_coverage": True}

_coverage_transition = transition(
    implementation = _coverage_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:collect_code_coverage"],
)

def _coverage_map_of_impl(ctx):
    runfiles = ctx.attr.test[0][DefaultInfo].default_runfiles.files.to_list()
    maps = [f for f in runfiles if f.basename.endswith(_MAP_SUFFIX)]
    if len(maps) != 1:
        fail("%s: expected one coverage map in the runfiles of %s, got %s" % (ctx.label, ctx.attr.test[0].label, maps))
    return [DefaultInfo(files = depset(maps), runfiles = ctx.runfiles(files = maps))]

coverage_map_of = rule(
    implementation = _coverage_map_of_impl,
    doc = "The coverage map of a `dart_test` built with coverage on.",
    attrs = {
        "test": attr.label(
            doc = "The `dart_test`.",
            mandatory = True,
            cfg = _coverage_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
