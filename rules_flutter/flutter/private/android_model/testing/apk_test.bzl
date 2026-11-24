"""A test of what a `flutter_android_app` built: the whole APK and its splits."""

load("@rules_java//java:defs.bzl", "java_test")

def _quoted(value):
    """One argument of the test, as `args` wants it: `$` and the shell's characters kept."""
    return "'%s'" % value.replace("$", "$$")

def android_apk_test(
        name,
        app,
        hub = "@android_model//:",
        abi = None,
        splits = [],
        classes = [],
        absent_classes = [],
        entries = [],
        absent_entries = [],
        split_classes = {},
        split_entries = {},
        version_name = None,
        version_code = None,
        signed = True,
        **kwargs):
    """Builds `app`'s APKs and checks them.

    Always checked: the whole APK defines no class twice, holds no class file, stores native
    libraries uncompressed at 16 KB boundaries, and is signed (v2); with `splits`, the splits hold
    the same classes and files as the whole APK and no class twice.

    Args:
      name: test name.
      app: name of the `flutter_android_app` target in this package.
      hub: label prefix of the pin's repository, for aapt2.
      abi: check the APK of this ABI (an app built with `split_per_abi`) instead of the whole one.
      splits: names of the app's splits besides `base` (`app`, `dart`, a project's target name).
      classes: class descriptors the app must define, for example `Lcom/example/Plugin;`.
      absent_classes: class descriptors it must not define.
      entries: APK entries it must hold.
      absent_entries: glob patterns no entry may match.
      split_classes: split name to a class that must be in that split and in no other.
      split_entries: split name to an entry that must be in that split and in no other.
      version_name: the versionName of the manifest.
      version_code: the versionCode of the manifest.
      signed: False for a release whose signing configuration is not the debug one: the build must
        leave it unsigned.
      **kwargs: common test attributes.
    """
    apk = ":%s_apk%s" % (app, ("_" + abi.replace("-", "_")) if abi else "")
    data = [apk, hub + "aapt2"]
    args = ["--apk", "$(rootpath %s)" % apk, "--aapt2", "$(rootpath %saapt2)" % hub]
    for split in (["base"] + splits) if splits else []:
        label = ":%s_base" % app if split == "base" else ":%s_split_%s" % (app, split)
        data.append(label)
        args += ["--split", "%s=$(rootpath %s)" % (split, label)]
    for c in classes:
        args += ["--class", _quoted(c)]
    for c in absent_classes:
        args += ["--no-class", _quoted(c)]
    for e in entries:
        args += ["--entry", e]
    for e in absent_entries:
        args += ["--no-entry", _quoted(e)]
    for split, c in split_classes.items():
        args += ["--split-class", _quoted("%s=%s" % (split, c))]
    for split, e in split_entries.items():
        args += ["--split-entry", "%s=%s" % (split, e)]
    if version_name != None:
        args += ["--version-name", version_name]
    if version_code != None:
        args += ["--version-code", str(version_code)]
    if not signed:
        args += ["--signed", "false"]
    java_test(
        name = name,
        size = kwargs.pop("size", "small"),
        main_class = "rules_flutter.android.testing.ApkCheck",
        use_testrunner = False,
        runtime_deps = [Label("//flutter/private/android_model/testing:apk_check")],
        data = data,
        args = args,
        **kwargs
    )

def android_bundle_test(name, app, entries = [], absent_entries = [], signed = True, **kwargs):
    """Builds `app`'s app bundle and checks it.

    Always checked: the bundle has a `base` module with a manifest, a resource table and dex files,
    and a bundle configuration, and is signed as a jar (or, with `signed = False`, is not).

    Args:
      name: test name.
      app: name of the `flutter_android_app` target in this package.
      entries: entries the bundle must hold, for example `base/lib/arm64-v8a/libapp.so`.
      absent_entries: glob patterns no entry may match.
      signed: False for a release whose signing configuration is not the debug one.
      **kwargs: common test attributes.
    """
    bundle = ":%s_bundle" % app
    args = ["--bundle", "$(rootpath %s)" % bundle]
    for e in entries:
        args += ["--entry", e]
    for e in absent_entries:
        args += ["--no-entry", _quoted(e)]
    if not signed:
        args += ["--signed", "false"]
    java_test(
        name = name,
        size = kwargs.pop("size", "small"),
        main_class = "rules_flutter.android.testing.ApkCheck",
        use_testrunner = False,
        runtime_deps = [Label("//flutter/private/android_model/testing:apk_check")],
        data = [bundle],
        args = args,
        **kwargs
    )

def android_sign_test(name, app, **kwargs):
    """Runs `app`'s sign programs with a key made in the test and checks what they signed.

    For an app whose signing configuration is its own (the build leaves its APKs and its bundle
    unsigned, and `bazel run :<app>_sign` and `:<app>_bundle_sign` sign them): the test makes a key
    store, gives it to both programs in their environment, as a CI job does, and checks that every
    APK has a v2 signature with that key's certificate and that the bundle verifies as a jar signed
    with it.

    Args:
      name: test name.
      app: name of the `flutter_android_app` target in this package.
      **kwargs: common test attributes.
    """
    programs = [":%s_sign" % app, ":%s_bundle_sign" % app]
    java_test(
        name = name,
        size = kwargs.pop("size", "medium"),
        main_class = "rules_flutter.android.testing.SignCheck",
        use_testrunner = False,
        runtime_deps = [Label("//flutter/private/android_model/testing:apk_check")],
        data = programs,
        args = ["--sign", "$(rootpath %s)" % programs[0], "--bundle-sign", "$(rootpath %s)" % programs[1]],
        **kwargs
    )
