"""Analysis test for `flutter_android_aab`.

The rule builds on rules_android 0.8.0's public `android_application` macro:
the wrapped target emits `<name>_unsigned.aab` through one `BuildBundle`
action (`bundletool build-bundle`). An input of that action is rules_android's
pinned bundletool deploy jar (`tools/android/bundletool_deploy.jar`, the deploy
jar of the `tools/android:bundletool` `java_binary`). The test names the
output, the mnemonic and the jar so that a rules_android bump that renames any
of them fails loudly.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility("private")

def _aab_build_bundle_impl(ctx):
    """Asserts one `BuildBundle` action emitting `unsigned_aab` with the bundletool deploy jar as input."""
    env = analysistest.begin(ctx)
    bundle_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "BuildBundle"]
    asserts.equals(env, 1, len(bundle_actions))
    action = bundle_actions[0]
    asserts.equals(env, ["build-bundle"], [a for a in action.argv if a == "build-bundle"])
    asserts.equals(
        env,
        [ctx.attr.unsigned_aab],
        [o.basename for o in action.outputs.to_list()],
    )

    # `_java.run` launches `java -jar`, so the bundletool is an input (the
    # deploy jar of rules_android's `java_binary`), not argv[0]. No host tool
    # path appears among the inputs.
    input_paths = [i.path for i in action.inputs.to_list()]
    asserts.true(
        env,
        [
            p
            for p in input_paths
            if "/external/rules_android+/" in p and p.endswith("/tools/android/bundletool_deploy.jar")
        ],
        "no pinned bundletool jar among the BuildBundle inputs: %s" % input_paths,
    )
    asserts.equals(env, [], [p for p in input_paths if p.startswith("/")])
    return analysistest.end(env)

aab_build_bundle_test = analysistest.make(
    _aab_build_bundle_impl,
    attrs = {
        "unsigned_aab": attr.string(
            doc = "Expected `<name>_unsigned.aab` output basename of `BuildBundle`.",
            mandatory = True,
        ),
    },
    doc = "Checks the `BuildBundle` action registered by `flutter_android_aab`.",
)
