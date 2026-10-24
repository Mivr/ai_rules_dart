"""Analysis tests for the `dart_js_binary` declared outputs.

`dart compile js` writes `<name>.js`, `<name>.js.map` and `<name>.js.deps`
next to the output. The map must be a declared output in the `source_map`
output group (as `dart_wasm_binary` does), unless `dart_compile_flags` carries
`--no-source-maps`; the `.deps` file carries absolute `file:` paths into the
exec root and the SDK, so it is never a declared output — the web compile
runner removes it before it exits.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_js_binary")

def _web_actions(env):
    return [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartCompileWeb"
    ]

def _js_map_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    stem = target.label.name + ".js"
    files = [f.basename for f in target[DefaultInfo].files.to_list()]
    asserts.true(env, stem in files, "%s is a declared output: %s" % (stem, files))

    groups = target[OutputGroupInfo]
    source_map = getattr(groups, "source_map", None)
    asserts.true(env, source_map != None, "js declares a source_map output group")
    asserts.equals(
        env,
        [stem + ".map"],
        [f.basename for f in source_map.to_list()],
        "the source_map group holds <name>.js.map",
    )

    actions = _web_actions(env)
    asserts.equals(env, 1, len(actions), "one web compile action")
    outputs = [f.basename for f in actions[0].outputs.to_list()]
    asserts.true(env, stem + ".map" in outputs, "the map is an action output: %s" % outputs)
    asserts.false(
        env,
        any([n.endswith(".deps") for n in outputs]),
        "the .deps sidecar is never a declared output: %s" % outputs,
    )
    return analysistest.end(env)

def _js_no_map_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(
        env,
        getattr(target[OutputGroupInfo], "source_map", None) == None,
        "--no-source-maps declares no source_map group",
    )
    actions = _web_actions(env)
    asserts.equals(env, 1, len(actions), "one web compile action")
    outputs = [f.basename for f in actions[0].outputs.to_list()]
    asserts.false(
        env,
        any([n.endswith(".map") or n.endswith(".deps") for n in outputs]),
        "no map or deps among the action outputs: %s" % outputs,
    )
    return analysistest.end(env)

_js_map_test = analysistest.make(_js_map_test_impl)
_js_no_map_test = analysistest.make(_js_no_map_test_impl)

def lows_b_b_suite(name):
    """Declares the web output tests with and without `--no-source-maps`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_js_binary(
        name = name + "_js",
        main = "main.dart",
        tags = ["manual"],
    )
    dart_js_binary(
        name = name + "_js_no_map",
        main = "main.dart",
        dart_compile_flags = ["--no-source-maps"],
        tags = ["manual"],
    )
    _js_map_test(
        name = name + "_js_map_test",
        target_under_test = ":" + name + "_js",
        size = "small",
    )
    _js_no_map_test(
        name = name + "_js_no_map_test",
        target_under_test = ":" + name + "_js_no_map",
        size = "small",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_js_map_test",
            ":" + name + "_js_no_map_test",
        ],
    )
