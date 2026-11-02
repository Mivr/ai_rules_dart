"""Direct `rules_testing` test for `dart_format`.

`dart_format` stages the analysis config's options project and hands it to a
runner executable. The test pins what the rule publishes: the executable, the
`DART_FORMAT_CONFIG` environment and `dart_format_config` output group naming
the runner's configuration, and that configuration's content. It also pins the
actions the rule registers: the symlink to the writer tool, and the copy that
stages the options project (its flags, and the options file and copy tool it
reads).
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_format")
load(
    ":truth_helpers.bzl",
    "WINDOWS_ATTR",
    "action_of",
    "exe_extension",
    "expect_executable_symlink",
    "expect_inputs",
)

def _expect_config_file(env, target):
    """Asserts the runner configuration the output group and the environment name."""
    config = env.expect.that_target(target).output_group("dart_format_config")
    config.contains_exactly(["dart/tests/dart_format_direct_subject.format_config.json"])
    env.expect.that_str(target[RunEnvironmentInfo].environment["DART_FORMAT_CONFIG"]).contains(
        "dart/tests/dart_format_direct_subject.format_config.json",
    )
    content = env.expect.that_target(target).action_generating(
        "dart/tests/dart_format_direct_subject.format_config.json",
    ).content()
    for key in ["dart", "root_options", "package_config", "options"]:
        content.contains('"%s"' % key)

def _dart_format_test(env, target):
    """Asserts the providers and the actions of `dart_format`."""
    ext = exe_extension(env)
    subject = env.expect.that_target(target)
    subject.executable().short_path_equals("dart/tests/dart_format_direct_subject" + ext)
    subject.runfiles().contains_at_least_predicates([
        matching.str_endswith("dart/tests/dart_format_direct_subject.format_config.json"),
        matching.str_endswith("dart/private/tools/format_writer" + ext),
    ])
    subject.provider(RunEnvironmentInfo).environment().keys().contains_exactly(["DART_FORMAT_CONFIG"])
    _expect_config_file(env, target)
    expect_executable_symlink(env, target, "*dart/private/tools/format_writer" + ext)
    copy = action_of(env, target, "DartCopyTree")
    copy.argv().contains_at_least(["--workspace", "--file"])
    copy.argv().contains_predicate(matching.str_endswith("dart_format_direct_subject.proj/src"))
    expect_inputs(copy, ["analysis_options.yaml", "*dart/private/tools/copy_tree.dill"])

def dart_format_direct_test_suite(name):
    """Declares the direct test of `dart_format`.

    Args:
      name: Name of the generated `test_suite`. Instantiate it as `dart_format_direct`: the
        test expects the subject at that name.
    """
    dart_format(
        name = name + "_subject",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        attrs = WINDOWS_ATTR,
        impl = _dart_format_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
