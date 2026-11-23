"""Analysis tests for `flutter_application(defines_files = [...])`.

Pins that:
- `defines_files` and `define_flagfiles` become one `dart_defines` target,
  `<name>_dart_defines`, whose `FlutterDartDefines` action reads the declared
  files and writes one `.dart_defines` file;
- the `FlutterKernelCompile` action takes that file as an input and carries
  `@<file>` on its command line before the explicit `-D` defines, so those win,
  while secret values from the files stay out of the argv;
- without `defines_files`, no defines file reaches the compile and the argv is
  unchanged from the baseline;
- the Android integration-test app still runs its own `FlutterDefinesFiles`
  action, and its flagfile also comes before the explicit defines.
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
    """The app's compile reads the `dart_defines` output before its own defines, and no value reaches the argv."""
    env = analysistest.begin(ctx)
    kernel_act = _kernel_action(env)
    if kernel_act:
        flagfiles = [p for p in _action_paths(kernel_act) if p.endswith("_dart_defines.dart_defines")]
        asserts.equals(env, 1, len(flagfiles), "expected one dart_defines input, got %s" % flagfiles)
        argv = kernel_act.argv
        for secret in ["secret_from_json", "secret_from_env", "env_val", "from_json", "user_flagfile_val"]:
            for arg in argv:
                asserts.false(env, secret in arg, "secret value %r leaked into kernel argv %s" % (secret, arg))
        for define in [_VISIBLE_DEFINE, _OVERRIDDEN_DEFINE]:
            asserts.true(env, "-D" + define in argv, "expected -D%s in kernel argv, got %s" % (define, argv))
        if flagfiles and "@" + flagfiles[0] in argv:
            asserts.true(
                env,
                argv.index("@" + flagfiles[0]) < argv.index("-D" + _VISIBLE_DEFINE),
                "the defines file must come before the explicit defines, which win",
            )
        else:
            asserts.true(env, False, "expected @<dart_defines> in kernel argv, got %s" % argv)
    return analysistest.end(env)

def _dart_defines_action_test_impl(ctx):
    """The generated `dart_defines` target parses every declared file in one action."""
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterDartDefines"]
    asserts.equals(env, 1, len(actions), "expected one FlutterDartDefines action")
    if actions:
        inputs = _action_paths(actions[0])
        for name in [_JSON_FILE, _ENV_FILE, _USER_FLAGFILE]:
            asserts.true(env, any([p.endswith(name) for p in inputs]), "expected %s in inputs, got %s" % (name, inputs))
        outputs = [f.path for f in actions[0].outputs.to_list()]
        asserts.equals(env, 1, len(outputs), "expected one output, got %s" % outputs)
        asserts.true(env, outputs[0].endswith(".dart_defines"), "unexpected output %s" % outputs)
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
            "_defines_files.defines" in a or a.endswith(".dart_defines"),
            "kernel argv should not contain a defines file, got %s" % a,
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
            argv.index("@" + generated_flagfile) < argv.index("-D" + _VISIBLE_DEFINE),
            "expected the generated flagfile before the explicit define in Android app kernel argv",
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
_dart_defines_action_test = analysistest.make(_dart_defines_action_test_impl)
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
    _dart_defines_action_test(
        name = name + "_dart_defines_parses_once",
        size = "small",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_defines_files_application_dart_defines",
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
            ":" + name + "_dart_defines_parses_once",
            ":" + name + "_unchanged_without_defines_files",
            ":" + name + "_android_integration_app_forwards_defines_files",
            ":" + name + "_android_integration_app_unchanged_without_defines_files",
        ],
    )
