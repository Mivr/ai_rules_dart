"""Analysis tests for the `flutter_sdk_kernel_binary` tool kernel action.

Asserts the `FlutterToolKernel` compile mounts only its declared inputs (one
relative staging root, never the exec root or an absolute host path) and runs
with its writable home beside its own output (never the shared `/tmp`).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//flutter/tests/..."])

def _tool_kernel_action(env):
    """The single `FlutterToolKernel` action of the target under test."""
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterToolKernel"
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected one FlutterToolKernel action, got %s" %
        [a.mnemonic for a in analysistest.target_actions(env)],
    )
    return actions[0]

def _filesystem_roots(argv):
    """Every value a `--filesystem-root` flag in `argv` mounts."""
    roots = []
    for i in range(len(argv)):
        if argv[i] == "--filesystem-root" and i + 1 < len(argv):
            roots.append(argv[i + 1])
    return roots

def _sdk_kernel_binary_test_impl(ctx):
    """One staging root, relative; the writable home beside the output."""
    env = analysistest.begin(ctx)
    action = _tool_kernel_action(env)

    roots = _filesystem_roots(action.argv)
    asserts.equals(env, 1, len(roots), "the tool kernel mounts one staging root holding its declared inputs, got %s" % (roots,))
    for root in roots:
        asserts.false(
            env,
            root == "." or root.startswith("/"),
            "no --filesystem-root mounts the exec root or a host path, got %s" % root,
        )

    dills = [f for f in action.outputs.to_list() if f.basename.endswith(".dill")]
    asserts.equals(
        env,
        1,
        len(dills),
        "the tool kernel declares one <name>.dill output, got %s" %
        [f.basename for f in action.outputs.to_list()],
    )
    for key in action.env:
        asserts.false(
            env,
            action.env[key] == "/tmp",
            "action env %s must not point at the shared /tmp" % key,
        )
    for key in ["HOME", "USERPROFILE", "LOCALAPPDATA"]:
        if key in action.env:
            asserts.equals(
                env,
                dills[0].dirname,
                action.env[key],
                "%s is the action's own output directory, got %s" % (key, action.env[key]),
            )
    return analysistest.end(env)

_sdk_kernel_binary_test = analysistest.make(_sdk_kernel_binary_test_impl)

def sdk_kernel_binary_test_suite(name):
    """Analyzes `web_template`'s tool kernel action for hermetic mounts."""
    _sdk_kernel_binary_test(
        name = name + "_tool_kernel",
        target_under_test = "//flutter/private/tools:web_template",
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_tool_kernel"],
    )
