"""The pin step of the Android model as a runnable target."""

load("@rules_java//java:defs.bzl", "java_binary")

def flutter_android_pin(name = "android_pin", out = "android_model.json", variants = [], gradle_fallback = [], **kwargs):
    """`bazel run //:android_pin`: Gradle writes the app's Android model, once.

    Call it in the BUILD file beside the app's `pubspec.yaml`. Running it executes the app's own Gradle
    wrapper (`android/gradlew`) with an init script that dumps the model of the app and of every plugin
    project, with the resolved Maven graph and hashes, into `out`. Check that file in and name it in
    `android_model.pin(model = ...)`. Run it again when the lock, a Gradle file or the plugin set
    changes; a build with a stale pin fails and says so.

    It needs what a stock Flutter Android build needs (a JDK, the Android SDK, `flutter pub get` done);
    a build needs none of that. `bazel run //:android_pin -- --check` fails when the file is not what
    Gradle gives now, without writing it.

    Args:
      name: target name; `android_pin` is what error messages name.
      out: the pin file, relative to this package.
      variants: app variants to record, for example `["debug", "devDebug"]`. By default every variant
        of the `debug` build type.
      gradle_fallback: Gradle paths of plugin projects the model cannot express (a Gradle plugin that
        generates code, for example); they are recorded as built by Gradle itself.
      **kwargs: common attributes (`tags`, `visibility`).
    """
    init = Label("//flutter/private/android_model/tools:model.init.gradle")
    args = ["--app", native.package_name() or ".", "--out", out, "--init", "$(rootpath %s)" % init]
    if variants:
        args += ["--variants", ",".join(variants)]
    if gradle_fallback:
        args += ["--fallback", ",".join(gradle_fallback)]
    java_binary(
        name = name,
        main_class = "rules_flutter.android.Pin",
        runtime_deps = [Label("//flutter/private/android_model/tools:pin_lib")],
        data = [init],
        args = args,
        **kwargs
    )
