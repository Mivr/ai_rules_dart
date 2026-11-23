"""Android Maven inputs of a `flutter.pub` path spoke.

A path plugin runs the same spoke generator as a hosted one, so its
`android/build.gradle*` must reach the same two Maven attributes: a mapped
coordinate becomes the mapped label, an ignored coordinate is left out, and
an unmapped one still fails the fetch with the hosted rule's message. The
unmapped case is an analysis probe, because a `fail()` cannot be caught from
a `unittest`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:flutter_pub_maven.bzl", "path_spoke_maven_inputs")
load("//flutter/private:gradle_plugin.bzl", "resolve_plugin_maven_deps")

visibility(["//flutter/tests/..."])

def _path_maven_ctx(mapping, ignore):
    """Fake path-spoke context carrying the two Android Maven attributes.

    `resolve_plugin_maven_deps` reads only `attrs` and builds a package
    reader from the context; these build texts have no `apply from:`, so the
    reader is never called and no path/read methods are needed.
    """
    return struct(
        attr = struct(
            package_name = "dirlink_plugin",
            android_maven_deps = mapping,
            android_maven_ignore = ignore,
        ),
    )

_BUILD_FILE = "android/build.gradle"
_KOTLIN_BUILD_FILE = "android/build.gradle.kts"

_MAPPED_CONTENT = """\
dependencies {
    implementation 'com.example:ignored:1.0'
    implementation 'com.example:mapped:2.0'
}
"""

_KOTLIN_MAPPED_CONTENT = """\
dependencies {
    implementation("com.example:ignored:1.0")
    implementation("com.example:mapped:2.0")
}
"""

_BUILTIN_CONTENT = """\
dependencies {
    implementation 'androidx.annotation:annotation:1.9.1'
}
"""

_UNMAPPED_CONTENT = """\
dependencies {
    implementation 'com.example:unmapped:1.0'
}
"""

def _path_maven_inputs_test_impl(ctx):
    """A path spoke translates its Gradle deps exactly as the hosted rule does.

    The ignored coordinate is omitted, the mapped one becomes its label in
    both Groovy and Kotlin DSL, and the built-in table still applies.
    """
    env = unittest.begin(ctx)
    inputs = path_spoke_maven_inputs(struct(
        android_maven_deps = {"com.example:mapped": "@rules_android_maven//:com_example_mapped"},
        android_maven_ignore = ["com.example:ignored"],
    ))
    asserts.equals(
        env,
        ["@rules_android_maven//:com_example_mapped"],
        resolve_plugin_maven_deps(
            _path_maven_ctx(inputs.deps, inputs.ignore),
            _BUILD_FILE,
            _MAPPED_CONTENT,
        ),
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:com_example_mapped"],
        resolve_plugin_maven_deps(
            _path_maven_ctx(inputs.deps, inputs.ignore),
            _KOTLIN_BUILD_FILE,
            _KOTLIN_MAPPED_CONTENT,
        ),
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_annotation_annotation"],
        resolve_plugin_maven_deps(
            _path_maven_ctx({}, []),
            _BUILD_FILE,
            _BUILTIN_CONTENT,
        ),
    )
    return unittest.end(env)

_path_maven_inputs_test = unittest.make(_path_maven_inputs_test_impl)

def _unmapped_probe_impl(_ctx):
    """Analysis probe: a path spoke whose Gradle build names an unmapped coordinate."""
    resolve_plugin_maven_deps(_path_maven_ctx({}, []), _BUILD_FILE, _UNMAPPED_CONTENT)
    return []

_unmapped_probe = rule(
    implementation = _unmapped_probe_impl,
    doc = "Analysis probe for the unmapped-coordinate refusal of a path spoke.",
)

def _unmapped_refusal_test_impl(ctx):
    """The unmapped coordinate fails naming package, build file and coordinate."""
    env = analysistest.begin(ctx)
    for expected in [
        "dirlink_plugin",
        _BUILD_FILE,
        "com.example:unmapped",
        "android_maven_deps",
        "android_maven_ignore",
    ]:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_unmapped_refusal_test = analysistest.make(
    _unmapped_refusal_test_impl,
    expect_failure = True,
)

def path_android_maven_test_suite(name):
    """Declares the path-spoke Android Maven unit and refusal tests.

    Args:
        name: Test suite name.
    """
    _unmapped_probe(
        name = name + "_probe",
        tags = ["manual"],
    )
    _path_maven_inputs_test(name = name + "_inputs")
    _unmapped_refusal_test(
        name = name + "_refusal",
        target_under_test = ":" + name + "_probe",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_inputs",
            ":" + name + "_refusal",
        ],
    )
