"""Analysis tests for `flutter_application(defines_files = [...])`.

Pins that:
- with `defines_files`, a `FlutterDefinesFiles` action is registered with the
  declared files as inputs and produces a flagfile;
- the `FlutterKernelCompile` action takes the flagfile as an input and carries
  `@<flagfile>` on its command line, while secret values from the files stay
  out of the argv;
- the argv ordering is: explicit `-D` defines, then the generated flagfile, then
  the user's `define_flagfiles`;
- without `defines_files`, no `FlutterDefinesFiles` action is registered and the
  compile argv is unchanged from the baseline.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application", "flutter_integration_test")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

visibility(["//flutter/tests/..."])

_PACKAGE = "defines_files_fixture"
_MAIN = "lib/language_version_main.dart"
_JSON_FILE = "_defines_fixture.json"
_ENV_FILE = "_defines_fixture.env"
_USER_FLAGFILE = "_defines_fixture_user.defines"

_JSON_CONTENT = [
    '{"JSON_SECRET": "secret_from_json", "OVERRIDDEN": "from_json"}',
]
_ENV_CONTENT = [
    "ENV_SECRET=secret_from_env",
    "EXTRA_ENV=env_val",
]
_USER_FLAGFILE_CONTENT = [
    "-DUSER_FLAG=user_flagfile_val",
]
_VISIBLE_DEFINE = "EXPLICIT_DEFINE=visible_val"
_OVERRIDDEN_DEFINE = "OVERRIDDEN=explicit_wins"

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

def _defines_files_action(env):
    """The target's FlutterDefinesFiles action."""
    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FlutterDefinesFiles"
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected one FlutterDefinesFiles action, got %s" %
        [action.mnemonic for action in actions],
    )
    return actions[0] if actions else None

def _action_paths(action):
    """The exec paths of the action's declared inputs."""
    return [f.path for f in action.inputs.to_list()] if action else []

def _defines_files_test_impl(ctx):
    """A declared defines_files generates a flagfile and keeps values out of argv."""
    env = analysistest.begin(ctx)
    df_action = _defines_files_action(env)
    kernel_act = _kernel_action(env)

    if df_action:
        df_inputs = _action_paths(df_action)
        asserts.true(
            env,
            any([p.endswith(_JSON_FILE) for p in df_inputs]),
            "expected JSON file in FlutterDefinesFiles inputs, got %s" % df_inputs,
        )
        asserts.true(
            env,
            any([p.endswith(_ENV_FILE) for p in df_inputs]),
            "expected .env file in FlutterDefinesFiles inputs, got %s" % df_inputs,
        )
        df_outputs = [f.path for f in df_action.outputs.to_list()]
        asserts.equals(
            env,
            1,
            len(df_outputs),
            "expected exactly one output from FlutterDefinesFiles, got %s" % df_outputs,
        )
        generated_flagfile = df_outputs[0]
        asserts.true(
            env,
            generated_flagfile.endswith("_defines_files.defines"),
            "expected output to end with _defines_files.defines, got %s" % generated_flagfile,
        )

    if kernel_act and df_action:
        k_inputs = _action_paths(kernel_act)
        generated_flagfile = [f.path for f in df_action.outputs.to_list()][0]
        asserts.true(
            env,
            generated_flagfile in k_inputs,
            "expected generated flagfile %s in kernel inputs, got %s" % (generated_flagfile, k_inputs),
        )
        asserts.true(
            env,
            any([p.endswith(_USER_FLAGFILE) for p in k_inputs]),
            "expected user flagfile in kernel inputs, got %s" % k_inputs,
        )

        argv = kernel_act.argv
        asserts.true(
            env,
            "@" + generated_flagfile in argv,
            "expected @%s in kernel argv, got %s" % (generated_flagfile, argv),
        )

        # File secret values must stay out of the argv
        for secret in ["secret_from_json", "secret_from_env", "env_val", "from_json"]:
            for arg in argv:
                asserts.false(
                    env,
                    secret in arg,
                    "secret value %r leaked into kernel argv %s" % (secret, arg),
                )

        # Explicit defines must be in argv
        asserts.true(
            env,
            "-D" + _VISIBLE_DEFINE in argv,
            "expected -D%s in kernel argv, got %s" % (_VISIBLE_DEFINE, argv),
        )
        asserts.true(
            env,
            "-D" + _OVERRIDDEN_DEFINE in argv,
            "expected -D%s in kernel argv, got %s" % (_OVERRIDDEN_DEFINE, argv),
        )

        # Precedence/ordering check: defines flags < generated flagfile < user define_flagfiles
        gen_arg = "@" + generated_flagfile
        user_arg = [a for a in argv if a.endswith(_USER_FLAGFILE)][0]
        def_arg = "-D" + _VISIBLE_DEFINE
        idx_def = argv.index(def_arg)
        idx_gen = argv.index(gen_arg)
        idx_user = argv.index(user_arg)
        asserts.true(
            env,
            idx_def < idx_gen,
            "defines flag (-D) must appear before generated flagfile, got %s >= %s" % (idx_def, idx_gen),
        )
        asserts.true(
            env,
            idx_gen < idx_user,
            "generated flagfile must appear before user define_flagfiles, got %s >= %s" % (idx_gen, idx_user),
        )

    return analysistest.end(env)

