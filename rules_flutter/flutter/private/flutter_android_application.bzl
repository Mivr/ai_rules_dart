"""Flutter Android application bundling.

Produces the native artifacts needed for an Android APK:
- A .jar containing lib/arm64-v8a/libapp.so (AOT-compiled Dart code)
- flutter_assets/ tree artifact

The user wires these outputs into rules_android's android_binary:

    load("@rules_flutter//flutter:android.bzl", "flutter_android_bundle")

    flutter_application(
        name = "my_app_flutter",
        main = "main.dart",
    )

    flutter_android_bundle(
        name = "my_app_android",
        application = ":my_app_flutter",
    )

    # Wire into android_binary via java_import:
    java_import(
        name = "my_app_native",
        jars = [":my_app_android_native_libs.jar"],
    )

    android_binary(
        name = "my_app",
        manifest = "AndroidManifest.xml",
        deps = [":my_app_native", "@flutter_android_engine_arm64//:flutter_embedding"],
        ...
    )

The native_libs.jar packages libapp.so at lib/<abi>/libapp.so inside a jar,
matching the same convention as flutter.jar (which packages libflutter.so).
This lets android_binary extract and package the .so into the APK automatically.

flutter_android_bundle applies a platform transition derived from its
`android_abi` attribute, so the application — including its AOT compile and
any FFI/native deps — always builds for the matching Android platform
(//flutter/platforms:android_arm64 or :android_x64) with no --platforms
flag from the user. Every native library is validated to be an ELF shared
object with the ABI's machine type before packaging; a host-format binary
is a hard build error.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_elf_machine_for_abi", "android_platform_for_abi", "compute_android_jni_path")

visibility(["//flutter/..."])

# Label of the rules_android Starlark flag holding the caller's `--android_platforms`.
# The native `//command_line_option:android_platforms` is a redirect to this flag on
# Bazel 9, and 9.0.0 emits the redirect target with a canonical-position apparent repo
# name that no repository has, so the transition reads the flag by its apparent label.
ANDROID_PLATFORMS_FLAG = "@rules_android//flags:android_platforms"

def _android_platform_transition_platforms(settings, attr):
    abi = getattr(attr, "android_abi", "")
    if abi in ANDROID_ABIS:
        return {
            "//command_line_option:platforms": [android_platform_for_abi(abi)],
        }

    for platform in settings["//command_line_option:platforms"]:
        platform_str = str(platform).lower()
        if "android" in platform_str:
            return {
                "//command_line_option:platforms": list(settings["//command_line_option:platforms"]),
            }
        if "x86_64" in platform_str or "x64" in platform_str or "amd64" in platform_str:
            return {
                "//command_line_option:platforms": [android_platform_for_abi("x86_64")],
            }
        if "arm64" in platform_str or "aarch64" in platform_str:
            return {
                "//command_line_option:platforms": [android_platform_for_abi("arm64-v8a")],
            }

    android_platforms = settings[ANDROID_PLATFORMS_FLAG]
    if android_platforms:
        return {
            "//command_line_option:platforms": list(android_platforms),
        }

    cpu = settings["//command_line_option:cpu"]
    if cpu in ("x86_64", "x86", "x64", "amd64"):
        return {
            "//command_line_option:platforms": [android_platform_for_abi("x86_64")],
        }
    return {
        "//command_line_option:platforms": [android_platform_for_abi("arm64-v8a")],
    }

def _android_platform_transition_impl(settings, attr):
    # Idempotent on every edge: besides the platform, pin `dynamic_mode` to
    # what rules_android itself uses for the native deps of an android_binary
    # (`_cc_flags_from_android` sets it to "off"). The bundle, the registrant
    # sources and the plugin aggregator are each reachable through both a
    # split `deps` edge (dynamic_mode=off) and an unsplit edge (the binary's
    # `assets`, the manifest merge's `libraries`), and passing the caller's
    # value through forked the whole application subgraph — including the AOT
    # kernel compile and the cross gen_snapshot — into two configurations
    # with byte-identical outputs. `dynamic_mode` feeds no Dart action, so
    # the surviving configuration produces the same app.dill and app.so.
    result = _android_platform_transition_platforms(settings, attr)
    result["//command_line_option:dynamic_mode"] = "off"
    features = list(settings["//command_line_option:features"])
    if getattr(attr, "analyze_size", False) and "analyze_size" not in features:
        features.append("analyze_size")
    result["//command_line_option:features"] = features
    return result

# Builds the bundle and everything behind it (the flutter_application, its
# AOT compile, FFI cc deps, Native Assets) for the Android platform matching
# `android_abi` (or the caller's configured Android ABI when `android_abi` is
# omitted on `flutter_android_registrant`). `//command_line_option:platforms`
# and `//command_line_option:dynamic_mode` are set; every other setting is
# the caller's.
_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [
        "//command_line_option:platforms",
        ANDROID_PLATFORMS_FLAG,
        "//command_line_option:cpu",
        "//command_line_option:dynamic_mode",
        "//command_line_option:features",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:dynamic_mode",
        "//command_line_option:features",
    ],
)

android_platform_transition = _android_platform_transition

def _symlink_to_jni(ctx, src, abi, basename):
    """Create a symlink placing a native lib into the jni/<abi>/ tree."""
    out = ctx.actions.declare_file(
        compute_android_jni_path(ctx.label.name, abi, basename),
    )
    ctx.actions.symlink(output = out, target_file = src)
    return out

def _symlink_assets_dir(ctx, flutter_assets):
    """Symlink the flutter_assets tree into assets/flutter_assets/ for mobile-install."""

    # Use label name as prefix to avoid conflicts when multiple bundles
    # exist in the same package (e.g. Tier 1 macro + explicit Tier 2).
    out = ctx.actions.declare_directory(ctx.label.name + "_mi/assets/flutter_assets")
    ctx.actions.symlink(output = out, target_file = flutter_assets)
    return out

def _create_native_libs_jar(ctx, aot_output, native_libs, abi):
    """Package native libs into a jar at lib/<abi>/*.so.

    This matches flutter.jar's convention (which puts libflutter.so at
    lib/arm64-v8a/libflutter.so). java_import + android_binary then
    extract and package the .so files into the APK automatically.

    Every library is validated to be an ELF shared object with the ABI's
    machine type before it is zipped — a wrong-format library fails the
    build instead of producing an APK that crashes on device. Two libraries
    claiming the same packaged filename are a hard error too: the zip would
    otherwise silently drop one of them.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        aot_output: The AOT compile output, packaged as libapp.so (Android
            convention: the engine loads the Dart snapshot via
            System.loadLibrary("app")). None in debug/JIT mode.
        native_libs: Plugin/FFI .so files to package under their own names.
        abi: Android ABI string (e.g. "arm64-v8a").

    Returns:
        The output .jar File.
    """
    jar = ctx.actions.declare_file(ctx.label.name + "_native_libs.jar")
    expected_machine = android_elf_machine_for_abi(abi)

    entries = sorted(
        ([("libapp.so", aot_output)] if aot_output else []) + [
            (lib.basename, lib)
            for lib in native_libs
        ],
        key = lambda e: e[0],
    )

    zip_entries = []
    seen_basenames = {}
    for basename, lib in entries:
        if basename in seen_basenames:
            fail((
                "flutter_android_bundle: two native libraries would both be " +
                "packaged as lib/{abi}/{basename}: {first} and {second}. " +
                "Rename one of them — Android can only load one."
            ).format(
                abi = abi,
                basename = basename,
                first = seen_basenames[basename].path,
                second = lib.path,
            ))
        seen_basenames[basename] = lib
        zip_entries.append("lib/{abi}/{basename}={src}".format(
            abi = abi,
            basename = basename,
            src = lib.path,
        ))

    args = ctx.actions.args()
    args.add("native-libs-jar")
    args.add("--output", jar.path)
    args.add("--abi", abi)
    args.add("--machine", str(expected_machine))
    args.add_all(zip_entries)

    ctx.actions.run(
        executable = ctx.executable._android_bundle_tool,
        arguments = [args],
        inputs = depset(
            direct = [ctx.executable._android_bundle_tool] + [lib for _, lib in entries],
        ),
        outputs = [jar],
        mnemonic = "FlutterNativeLibsJar",
        progress_message = "Packaging Flutter native libs into jar %s" % ctx.label,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    return jar

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
    for name in ("debug_info", "obfuscation_map"):
        if hasattr(app_groups, name):
            groups[name] = getattr(app_groups, name)
    return groups

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    flutter_assets = app_info.flutter_assets
    native_libs = list(app_info.native_libs)

    # Native Assets `dynamic_loading_bundle` shared libraries land in
    # `jniLibs/<abi>/` of the same `native_libs.jar` rules_android
    # already extracts into the APK.
    native_libs.extend(app_info.bundled_code_assets.to_list())

    kernel_dill = app_info.kernel_dill

    # Debug mode: include kernel_blob.bin in flutter_assets for JIT execution.
    if kernel_dill and not app_info.aot_output:
        flutter_assets = _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, flutter_sdk_info)

    # The AOT output is the libapp.so for Android.
    aot_output = app_info.aot_output
    all_native_libs = ([aot_output] if aot_output else []) + native_libs
    abi = ctx.attr.android_abi

    # Create a jar containing native libs at lib/<abi>/*.so.
    # In debug mode (JIT) with no plugin/FFI libs there is nothing to
    # package — create an empty jar so the java_import pipeline in the
    # macro doesn't break.
    if all_native_libs:
        native_libs_jar = _create_native_libs_jar(ctx, aot_output, native_libs, abi)
    else:
        native_libs_jar = ctx.actions.declare_file(ctx.label.name + "_native_libs.jar")

        # Zipper requires at least one entry, so use a minimal valid zip header.
        ctx.actions.run(
            executable = ctx.executable._android_bundle_tool,
            arguments = [
                "empty-jar",
                "--output",
                native_libs_jar.path,
            ],
            inputs = depset(
                direct = [ctx.executable._android_bundle_tool],
            ),
            outputs = [native_libs_jar],
            mnemonic = "FlutterEmptyNativeLibsJar",
            progress_message = "Creating empty native libs jar (debug mode) %s" % ctx.label,
            toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
        )

    outputs = [flutter_assets, native_libs_jar] + all_native_libs

    # mobile-install compatible output structure.
    mobile_install_files = []
    if ctx.attr.mobile_install_compatible:
        if aot_output:
            jni_libapp = _symlink_to_jni(ctx, aot_output, abi, "libapp.so")
            mobile_install_files.append(jni_libapp)

        for lib in native_libs:
            jni_lib = _symlink_to_jni(ctx, lib, abi, lib.basename)
            mobile_install_files.append(jni_lib)

        assets_dir = _symlink_assets_dir(ctx, flutter_assets)
        mobile_install_files.append(assets_dir)

        outputs.extend(mobile_install_files)

    output_groups = {
        "native_libs": depset(all_native_libs),
        "native_libs_jar": depset([native_libs_jar]),
        "flutter_assets": depset([flutter_assets]),
        "mobile_install": depset(mobile_install_files),
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
        "mobile_install_compatible": attr.bool(
            doc = """Whether to produce output structured for `bazel mobile-install`.

When True (the default), native libs are symlinked into jni/<abi>/ and
flutter assets into assets/flutter_assets/, matching the directory layout
that mobile-install expects. A `mobile_install` output group is also
provided for selective fetching.

Set to False if you only build release APKs and do not need mobile-install.""",
            default = True,
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("arm64-v8a" or "x86_64").

Single source of truth for the target platform: the rule transitions itself
and the application to the matching //flutter/platforms target, so native
library placement (lib/<abi>/) and the code built into those libraries always
agree.""",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_android_bundle_tool": attr.label(
            doc = "Tool that builds the Android application bundle from the compiled outputs.",
            default = Label("//flutter/private/tools:android_bundle"),
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
    doc = """Bundles Flutter compilation outputs for Android packaging.

Produces a native_libs.jar containing lib/<abi>/libapp.so and a flutter_assets
tree artifact. Use java_import on the jar and android_binary to assemble the APK.

The rule transitions itself and `application` to the Android platform derived
from `android_abi`, so the AOT compile and all native deps target Android
without any --platforms flag. Passing --android_platforms to android_binary
remains supported: this rule's transition re-normalizes its subgraph to the
declared ABI's platform, so the two compose to the same configuration. Native
libraries are validated to be ELF for the declared ABI at packaging time.

By default, outputs are also structured for `bazel mobile-install` compatibility.
Use the wrapping android_binary target with `bazel mobile-install` for fast
incremental deployment to a connected device.""",
)

def android_internal_tags(tags):
    """Keeps internal targets out of wildcard builds behind the pure-Go proxy.

    Args:
        tags: Target tags list to adjust.

    Returns:
        List of tags including "manual".
    """
    internal_tags = list(tags) if tags else []
    if "manual" not in internal_tags:
        internal_tags.append("manual")
    return internal_tags

def _aar_manifest(ctx):
    """Writes the AAR's AndroidManifest.xml, which carries only the package name."""
    manifest = ctx.actions.declare_file(ctx.label.name + "_aar/AndroidManifest.xml")
    ctx.actions.write(
        output = manifest,
        content = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n" +
                  "    package=\"{}\"/>\n".format(ctx.attr.package_name),
    )
    return manifest

def _aar_engine_jar(android_abi):
    """Selects the pinned release engine `flutter.jar` for `android_abi`."""
    if android_abi == "x86_64":
        return Label("@flutter_android_engine_x64//:flutter.jar")
    return Label("@flutter_android_engine_arm64//:flutter.jar")

def _flutter_android_aar_impl(ctx):
    """Packs the module's AOT library, assets and manifest into `<name>.aar`."""
    abi = ctx.attr.android_abi
    if abi not in ANDROID_ABIS:
        fail((
            "flutter_android_aar {}: invalid value in 'android_abi' attribute: " +
            "has to be one of 'arm64-v8a' or 'x86_64' instead of '{}'. " +
            "Unsupported Android ABI '{}'. Supported: {}."
        ).format(
            ctx.label,
            abi,
            abi,
            ", ".join(ANDROID_ABIS.keys()),
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
            default = Label("//flutter/private/tools:android_bundle"),
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
