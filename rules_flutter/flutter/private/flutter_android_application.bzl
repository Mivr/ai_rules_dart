"""The Dart payload of a Flutter app for Android, and a Flutter module as an AAR.

`flutter_android_bundle` builds what the Dart side gives an Android app for one ABI: the AOT library
(a profile or release build), the native libraries of the Dart graph (FFI libraries, code assets) and
the `flutter_assets` tree (with the kernel in a debug build). `flutter_android_app` of a pinned Gradle
model (`//flutter/private/android_model`) calls it once per ABI and packages the result.

It applies a platform transition derived from its `android_abi` attribute, so the application,
including its AOT compile and any FFI or native deps, always builds for the matching Android platform
(//flutter/platforms:android_arm64 or :android_x64) with no --platforms flag from the user.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_elf_machine_for_abi", "android_platform_for_abi")

visibility(["//flutter/..."])

# Flutter's profile mode (see //flutter:profile).
_PROFILE_FLAG = "//flutter:profile"
_AOT_SYMBOLS_FLAG = "//flutter/private:android_aot_symbols"

# What a Gradle variant's build mode means for the Dart payload, whatever `-c` the command line has:
# the variant names the mode, as `flutter build apk --release` does.
_MODE_SETTINGS = {
    "debug": ("dbg", False),
    "profile": ("opt", True),
    "release": ("opt", False),
}

def _android_platform_transition_platforms(attr):
    # An ABI the rule does not know is reported by the rule itself; the transition needs a platform.
    abi = getattr(attr, "android_abi", "")
    return {
        "//command_line_option:platforms": [android_platform_for_abi(abi if abi in ANDROID_ABIS else "arm64-v8a")],
    }

def _android_platform_transition_impl(settings, attr):
    # Idempotent on every edge: besides the platform, `dynamic_mode` is pinned
    # to "off", so that the application subgraph has one configuration whatever
    # the caller's value. `dynamic_mode` feeds no Dart action.
    result = _android_platform_transition_platforms(attr)
    result["//command_line_option:dynamic_mode"] = "off"
    features = list(settings["//command_line_option:features"])
    if getattr(attr, "analyze_size", False) and "analyze_size" not in features:
        features.append("analyze_size")
    result["//command_line_option:features"] = features
    mode = getattr(attr, "flutter_mode", "")
    if mode:
        result["//command_line_option:compilation_mode"] = _MODE_SETTINGS[mode][0]
        result[_PROFILE_FLAG] = _MODE_SETTINGS[mode][1]
    else:
        result["//command_line_option:compilation_mode"] = settings["//command_line_option:compilation_mode"]
        result[_PROFILE_FLAG] = settings[_PROFILE_FLAG]
    result[_AOT_SYMBOLS_FLAG] = getattr(attr, "native_debug_symbols", False)
    return result

# Builds the bundle and everything behind it (the flutter_application, its
# AOT compile, FFI cc deps, Native Assets) for the Android platform matching
# `android_abi`. `//command_line_option:platforms`
# and `//command_line_option:dynamic_mode` are set; every other setting is
# the caller's.
_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [
        "//command_line_option:features",
        "//command_line_option:compilation_mode",
        _PROFILE_FLAG,
    ],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:dynamic_mode",
        "//command_line_option:features",
        "//command_line_option:compilation_mode",
        _PROFILE_FLAG,
        _AOT_SYMBOLS_FLAG,
    ],
)

android_platform_transition = _android_platform_transition

def _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, flutter_sdk_info):
    """Copy flutter_assets and add kernel_blob.bin + VM snapshots for debug mode.

    On Android, the debug engine looks for kernel_blob.bin inside
    flutter_assets/ (same convention as `flutter build apk --debug`).
    The vm_snapshot_data and isolate_snapshot_data are needed for the
    kernel service isolate (hot reload and expression evaluation).
    """
    out = ctx.actions.declare_directory(ctx.label.name + "_debug_flutter_assets")

    args = ctx.actions.args()
    args.add("debug-assets")
    args.add("--assets-dir", flutter_assets.path)
    args.add("--output-dir", out.path)
    args.add("--kernel", kernel_dill.path)
    inputs = [flutter_assets, kernel_dill, ctx.executable._android_bundle_tool]

    vm_snapshot = flutter_sdk_info.vm_isolate_snapshot
    iso_snapshot = flutter_sdk_info.isolate_snapshot
    if vm_snapshot:
        args.add("--vm-snapshot", vm_snapshot.path)
        inputs.append(vm_snapshot)
    if iso_snapshot:
        args.add("--isolate-snapshot", iso_snapshot.path)
        inputs.append(iso_snapshot)

    ctx.actions.run(
        executable = ctx.executable._android_bundle_tool,
        arguments = [args],
        inputs = depset(
            direct = inputs,
        ),
        outputs = [out],
        mnemonic = "FlutterAndroidDebugAssets",
        progress_message = "Assembling debug flutter_assets with kernel and VM snapshots %s" % ctx.label,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    return out

def _bundle_size_depset(ctx):
    """Returns the analyze_size depset from the application target, if present."""
    if OutputGroupInfo in ctx.attr.application and hasattr(ctx.attr.application[OutputGroupInfo], "analyze_size"):
        return ctx.attr.application[OutputGroupInfo].analyze_size
    return depset()

def _bundle_release_groups(ctx):
    """Forwards the application's `debug_info` and `obfuscation_map` output groups.

    The bundle compiles the application for the Android platform, so these are
    the symbols and the map of the build that ships in the APK.
    """
    groups = {}
    if OutputGroupInfo not in ctx.attr.application:
        return groups
    app_groups = ctx.attr.application[OutputGroupInfo]
    for name in ("debug_info", "obfuscation_map", "android_plugins"):
        if hasattr(app_groups, name):
            groups[name] = getattr(app_groups, name)
    return groups

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    pinned = ctx.attr.engine_revision
    if pinned and flutter_sdk_info.engine_revision and pinned != flutter_sdk_info.engine_revision:
        fail(("\n{label}: the app's Android pin was written with Flutter engine {pinned} (its Java embedding and " +
              "libflutter.so are that engine's), and this build's Flutter SDK {version} has engine {have}. An app with " +
              "the Dart program of one engine and the embedding of another does not start. Pin again with the " +
              "Flutter version the build uses.").format(
            label = ctx.label,
            pinned = pinned,
            version = flutter_sdk_info.version,
            have = flutter_sdk_info.engine_revision,
        ))
    flutter_assets = app_info.flutter_assets
    native_libs = list(app_info.native_libs)

    # The code assets' bundle directories (build hooks, `flutter_native_asset`): their libraries
    # are packaged under `lib/<abi>/` with the app's other native libraries.
    code_asset_dirs = list(app_info.bundled_code_assets)

    kernel_dill = app_info.kernel_dill

    # Debug mode: include kernel_blob.bin in flutter_assets for JIT execution.
    if kernel_dill and not app_info.aot_output:
        flutter_assets = _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, flutter_sdk_info)

    # The AOT output is the libapp.so for Android.
    aot_output = app_info.aot_output
    all_native_libs = ([aot_output] if aot_output else []) + native_libs

    # Two libraries of one name cannot both be packaged: Android can load only one.
    seen = {}
    for lib in native_libs:
        if lib.basename in seen or (aot_output and lib.basename == "libapp.so"):
            fail((
                "flutter_android_bundle: two native libraries would both be " +
                "packaged as lib/{abi}/{basename}: {first} and {second}. " +
                "Rename one of them: Android can only load one."
            ).format(
                abi = ctx.attr.android_abi,
                basename = lib.basename,
                first = (seen.get(lib.basename) or aot_output).path,
                second = lib.path,
            ))
        seen[lib.basename] = lib

    outputs = [flutter_assets] + all_native_libs + code_asset_dirs

    output_groups = {
        # The AOT library alone (packaged as libapp.so), and the other native libraries alone.
        "aot": depset([aot_output] if aot_output else []),
        "plugin_native_libs": depset(native_libs),
        "native_libs": depset(all_native_libs),
        # Directories of native libraries whose names are known only when they are built (the
        # libraries of build hooks).
        "native_lib_dirs": depset(code_asset_dirs),
        "flutter_assets": depset([flutter_assets]),
    }

    size_depset = _bundle_size_depset(ctx)
    size_files = size_depset.to_list()
    if size_files:
        outputs.extend(size_files)
        output_groups["analyze_size"] = size_depset
    output_groups.update(_bundle_release_groups(ctx))

    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(**output_groups),
    ]

flutter_android_bundle = rule(
    implementation = _flutter_android_bundle_impl,
    cfg = _android_platform_transition,
    attrs = {
        "analyze_size": attr.bool(
            doc = "Whether to transition application with analyze_size feature and forward analyze_size output group.",
            default = False,
        ),
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "engine_revision": attr.string(
            doc = """The Flutter engine revision of the Java embedding the app is packaged with (an app built
from the Gradle model reads it from the pin). When it is not the engine of the build's
Flutter SDK the build fails: the Dart program and the embedding would not match.""",
        ),
        "native_debug_symbols": attr.bool(
            doc = """The AOT library keeps its symbol table, as in a stock build, where gen_snapshot does not
