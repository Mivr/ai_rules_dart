"""The `flutter_android_engine` macro and the AndroidX deps it exports.

Lives under `flutter/private/` so the private layer
(`flutter_integration_test.bzl`) can instantiate the engine without loading
upward from the public `//flutter:android.bzl` facade, which re-exports it.
"""

load("@rules_android//android:rules.bzl", _android_library = "android_library")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")

visibility(["//flutter/..."])

# AndroidX deps of flutter.jar, mirroring the dependency list of Flutter's
# official io.flutter:flutter_embedding_* Maven POM (the deps every
# Gradle-built Flutter app ships): lifecycle for FlutterActivity's
# LifecycleRegistry, window/window-java for foldable display features, core
# for ContextCompat/ViewCompat/input, tracing for the engine's TraceSection,
# fragment for FlutterFragment(Activity), exifinterface for image decoding,
# and relinker for engine .so loading. The POM's lifecycle-common-java8 and
# lifecycle-process entries are omitted: at the lifecycle version pinned here
# their classes live in lifecycle-common, and the embedding never references
# lifecycle-process types.
#
# `flutter_android_engine` *exports* these: the POM declares them at compile
# scope, so in Gradle builds everything that compiles against the embedding
# AAR — runner sources, the plugin registrant, and every Flutter plugin —
# sees them on its compile classpath transitively. Exporting reproduces
# that contract. It adds nothing to the APK that the engine target wasn't
# already carrying at runtime.
_ANDROIDX_EMBEDDING_DEPS = [
    "@rules_android_maven//:androidx_annotation_annotation",
    "@rules_android_maven//:androidx_core_core",
    "@rules_android_maven//:androidx_exifinterface_exifinterface",
    "@rules_android_maven//:androidx_fragment_fragment",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "@rules_android_maven//:androidx_tracing_tracing",
    "@rules_android_maven//:androidx_window_window",
    "@rules_android_maven//:androidx_window_window_java",
    "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
]

# rule_test_coverage: no-actions
def flutter_android_engine(name, android_abi = "arm64", neverlink = False, **kwargs):
    """Imports the Flutter engine (flutter.jar) as a java_import target.

    Auto-selects debug or release engine based on Bazel compilation mode:
    - Debug (-c dbg): JIT engine for emulator/iterative development.
    - Release (-c opt / default): AOT engine for production.

    The engine's native libraries are stripped with the NDK's `llvm-strip
    --strip-unneeded`, as a Gradle build strips them, so the Android NDK
    C++ toolchain must be registered (see the README's Android section).

    A plugin library compiles against the engine but must not package it:
    the app's own engine, of the app's ABI, is the one that ships. Give a
    plugin a `neverlink = True` engine, as Gradle gives a plugin the
    embedding with `compileOnly`. A linked one puts a second engine in the
    APK, which for an x64 app is an arm64 `libflutter.so` that makes Android
    install the app as arm64 and crash at launch.

    Args:
        name: Target name. Add to android_binary deps.
        android_abi: Engine ABI — "arm64" (default) or "x64".
        neverlink: Compile against the engine without packaging it. For
            `flutter_android_plugin_library(flutter_engine = ...)`; the
            engine in the app's `android_binary` deps leaves it False.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    # Map short ABI names to repo names.
    abi_to_repo = {
        "arm64": "flutter_android_engine_arm64",
        "x64": "flutter_android_engine_x64",
    }
    repo = abi_to_repo.get(android_abi)
    if not repo:
        fail("Unsupported android_abi '%s'. Use arm64 or x64." % android_abi)

    # `deps` (not just the wrapper's exports) matters here: flutter.jar's
    # own desugar action takes its classpath from the java_import's
    # direct deps, and desugaring io.flutter.* against an incomplete
    # classpath fails the deploy jar's desugar-dependency check.
    _java_import(
        name = "_%s_jar" % name,
        # The engine with its native libraries stripped, as Gradle packages
        # it (flutter_android_engine_jar.bzl).
        jars = select({
            "@rules_flutter//flutter/private:dbg": [Label("@%s//:debug_stripped" % repo)],
            # Named through rules_flutter's own repo mapping, so a consumer
            # needs no use_repo entry for a repo only profile builds fetch.
            "@rules_flutter//flutter/private:profile": [Label("@%s_profile//:stripped" % repo)],
            "//conditions:default": [Label("@%s//:stripped" % repo)],
        }),
        tags = tags,
        neverlink = neverlink,
        deps = _ANDROIDX_EMBEDDING_DEPS,
    )

    # The android_library wrapper carries the embedding's R8 keep rules
    # (the @androidx.annotation.Keep contract FlutterJNI relies on) to the
    # consuming android_binary — the role the Maven embedding AAR's
    # consumer proguard config plays in Gradle builds. java_import cannot
    # declare proguard_specs, hence the wrapper. The androidx artifacts
    # are additionally exported so consumers compile against the same
    # classpath the embedding POM gives Gradle builds (see
    # _ANDROIDX_EMBEDDING_DEPS).
    _android_library(
        name = name,
        exports = ["_%s_jar" % name] + _ANDROIDX_EMBEDDING_DEPS,
        proguard_specs = ["@rules_flutter//flutter/private/runners/android:flutter_engine_proguard.pro"],
        neverlink = neverlink,
        tags = tags,
        **kwargs
    )
