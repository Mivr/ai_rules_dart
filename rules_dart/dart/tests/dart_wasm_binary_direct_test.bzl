"""Direct `rules_testing` test for `dart_wasm_binary`.

The test analyzes one `dart_wasm_binary` and asserts both halves of what the
rule publishes: its providers (the module and the three sibling files a browser
needs as `DefaultInfo` and as output groups, and the `DartAnalyzableInfo` the
`dart_analyze` aspect reads) and the single `DartCompileWeb` action, with the
flags a WebAssembly compile requires and the files it reads. The hermeticity of
the staged project stays with `web_test.bzl`.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//dart:defs.bzl", "dart_wasm_binary")
load("//dart:providers.bzl", "DartAnalyzableInfo")
load(":truth_helpers.bzl", "action_of", "expect_default_outputs", "expect_inputs", "provider_of")

visibility(["//dart/..."])

_OUTPUT_DIR = "dart/tests/"
_OUTPUT_GROUPS = {
    "mjs": ".mjs",
    "support_js": ".support.js",
    "source_map": ".wasm.map",
}

def _expect_outputs(env, target, stem):
    """Asserts the module and its three siblings, as default outputs and output groups."""
    expect_default_outputs(
        env,
        target,
        [_OUTPUT_DIR + stem + ".wasm"] + [_OUTPUT_DIR + stem + ext for ext in _OUTPUT_GROUPS.values()],
    )
    for group, ext in _OUTPUT_GROUPS.items():
        env.expect.that_target(target).output_group(group).contains_exactly([_OUTPUT_DIR + stem + ext])

def _expect_compile_flags(action):
    """Asserts the arguments that make the compile a WebAssembly one under the staged root."""
    action.argv().contains_at_least([
        "compile",
        "wasm",
        "-o",
        "-Dbanner=hello",
        "-O2",
        "-E--multi-root-scheme=org-dartlang-root",
    ])
    action.contains_flag_values([("--packages", "org-dartlang-root:///.dart_tool/package_config.json")])

def _dart_wasm_binary_test(env, target):
    """Asserts the providers and the `DartCompileWeb` action of `dart_wasm_binary`."""
    _expect_outputs(env, target, "dart_wasm_binary_direct_subject")
    analyzable = provider_of(env, target, DartAnalyzableInfo, "DartAnalyzableInfo", {"srcs": subjects.depset_file})
    analyzable.srcs().contains("dart/tests/bin/direct_main.dart")
    action = action_of(env, target, "DartCompileWeb")
    _expect_compile_flags(action)
    expect_inputs(action, ["*dart/tests/bin/direct_main.dart", "*bin/dart", "*web_compile_runner*"])

def dart_wasm_binary_direct_test_suite(name):
    """Declares the direct test of `dart_wasm_binary`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_wasm_binary(
        name = name + "_subject",
        dart_compile_flags = ["-O2"],
        defines = ["banner=hello"],
        main = ":bin/direct_main.dart",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_wasm_binary_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
