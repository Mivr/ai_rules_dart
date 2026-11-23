"""Analysis tests for `flutter_application(define_flagfiles = [...])`.

A define flagfile keeps a `-Dname=value` value out of the kernel action's
command line and therefore out of `bazel aquery`, the BEP and a remote cache's
stored action, while the compiler still receives the value when the guard
expands the file. These tests pin both halves of that contract:

- with a declared flagfile the `FlutterKernelCompile` argv contains `@<path>`
  and none of the file's `-D` lines, and the file is an action input;
- without one the argv is the base one: the ordinary `-D` flags are still
  there and no flagfile argument appears.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

visibility(["//flutter/tests/..."])

_PACKAGE = "define_flagfiles_fixture"
_MAIN = "lib/language_version_main.dart"
_FLAGFILE = "_define_flagfiles_secret.defines"
_SECRET_DEFINES = [
    "-DAPI_KEY=flagfile-secret",
    "-DSECOND=flagfile-two",
]
_VISIBLE_DEFINE = "VISIBLE=attr-value"
_BASE_DEFINE = "BASE=attr-value"

def _kernel_action(env):
    """The target's one whole-program kernel compile action."""
    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected one FlutterKernelCompile, got %s" %
        [action.mnemonic for action in actions],
    )
    return actions[0] if actions else None

def _action_paths(action):
    """The exec paths of the action's declared inputs."""
    return [f.path for f in action.inputs.to_list()] if action else []

def _flagfile_inputs(action):
    """The action inputs whose basename is the generated flagfile."""
    return [p for p in _action_paths(action) if p.endswith(_FLAGFILE)]

def _flagfile_expands_test_impl(ctx):
    """A declared flagfile is an input and its values stay out of argv."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []
    flagfiles = _flagfile_inputs(action)
    asserts.equals(
        env,
        1,
        len(flagfiles),
        "expected the flagfile once in the action inputs, got %s" % flagfiles,
    )
    if flagfiles:
        asserts.true(
            env,
            "@" + flagfiles[0] in argv,
            "expected @%s in the kernel argv, got %s" % (flagfiles[0], argv),
        )
    asserts.true(
        env,
        "-D" + _VISIBLE_DEFINE in argv,
        "expected the ordinary attribute define in argv, got %s" % argv,
    )
    for line in ctx.attr.secret_defines:
        asserts.true(
            env,
            line not in argv,
            "the flagfile define %s must stay out of argv, got %s" %
            (line, argv),
        )
    return analysistest.end(env)

def _no_flagfiles_test_impl(ctx):
    """Without the attribute the base argv is unchanged."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []
    asserts.true(
        env,
        "-D" + _BASE_DEFINE in argv,
        "expected the ordinary attribute define in argv, got %s" % argv,
    )
    asserts.equals(
        env,
        [],
        [a for a in argv if a.startswith("@")],
        "a target without define_flagfiles must pass no flagfile",
    )
    asserts.equals(
        env,
        [],
        [p for p in _action_paths(action) if p.endswith(_FLAGFILE)],
        "a target without define_flagfiles must declare no flagfile input",
    )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_flagfile_test = analysistest.make(
    _flagfile_expands_test_impl,
    attrs = {"secret_defines": attr.string_list(mandatory = True)},
    config_settings = _DBG,
)
_no_flagfiles_test = analysistest.make(
    _no_flagfiles_test_impl,
    config_settings = _DBG,
)

def define_flagfiles_test_suite(name):
    """Fixtures and analysis tests for define flagfiles.

    Args:
        name: The test suite name.
    """
    write_file(
        name = "_define_flagfiles_secret_file",
        out = _FLAGFILE,
        content = _SECRET_DEFINES,
        tags = ["manual"],
    )
    flutter_application(
        name = "_define_flagfiles_application",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        defines = [_VISIBLE_DEFINE],
        define_flagfiles = [":_define_flagfiles_secret_file"],
        tags = ["manual"],
    )
    flutter_application(
        name = "_define_flagfiles_baseline",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        defines = [_BASE_DEFINE],
        tags = ["manual"],
    )

    _flagfile_test(
        name = name + "_flagfile_expands",
        target_under_test = ":_define_flagfiles_application",
        secret_defines = _SECRET_DEFINES,
        target_compatible_with = HOST_COMPATIBLE,
    )
    _no_flagfiles_test(
        name = name + "_unchanged_without_flagfiles",
        target_under_test = ":_define_flagfiles_baseline",
        target_compatible_with = HOST_COMPATIBLE,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flagfile_expands",
            ":" + name + "_unchanged_without_flagfiles",
        ],
    )