strip and the Android build does. Set by an app built from the Gradle model when its bundle
carries native debug symbols (`ndk.debugSymbolLevel`, by default in a release build); the
packer of the app strips the library. With `obfuscate` the compiler strips all the same.""",
        ),
        "flutter_mode": attr.string(
            doc = """Flutter's build mode of the payload: `debug` (the kernel), `profile` or `release`
(AOT). Empty: what the command line says (`-c dbg`, `-c opt`, `--//flutter:profile`).
An app built from the Gradle model sets it from the variant, as `flutter build`
picks the mode from its flag.""",
            values = ["", "debug", "profile", "release"],
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("armeabi-v7a", "arm64-v8a" or "x86_64").

Single source of truth for the target platform: the rule transitions itself
and the application to the matching //flutter/platforms target, so native
library placement (lib/<abi>/) and the code built into those libraries always
agree.""",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_android_bundle_tool": attr.label(
            doc = "Tool that builds the Android application bundle from the compiled outputs.",
            default = Label("@rules_flutter_tools//:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = """The Dart payload of a Flutter app for one Android ABI.

Its files are the `flutter_assets` tree (with `kernel_blob.bin` and the VM snapshots in a debug
build) and the native libraries: the AOT library (a profile or release build) and the libraries of
the Dart graph, some of them in a directory (the libraries build hooks made). Output groups:
`flutter_assets`, `aot`, `plugin_native_libs`, `native_libs`, `native_lib_dirs`, and
`debug_info`, `obfuscation_map` and `analyze_size` when the application has them.

The rule transitions itself and `application` to the Android platform derived from `android_abi`,
so the AOT compile and all native deps target Android without any --platforms flag.
`flutter_android_app` of a pinned Gradle model packages it; see docs/android-model.md.""",
)

def _aar_manifest(ctx):
    """Writes the AAR's AndroidManifest.xml, which carries only the package name."""
    manifest = ctx.actions.declare_file(ctx.label.name + "_aar/AndroidManifest.xml")
    ctx.actions.write(
        output = manifest,
        content = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n" +
                  "    package=\"{}\"/>\n".format(ctx.attr.package_name),
    )
    return manifest

# The ABIs with a pinned engine jar for `engine_maven` (see `_ANDROID_ENGINE_JAR_ARCHS` in
# //flutter:repositories.bzl).
_AAR_ABIS = ["arm64-v8a", "x86_64"]

def _aar_engine_jar(android_abi):
    """Selects the pinned release engine `flutter.jar` for `android_abi`."""
    if android_abi == "x86_64":
        return Label("@flutter_android_engine_x64//:flutter.jar")
    return Label("@flutter_android_engine_arm64//:flutter.jar")

def _flutter_android_aar_impl(ctx):
    """Packs the module's AOT library, assets and manifest into `<name>.aar`."""
    abi = ctx.attr.android_abi
    if abi not in _AAR_ABIS:
        fail((
            "flutter_android_aar {}: invalid value in 'android_abi' attribute: " +
            "has to be one of 'arm64-v8a' or 'x86_64' instead of '{}'. " +
            "Unsupported Android ABI '{}'. Supported: {}."
        ).format(
            ctx.label,
            abi,
            abi,
            ", ".join(_AAR_ABIS),
        ))
    app_info = ctx.attr.application[FlutterApplicationInfo]
    if ctx.var.get("COMPILATION_MODE") == "dbg" or not app_info.aot_output:
        fail((
            "flutter_android_aar {}: debug mode is not supported. A debug AAR needs the JIT " +
            "kernel, which this rule does not package. Build with `-c opt` (release) or " +
            "`--//flutter:profile`."
        ).format(ctx.label))
    manifest = _aar_manifest(ctx)
    flutter_assets = app_info.flutter_assets
    aar = ctx.actions.declare_file(ctx.label.name + ".aar")

    args = ctx.actions.args()
    args.add("aar")
    args.add("--output", aar)
    args.add("--manifest", manifest)
    args.add("--assets-dir", flutter_assets.path)
    args.add("--lib")
    args.add(abi)
    args.add(str(android_elf_machine_for_abi(abi)))
    args.add(app_info.aot_output)

    ctx.actions.run(
        executable = ctx.executable._android_bundle_tool,
        arguments = [args],
        inputs = [
            ctx.executable._android_bundle_tool,
            manifest,
            flutter_assets,
            app_info.aot_output,
        ],
        outputs = [aar],
        mnemonic = "FlutterAndroidAar",
        progress_message = "Packaging Flutter module into %s" % aar.short_path,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )

    # The engine comes from the pinned `flutter_android_engine_<abi>` repository;
    # release and profile both use the release flutter.jar.
    return [
        DefaultInfo(files = depset([aar])),
        OutputGroupInfo(engine_maven = depset([ctx.file._engine_jar])),
    ]

flutter_android_aar = rule(
    implementation = _flutter_android_aar_impl,
    cfg = _android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "A `flutter_application` target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "package_name": attr.string(
            doc = "The Android package written to the AAR's `AndroidManifest.xml`.",
            mandatory = True,
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("arm64-v8a" or "x86_64").

Single source of truth for the target platform: the rule transitions itself
and `application` to the matching `//flutter/platforms` target, packages
`jni/<abi>/libapp.so` into the AAR, and exposes that ABI's pinned engine
`flutter.jar` in the `engine_maven` output group.""",
            default = "arm64-v8a",
        ),
        "_android_bundle_tool": attr.label(
            doc = "Tool that writes the archive.",
            default = Label("@rules_flutter_tools//:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
        "_engine_jar": attr.label(
            doc = "The pinned release engine `flutter.jar` for `android_abi`.",
            default = _aar_engine_jar,
            allow_single_file = True,
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = [
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = """Packages a `flutter_application` as an Android library (AAR) for a native host app.

Emits `<name>.aar` holding `jni/<abi>/libapp.so` (the AOT-compiled Dart library for
`android_abi`), `assets/flutter_assets/`, an `AndroidManifest.xml` with `package_name`,
and an empty `classes.jar`. No Gradle and no host tool is involved.

Output groups:
- `engine_maven`: the pinned engine `flutter.jar` for `android_abi` (the Java
  embedding classes and `libflutter.so`), from the `flutter_android_engine_<abi>`
  repository and its sha256 pin.

Release and profile only: a debug build fails analysis.""",
)
