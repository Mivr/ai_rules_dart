"""Analysis test: every pub Android plugin compiles against one engine target.

The generated `android/BUILD.bazel` of each plugin repository names
`@rules_flutter//flutter:android_plugin_engine` in the `deps` of its
`kt_android_library`. Two stand-in plugin libraries with the deps that
generator renders must resolve to the same engine target. The engine itself
is not analysed (it needs the Android SDK and engine repositories); only the
label each generated library names is compared.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_pub_android_package.bzl", "make_android_subpackage_build_content")

visibility(["//flutter/tests/..."])

_EngineDepsInfo = provider(
    doc = "The labels a plugin library lists in its `deps`.",
    fields = {"labels": "List of label strings."},
)

def _plugin_stub_impl(ctx):
    """Normalise the dep labels the stub was given.

    Args:
        ctx: The rule context.

    Returns:
        The `_EngineDepsInfo` provider.
    """
    return [_EngineDepsInfo(labels = [str(Label(dep)) for dep in ctx.attr.deps])]

android_plugin_stub = rule(
    implementation = _plugin_stub_impl,
    attrs = {"deps": attr.string_list(doc = "Direct dep labels the generated plugin library names.")},
    doc = "Stands in for a generated plugin `kt_android_library`.",
)

def _probe_impl(ctx):
    """Expose both plugin stubs' deps through one provider.

    Args:
        ctx: The rule context.

    Returns:
        The `_EngineDepsInfo` provider holding every plugin's dep labels, prefixed by index.
    """
    return [_EngineDepsInfo(labels = [
        "%d:%s" % (i, label)
        for i, plugin in enumerate(ctx.attr.plugins)
        for label in plugin[_EngineDepsInfo].labels
    ])]

_probe = rule(
    implementation = _probe_impl,
    attrs = {"plugins": attr.label_list(providers = [_EngineDepsInfo], doc = "Plugin stand-ins.")},
    doc = "Aggregates the plugin stand-ins for the analysis test.",
)

def _shared_engine_test_impl(ctx):
    """Both plugins depend on the same engine target.

    Args:
        ctx: The rule context.

    Returns:
        The analysis-test result.
    """
    env = analysistest.begin(ctx)
    labels = analysistest.target_under_test(env)[_EngineDepsInfo].labels
    engine = str(Label("//flutter:android_plugin_engine"))
    asserts.equals(env, ["0:" + engine, "1:" + engine], labels)
    return analysistest.end(env)

_shared_engine_test = analysistest.make(_shared_engine_test_impl)

def _generated_engine_deps(java_package):
    """The `@rules_flutter` deps the generator renders for one plugin.

    Args:
        java_package: The plugin's Android namespace.

    Returns:
        The label strings from the generated `kt_android_library` deps.
    """
    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = java_package,
        extra_maven_labels = ["@rules_android_maven//:androidx_browser_browser"],
    )
    return [
        line.strip().strip(",").strip('"')
        for line in content.splitlines()
        if line.strip().startswith('"@rules_flutter//')
    ]

def android_shared_engine_test_suite(name):
    """Declare the shared-engine analysis test and its fixtures.

    Args:
        name: Name of the test target.
    """
    for plugin in ("a", "b"):
        android_plugin_stub(
            name = "%s_plugin_%s" % (name, plugin),
            deps = _generated_engine_deps("com.example." + plugin),
            tags = ["manual"],
        )
    _probe(
        name = name + "_probe",
        plugins = [":%s_plugin_a" % name, ":%s_plugin_b" % name],
        tags = ["manual"],
    )
    _shared_engine_test(name = name, target_under_test = ":" + name + "_probe")