def _no_defines_files_test_impl(ctx):
    """Without defines_files, no action runs and kernel argv has no generated flagfile."""
    env = analysistest.begin(ctx)
    df_actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FlutterDefinesFiles"
    ]
    asserts.equals(
        env,
        0,
        len(df_actions),
        "expected zero FlutterDefinesFiles actions, got %s" % df_actions,
    )

    action = _kernel_action(env)
    argv = action.argv if action else []
    asserts.true(
        env,
        "-D" + _VISIBLE_DEFINE in argv,
        "expected -D%s in kernel argv, got %s" % (_VISIBLE_DEFINE, argv),
    )
    for a in argv:
        asserts.false(
            env,
            "_defines_files.defines" in a,
            "kernel argv should not contain generated flagfile, got %s" % a,
        )

    return analysistest.end(env)

def _android_it_defines_files_test_impl(ctx):
    """Android flutter_integration_test forwards defines_files to its app kernel compile."""
    env = analysistest.begin(ctx)
    df_action = _defines_files_action(env)
    kernel_act = _kernel_action(env)
    if df_action and kernel_act:
        df_inputs = _action_paths(df_action)
        asserts.true(
            env,
            any([p.endswith(_JSON_FILE) for p in df_inputs]),
            "expected JSON file in Android app FlutterDefinesFiles inputs, got %s" % df_inputs,
        )
        generated_flagfile = [f.path for f in df_action.outputs.to_list()][0]
        k_inputs = _action_paths(kernel_act)
        asserts.true(
            env,
            generated_flagfile in k_inputs,
            "expected generated flagfile %s in Android app kernel inputs, got %s" % (generated_flagfile, k_inputs),
        )
        argv = kernel_act.argv
        asserts.true(
            env,
            "@" + generated_flagfile in argv,
            "expected @%s in Android app kernel argv, got %s" % (generated_flagfile, argv),
        )
        for arg in argv:
            asserts.false(
                env,
                "secret_from_json" in arg,
                "secret value leaked into Android app kernel argv %s" % arg,
            )
        asserts.true(
            env,
            argv.index("-D" + _VISIBLE_DEFINE) < argv.index("@" + generated_flagfile),
            "expected explicit define before generated flagfile in Android app kernel argv",
        )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_defines_files_test = analysistest.make(
    _defines_files_test_impl,
    config_settings = _DBG,
)
_no_defines_files_test = analysistest.make(
    _no_defines_files_test_impl,
    config_settings = _DBG,
)
_android_it_defines_files_test = analysistest.make(
    _android_it_defines_files_test_impl,
    config_settings = _DBG,
)

def defines_files_test_suite(name):
    """Fixtures and analysis tests for defines_files.

    Args:
        name: The test suite name.
    """
    write_file(
        name = "_defines_files_fixture_json",
        out = _JSON_FILE,
        content = _JSON_CONTENT,
        tags = ["manual"],
    )
    write_file(
        name = "_defines_files_fixture_env",
        out = _ENV_FILE,
        content = _ENV_CONTENT,
        tags = ["manual"],
    )
    write_file(
        name = "_defines_files_fixture_user_flagfile",
        out = _USER_FLAGFILE,
        content = _USER_FLAGFILE_CONTENT,
        tags = ["manual"],
    )

    flutter_application(
        name = "_defines_files_application",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        defines = [_VISIBLE_DEFINE, _OVERRIDDEN_DEFINE],
        defines_files = [
            ":_defines_files_fixture_json",
            ":_defines_files_fixture_env",
        ],
        define_flagfiles = [":_defines_files_fixture_user_flagfile"],
        tags = ["manual"],
    )

    flutter_application(
        name = "_defines_files_baseline",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        defines = [_VISIBLE_DEFINE],
        tags = ["manual"],
    )

    flutter_integration_test(
        name = "_defines_files_android_it",
        package_name = _PACKAGE,
        platform = "android",
        srcs = [_MAIN],
        defines = [_VISIBLE_DEFINE],
        defines_files = [":_defines_files_fixture_json"],
        deps = ["//flutter/tests/linux_integration_dep:flutter_test_dep"],
        tags = ["manual"],
    )

    flutter_integration_test(
        name = "_defines_files_android_it_baseline",
        package_name = _PACKAGE,
        platform = "android",
        srcs = [_MAIN],
        defines = [_VISIBLE_DEFINE],
        deps = ["//flutter/tests/linux_integration_dep:flutter_test_dep"],
        tags = ["manual"],
    )

    _defines_files_test(
        name = name + "_flagfile_generated_and_ordered",
        size = "small",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_defines_files_application",
    )
    _no_defines_files_test(
        name = name + "_unchanged_without_defines_files",
        size = "small",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_defines_files_baseline",
    )
    _android_it_defines_files_test(
        name = name + "_android_integration_app_forwards_defines_files",
        size = "small",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":___defines_files_android_it_app",
    )
    _no_defines_files_test(
        name = name + "_android_integration_app_unchanged_without_defines_files",
        size = "small",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":___defines_files_android_it_baseline_app",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flagfile_generated_and_ordered",
            ":" + name + "_unchanged_without_defines_files",
            ":" + name + "_android_integration_app_forwards_defines_files",
            ":" + name + "_android_integration_app_unchanged_without_defines_files",
        ],
    )
