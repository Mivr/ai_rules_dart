"""Shared fixtures and tests for the iOS and macOS bundling rules.

These tests care about how a rule lays its outputs out, not about what a real
Flutter build produces, so their applications are fakes: compiling a real one
per fixture would cost minutes and need a device SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:providers.bzl", "AppleBundleInfo")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:macos.bzl", "flutter_apple_plugin_library")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterApplicationInfo")

visibility(["//flutter/tests/...", "//tests/rules_testing:__pkg__"])

def _write_fake_macho(ctx, out_file, install_name):
    if ctx.attr.fat_macho:
        arm_slice = ctx.actions.declare_file(out_file.short_path + ".arm64")
        x86_slice = ctx.actions.declare_file(out_file.short_path + ".x86_64")
        for arch, slice_file in [("arm64", arm_slice), ("x86_64", x86_slice)]:
            ctx.actions.run(
                executable = ctx.executable._macho_edit,
                arguments = [
                    "stub",
                    "--output",
                    slice_file.path,
                    "--arch",
                    arch,
                    "--platform",
                    "macos",
                    "--min-os",
                    "11.0",
                    "--install-name",
                    install_name,
                ],
                inputs = depset(
                    direct = [ctx.executable._macho_edit],
                ),
                outputs = [slice_file],
                toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
            )
        ctx.actions.run(
            executable = ctx.executable._macho_edit,
            arguments = [
                "fat",
                "--output",
                out_file.path,
                x86_slice.path,
                arm_slice.path,
            ],
            inputs = depset(
                direct = [x86_slice, arm_slice, ctx.executable._macho_edit],
            ),
            outputs = [out_file],
            toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
        )
    else:
        ctx.actions.run(
            executable = ctx.executable._macho_edit,
            arguments = [
                "stub",
                "--output",
                out_file.path,
                "--arch",
                "arm64",
                "--platform",
                "macos",
                "--min-os",
                "13.0",
                "--install-name",
                install_name,
            ],
            inputs = depset(
                direct = [ctx.executable._macho_edit],
            ),
            outputs = [out_file],
            toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
        )

def _fake_application_impl(ctx):
    """Placeholder outputs, every one declared under this target's name.

    So fakes in one package never share an output — which is the very defect
    the tests over them are checking the real rules for.

    A path named in both `native_libs` and `code_assets` is one File: the shape
    of one library arriving by both routes.
    """

    libs = {}
    for path in ctx.attr.native_libs + ctx.attr.code_assets:
        if path not in libs:
            lib = ctx.actions.declare_file("%s/%s" % (ctx.label.name, path))
            if ctx.attr.macho_aot:
                _write_fake_macho(
                    ctx,
                    lib,
                    "@rpath/%s/%s" % (ctx.label.name, path),
                )
            else:
                ctx.actions.write(lib, "%s %s" % (ctx.label, path))
            libs[path] = lib

    # Debug carries a kernel and no AOT dylib; release the reverse. When
    # `macho_aot = True`, the release fixture synthesizes a valid 64-bit Mach-O
    # dylib via `macho_edit.dart stub` so `FlutterIOSRetagDylib` can parse and
    # re-tag it in a real `build_test`.
    if ctx.attr.debug:
        aot_output = None
        kernel_dill = ctx.actions.declare_file(ctx.label.name + "/app.dill")
        ctx.actions.write(kernel_dill, str(ctx.label))
    else:
        kernel_dill = None
        aot_output = ctx.actions.declare_file(ctx.label.name + "/app.so")
        if ctx.attr.macho_aot:
            _write_fake_macho(
                ctx,
                aot_output,
                "@rpath/%s/App.framework/App" % ctx.label.name,
            )
        else:
            ctx.actions.write(aot_output, str(ctx.label))

    asset_manifest = ctx.actions.declare_file(ctx.label.name + "/_staging/AssetManifest.bin")
    ctx.actions.write(asset_manifest, "")
    icu_data = ctx.actions.declare_file(ctx.label.name + "/icudtl.dat")
    ctx.actions.write(icu_data, "ICU")
    flutter_assets = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "copy-files",
            "--output-dir",
            flutter_assets.path,
            asset_manifest.path,
        ],
        inputs = depset(
            direct = [asset_manifest, ctx.executable._macho_edit],
        ),
        outputs = [flutter_assets],
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )

    plugins = []
    apple_plugin_libs = []
    if ctx.attr.plugin_name and ctx.attr.plugin_class:
        plugins.append(struct(
            name = ctx.attr.plugin_name,
            platforms = {
                "ios": {"pluginClass": ctx.attr.plugin_class},
                "macos": {"pluginClass": ctx.attr.plugin_class},
            },
        ))
    for plugin_name in sorted(ctx.attr.extra_plugins.keys()):
        plugins.append(struct(
            name = plugin_name,
            platforms = {
                "ios": {"pluginClass": ctx.attr.extra_plugins[plugin_name]},
                "macos": {"pluginClass": ctx.attr.extra_plugins[plugin_name]},
            },
        ))
    for lib in ctx.attr.apple_libs + ctx.attr.apple_plugin_libraries:
        if FlutterApplePluginInfo not in lib:
            fail("fake_application: apple_libs entry %s must provide FlutterApplePluginInfo" % lib.label)
        platform_name = lib[FlutterApplePluginInfo].platform
        fw_infos = getattr(lib[FlutterApplePluginInfo], "framework_infos", None)
        apple_plugin_libs.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            sdk_frameworks = tuple(lib[FlutterApplePluginInfo].sdk_frameworks),
            sdk_dylibs = tuple(lib[FlutterApplePluginInfo].sdk_dylibs),
            framework_infos = fw_infos if fw_infos != None else depset(),
            package = ctx.attr.plugin_name or lib.label.name,
        ))

    return [FlutterApplicationInfo(
        aot_output = aot_output,
        # The fixture synthesizes its binary (a Mach-O stub or plain text),
        # never a stripped gen_snapshot output.
        aot_strip = False,
        kernel_dill = kernel_dill,
        is_debug = ctx.attr.debug,
        flutter_assets = flutter_assets,
        native_libs = [libs[path] for path in ctx.attr.native_libs],
        bundled_code_assets = depset([libs[path] for path in ctx.attr.code_assets]),
        apple_privacy_manifests = depset(ctx.files.apple_privacy_manifests),
        plugins = plugins,
        apple_plugin_libraries = depset(apple_plugin_libs),
        linux_plugin_libraries = depset(),
        windows_plugin_libraries = depset(),
        icu_data = icu_data,
    )]

fake_application = rule(
    implementation = _fake_application_impl,
    attrs = {
        "apple_libs": attr.label_list(),
        "apple_plugin_libraries": attr.label_list(),
        "apple_privacy_manifests": attr.label_list(
            allow_files = True,
            doc = "Privacy manifest files exposed on `FlutterApplicationInfo.apple_privacy_manifests`.",
        ),
        "code_assets": attr.string_list(),
        "debug": attr.bool(default = False),
        "fat_macho": attr.bool(default = False),
        "macho_aot": attr.bool(default = True),
        "native_libs": attr.string_list(),
        "plugin_class": attr.string(default = ""),
        "plugin_name": attr.string(default = ""),
        "extra_plugins": attr.string_dict(
            default = {},
            doc = "Additional native plugins as {module name: plugin class}, exposed on ios and macos like plugin_name/plugin_class.",
        ),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "A fake FlutterApplicationInfo for tests over Apple bundling rules.",
)

def _outputs_under_target_dir_test_impl(ctx):
    """Every output this rule declares sits under a directory named after it.

    The invariant both Apple framework rules exist under: two apps in one
    package are two targets, and Bazel gives a declared file the package's path
    plus whatever name the rule asks for, with nothing of the target's own in
    between. A rule that hardcodes its layout therefore has both targets
    writing one path, which fails the build with conflicting actions as soon as
    the two apps differ enough for their actions to differ. A pair built from
    the *same* application hides it, because Bazel shares identical actions.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    own = "/".join([p for p in [target.label.package, target.label.name] if p])

    outputs = target[DefaultInfo].files.to_list()
    asserts.true(env, len(outputs) > 0, "the rule declared no outputs to check")
    for f in outputs:
        asserts.true(
            env,
            f.short_path == own or f.short_path.startswith(own + "/"),
            "%s is not the directory %s nor under it, so a second app in the " % (f.short_path, own) +
            "package would declare it too",
        )
    return analysistest.end(env)

outputs_under_target_dir_test = analysistest.make(
    _outputs_under_target_dir_test_impl,
)

def _fake_macho_binary_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "stub",
            "--type",
            "execute",
            "--output",
            out.path,
            "--arch",
            ctx.attr.arch,
            "--platform",
            ctx.attr.platform,
            "--min-os",
            "14.0",
        ],
        inputs = depset(
            direct = [ctx.executable._macho_edit],
        ),
        outputs = [out],
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    return [DefaultInfo(files = depset([out]), executable = out)]

fake_macho_binary = rule(
    implementation = _fake_macho_binary_impl,
    attrs = {
        "arch": attr.string(default = "arm64"),
        "platform": attr.string(default = "ios"),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    executable = True,
)

_FAKE_FRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>{name}</string>
    <key>CFBundleIdentifier</key>
    <string>io.flutter.{name}</string>
    <key>CFBundleName</key>
    <string>{name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
"""

def _fake_xcframework_impl(ctx):
    fw_name = ctx.attr.framework_name
    slice_name = "macos-arm64_x86_64" if ctx.attr.platform == "macos" else "ios-arm64"
    prefix = "%s/%s.xcframework/%s/%s.framework" % (ctx.label.name, fw_name, slice_name, fw_name)
    if ctx.attr.platform == "macos":
        binary = ctx.actions.declare_file("%s/Versions/A/%s" % (prefix, fw_name))
        plist = ctx.actions.declare_file("%s/Versions/A/Resources/Info.plist" % prefix)
        header = ctx.actions.declare_file("%s/Versions/A/Headers/%s.h" % (prefix, fw_name))
        install_name = "@rpath/%s.framework/Versions/A/%s" % (fw_name, fw_name)
    else:
        binary = ctx.actions.declare_file("%s/%s" % (prefix, fw_name))
        plist = ctx.actions.declare_file("%s/Info.plist" % prefix)
        header = ctx.actions.declare_file("%s/Headers/%s.h" % (prefix, fw_name))
        install_name = "@rpath/%s.framework/%s" % (fw_name, fw_name)

    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "stub",
            "--output",
            binary.path,
            "--arch",
            ctx.attr.arch,
            "--platform",
            ctx.attr.platform,
            "--min-os",
            "14.0",
            "--install-name",
            install_name,
        ],
        inputs = depset(
            direct = [ctx.executable._macho_edit],
        ),
        outputs = [binary],
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    ctx.actions.write(plist, _FAKE_FRAMEWORK_PLIST.format(name = fw_name))
    ctx.actions.write(header, "// Synthetic %s framework header\n" % fw_name)
    return [DefaultInfo(files = depset([binary, plist, header]))]

fake_xcframework = rule(
    implementation = _fake_xcframework_impl,
    attrs = {
        "arch": attr.string(default = "arm64"),
        "framework_name": attr.string(default = "Flutter"),
        "platform": attr.string(default = "ios"),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
)

def _macho_verify_probe_impl(ctx):
    files = ctx.attr.target[DefaultInfo].files.to_list()
    if not files:
        fail("%s: target %s produced no files" % (ctx.label, ctx.attr.target.label))

    relpath = ctx.attr.binary_relpath
    input_file = None
    use_relpath = False
    if len(files) == 1 and (files[0].is_directory or files[0].extension in ["ipa", "zip"]):
        input_file = files[0]
        use_relpath = bool(relpath)
    elif relpath:
        for f in files:
            if f.short_path.endswith("/" + relpath) or f.basename == relpath:
                input_file = f
                break
        if not input_file:
            fail("%s: no file matching %r in %s" % (ctx.label, relpath, [f.short_path for f in files]))
    else:
        input_file = files[0]

    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")
    args = [
        "verify",
        "--input",
        input_file.path,
        "--objdump",
        ctx.executable._objdump.path,
        "--output",
        stamp.path,
    ]
    if use_relpath:
        args.extend(["--binary-relpath", relpath])
    direct_inputs = [input_file, ctx.executable._macho_edit, ctx.executable._objdump]
    if AppleBundleInfo in ctx.attr.target and ctx.attr.target[AppleBundleInfo].archive:
        fw_zip = ctx.attr.target[AppleBundleInfo].archive
        args.extend(["--framework-zip", fw_zip.path])
        direct_inputs.append(fw_zip)
    for substr in ctx.attr.expected_substrings:
        args.extend(["--expect", substr])
    for entry in ctx.attr.expected_entries:
        args.extend(["--expect-entry", entry])
    for entry in ctx.attr.forbidden_entries:
        args.extend(["--forbid-entry", entry])

    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = args,
        inputs = depset(
            direct = direct_inputs,
        ),
        outputs = [stamp],
        mnemonic = "FlutterMachOVerifyProbe",
        progress_message = "Verifying Mach-O binary for %s with llvm-objdump" % ctx.label,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    return [DefaultInfo(files = depset([stamp]))]

macho_verify_probe = rule(
    implementation = _macho_verify_probe_impl,
    attrs = {
        "binary_relpath": attr.string(default = ""),
        "expected_entries": attr.string_list(default = []),
        "expected_substrings": attr.string_list(default = []),
        "forbidden_entries": attr.string_list(default = []),
        "target": attr.label(mandatory = True),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
        "_objdump": attr.label(
            default = Label("@llvm//tools:llvm-objdump"),
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Verifies a built Mach-O binary, framework, or archive using @llvm//tools:llvm-objdump.",
)

# -- Apple plugin shapes -------------------------------------------------------
#
# A mixed plugin has two halves that cannot depend on each other: the Swift
# half publishes `<module_name>-Swift.h`, the ObjC half needs it. These tests
# pin the resulting shape: the Swift target generates the header, the ObjC
# compile declares it as an input, and the public target still merges both
# halves' providers.

def _mixed_plugin_swift_header_test_impl(ctx):
    """The Swift half publishes the plugin's `<module_name>-Swift.h`."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    if CcInfo not in tut:
        asserts.true(env, False, "Expected CcInfo on %s" % tut.label)
        return analysistest.end(env)

    headers = [f.basename for f in tut[CcInfo].compilation_context.headers.to_list()]
    asserts.true(
        env,
        ctx.attr.expected_header_name in headers,
        "Expected %s in the Swift library's CcInfo headers, got: %s" % (ctx.attr.expected_header_name, headers),
    )
    files = [f.basename for f in tut[DefaultInfo].files.to_list()]
    asserts.true(
        env,
        ctx.attr.expected_header_name in files,
        "Expected %s among the Swift library's outputs, got: %s" % (ctx.attr.expected_header_name, files),
    )
    return analysistest.end(env)

def _assert_modulemap_in_headers(env, tut, suffix):
    """The framework's module map is among `CcInfo` headers, so a sandbox stages it."""
    paths = [h.path for h in tut[CcInfo].compilation_context.headers.to_list()]
    asserts.true(
        env,
        any([path.endswith(suffix) for path in paths]),
        "Expected a header ending with %s in %s CcInfo headers, got: %s" % (suffix, tut.label, paths),
    )

def _assert_objc_compiles_with_modules(env, tut):
    """Every ObjC compile of the target carries `-fmodules`, so `@import` parses."""
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "ObjcCompile"]
    for action in compiles:
        asserts.true(
            env,
            "-fmodules" in action.argv,
            "Expected -fmodules in the ObjcCompile argv of %s, got: %s" % (tut.label, action.argv),
        )

def _assert_swift_header_reachable(env, tut, ctx):
    """The Swift module's generated header is reachable and the target compiles `.m`."""
    header_files = [
        f
        for f in tut[CcInfo].compilation_context.headers.to_list()
        if f.basename == ctx.attr.expected_header_basename
    ]
    quote_includes = tut[CcInfo].compilation_context.quote_includes.to_list()
    generated = [f for f in header_files if f.dirname in quote_includes]
    asserts.equals(
        env,
        [ctx.attr.expected_header_basename],
        [f.basename for f in generated],
        "exactly one same-basename header must be reachable through a quote include path",
    )
    asserts.true(
        env,
        bool(generated) and generated[0].dirname in quote_includes,
        "Expected %s in the ObjC target's quote include paths, got: %s" % (
            generated[0].dirname if generated else ctx.attr.expected_header_basename,
            quote_includes,
        ),
    )

    shadow_suffix = ctx.attr.excluded_quote_include_suffix
    asserts.equals(
        env,
        2 if shadow_suffix else 1,
        len(header_files),
        "the fixture must put exactly one same-basename header in the transitive set per declared shadow",
    )
    if shadow_suffix:
        shadow_dirs = [f.dirname for f in header_files if f.dirname.endswith(shadow_suffix)]
        asserts.equals(
            env,
            1,
            len(shadow_dirs),
            "the shadow dependency must export its same-basename header from the declared directory",
        )
        shadowed = [path for path in quote_includes if path.endswith(shadow_suffix)]
        asserts.equals(
            env,
            [],
            shadowed,
            "A transitive header with the same basename must not add a quote include path",
        )

    compiled = []
    for action in analysistest.target_actions(env):
        if action.mnemonic not in ("ObjcCompile", "CppCompile"):
            continue
        compiled.extend([f.basename for f in action.outputs.to_list() if f.basename.endswith(".o")])
    asserts.true(
        env,
        bool(compiled),
        "Expected an ObjC compile action on %s, got: %s" % (
            tut.label,
            [action.mnemonic for action in analysistest.target_actions(env)],
        ),
    )

def _mixed_plugin_objc_input_test_impl(ctx):
    """The ObjC half compiles against the Swift module's generated header.

    Starlark's view of an analysis action (`action.inputs`) lists the source
    and module-map inputs the rule declares directly, not the headers the
    C++ rules pull from `CcCompilationContext` when they form the final
    compile command (`bazel aquery` shows those). So this test proves the
    observable facts the compile command is built from: the ObjC target's
    CcInfo carries the Swift module's generated header, the header's
    directory is a quote include path (so the plain-basename `#import`
    resolves from a source `.m`), and the target registers an ObjC compile
    action for its `.m` source.

    A dependency may export a header with the same basename from another
    directory; only the Swift module's own header may contribute a quote
    include path, so the test also pins that the dependency's directory is
    not one. `excluded_quote_include_suffix` names it.
    """
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    _assert_modulemap_in_headers(env, tut, ctx.attr.expected_modulemap_suffix)
    _assert_objc_compiles_with_modules(env, tut)
    if ctx.attr.expected_header_basename:
        _assert_swift_header_reachable(env, tut, ctx)
    return analysistest.end(env)

def _apple_plugin_public_test_impl(ctx):
    """The public target merges both halves and keeps the plugin providers."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    if CcInfo not in tut or SwiftInfo not in tut or FlutterApplePluginInfo not in tut:
        asserts.true(
            env,
            False,
            "Expected CcInfo, SwiftInfo and FlutterApplePluginInfo on %s" % tut.label,
        )
        return analysistest.end(env)

    info = tut[FlutterApplePluginInfo]
    asserts.equals(env, ctx.attr.expected_module_name, info.module_name)
    asserts.equals(env, ctx.attr.expected_platform, info.platform)
    asserts.equals(env, ctx.attr.expected_sdk_frameworks, list(info.sdk_frameworks))
    asserts.equals(env, ctx.attr.expected_sdk_dylibs, list(info.sdk_dylibs))
    asserts.true(env, len(tut[DefaultInfo].files.to_list()) > 0, "Expected output files")

    _assert_modulemap_in_headers(env, tut, ctx.attr.expected_modulemap_suffix)
    headers = [h.basename for h in tut[CcInfo].compilation_context.headers.to_list()]
    for expected in ctx.attr.expected_header_basenames:
        asserts.true(
            env,
            expected in headers,
            "Expected %s in the public target's CcInfo headers, got: %s" % (expected, headers),
        )
    return analysistest.end(env)

def _apple_plugin_surface_test_impl(ctx):
    """The fixture created exactly the base target set for its shape."""
    env = unittest.begin(ctx)
    asserts.equals(env, ctx.attr.expected_kinds, ctx.attr.observed_kinds)
    return unittest.end(env)

_apple_plugin_surface_test = unittest.make(
    _apple_plugin_surface_test_impl,
    attrs = {
        "expected_kinds": attr.string_dict(mandatory = True),
        "observed_kinds": attr.string_dict(mandatory = True),
    },
)

def _apple_plugin_swift_attrs_test_impl(ctx):
    """The Swift half sets `generates_header` and a stable header name."""
    env = unittest.begin(ctx)
    asserts.true(
        env,
        ctx.attr.observed_generates_header,
        "Expected the mixed plugin's Swift library to set generates_header",
    )
    asserts.equals(
        env,
        ctx.attr.expected_header_name,
        ctx.attr.observed_header_name,
        "the Swift library must name the generated header explicitly",
    )
    return unittest.end(env)

_apple_plugin_swift_attrs_test = unittest.make(
    _apple_plugin_swift_attrs_test_impl,
    attrs = {
        "expected_header_name": attr.string(mandatory = True),
        "observed_generates_header": attr.bool(mandatory = True),
        "observed_header_name": attr.string(mandatory = True),
    },
)

def _apple_plugin_bridging_copts_test_impl(ctx):
    """A bridging header gets the framework Clang includes; no header gets none."""
    env = unittest.begin(ctx)
    framework_copts = [
        "-Xcc",
        "-include",
        "-Xcc",
        "Foundation/Foundation.h",
        "-Xcc",
        "-include",
        "-Xcc",
        ctx.attr.platform_framework,
    ]
    bridging_copts = ctx.attr.bridging_copts
    asserts.equals(env, [ctx.attr.probe_copt], bridging_copts[:1])
    asserts.equals(env, framework_copts, bridging_copts[1:len(framework_copts) + 1])
    asserts.equals(
        env,
        ["-import-objc-header"],
        bridging_copts[len(framework_copts) + 1:len(framework_copts) + 2],
    )
    asserts.true(
        env,
        len(bridging_copts) == len(framework_copts) + 3 and ctx.attr.expected_header in bridging_copts[-1],
        "expected %s after -import-objc-header: %s" % (ctx.attr.expected_header, bridging_copts),
    )
    asserts.equals(
        env,
        [],
        [copt for copt in ctx.attr.mixed_swift_copts if copt == "-Xcc"],
        "a plugin without a bridging header must get no -Xcc include",
    )
    return unittest.end(env)

_apple_plugin_bridging_copts_test = unittest.make(
    _apple_plugin_bridging_copts_test_impl,
    attrs = {
        "bridging_copts": attr.string_list(mandatory = True),
        "expected_header": attr.string(mandatory = True),
        "mixed_swift_copts": attr.string_list(mandatory = True),
        "platform_framework": attr.string(mandatory = True),
        "probe_copt": attr.string(mandatory = True),
    },
)

def _created_rules(before, after):
    """Return the `{name: kind}` map of rules created between two snapshots."""
    return {name: after[name]["kind"] for name in after if name not in before}

def apple_plugin_fixtures(name, platform):
    """Declare pure-Swift, pure-ObjC and mixed plugin fixtures for one platform.

    Args:
      name: Prefix for the fixtures.
      platform: `"ios"` or `"macos"`.

    Returns:
      A struct of the fixture labels, module name and the target kinds each
      macro created.
    """
    prefix = "%s_%s" % (name, platform)
    module = prefix + "_module"
    pure_swift = prefix + "_pure_swift"
    pure_objc = prefix + "_pure_objc"
    mixed = prefix + "_mixed"

    write_file(
        name = pure_swift + "_src",
        out = pure_swift + ".swift",
        content = ["import Flutter", "public class PureSwiftPlugin {}"],
    )
    write_file(
        name = pure_objc + "_src",
        out = pure_objc + ".m",
        content = ["#import <Foundation/Foundation.h>"],
    )
    write_file(
        name = mixed + "_swift_src",
        out = mixed + "_swift.swift",
        content = [
            "import Flutter",
            "import %s_objc" % module,
            "@objc public class MixedPlugin: NSObject {}",
        ],
    )
    write_file(
        name = mixed + "_objc_src",
        out = mixed + "_objc.m",
        content = ['#import "%s-Swift.h"' % module],
    )
    write_file(
        name = mixed + "_header",
        out = mixed + ".h",
        content = ["#pragma once"],
    )

    before = native.existing_rules().keys()
    flutter_apple_plugin_library(
        name = pure_swift,
        srcs = [":" + pure_swift + ".swift"],
        module_name = pure_swift + "_module",
        platform = platform,
        tags = ["manual"],
    )
    pure_swift_kinds = _created_rules(before, native.existing_rules())

    before = native.existing_rules().keys()
    flutter_apple_plugin_library(
        name = pure_objc,
        srcs = [":" + pure_objc + ".m"],
        module_name = pure_objc + "_module",
        platform = platform,
        tags = ["manual"],
    )
    pure_objc_kinds = _created_rules(before, native.existing_rules())

    before = native.existing_rules().keys()
    flutter_apple_plugin_library(
        name = mixed,
        srcs = [
            ":" + mixed + "_swift.swift",
            ":" + mixed + "_objc.m",
            ":" + mixed + ".h",
        ],
        module_name = module,
        platform = platform,
        sdk_frameworks = ["AVFoundation"],
        sdk_dylibs = ["sqlite3"],
        tags = ["manual"],
    )
    mixed_rules = native.existing_rules()
    mixed_kinds = _created_rules(before, mixed_rules)
    mixed_swift = mixed_rules["_" + mixed + "__swift"]

    shadow_mixed = prefix + "_shadow_mixed"
    shadow_module = prefix + "_shadow_module"
    shadow_header_dir = shadow_mixed + "_shadow"
    write_file(
        name = shadow_mixed + "_swift_src",
        out = shadow_mixed + "_swift.swift",
        content = [
            "import Flutter",
            "public class ShadowMixedPlugin: NSObject {}",
        ],
    )
    write_file(
        name = shadow_mixed + "_objc_src",
        out = shadow_mixed + "_objc.m",
        content = ['#import "%s-Swift.h"' % shadow_module],
    )
    write_file(
        name = shadow_mixed + "_shadow_header",
        out = "%s/%s-Swift.h" % (shadow_header_dir, shadow_module),
        content = [
            "#pragma once",
            "// A dependency's header that merely shares the generated header's basename.",
        ],
    )
    objc_library(
        name = shadow_mixed + "_shadow_objc",
        hdrs = [":" + shadow_mixed + "_shadow_header"],
        tags = ["manual"],
    )

    flutter_apple_plugin_library(
        name = shadow_mixed,
        srcs = [
            ":" + shadow_mixed + "_swift.swift",
            ":" + shadow_mixed + "_objc.m",
        ],
        module_name = shadow_module,
        platform = platform,
        deps = [":" + shadow_mixed + "_shadow_objc"],
        tags = ["manual"],
    )

    bridging = prefix + "_bridging"
    bridging_module = bridging + "_module"
    write_file(
        name = bridging + "_swift_src",
        out = bridging + ".swift",
        content = ["import Flutter", "public class BridgingPlugin {}"],
    )
    write_file(
        name = bridging + "_header",
        out = bridging_module + "-Bridging-Header.h",
        content = ["#pragma once"],
    )

    before = native.existing_rules().keys()
    flutter_apple_plugin_library(
        name = bridging,
        srcs = [
            ":" + bridging + ".swift",
            bridging_module + "-Bridging-Header.h",
        ],
        module_name = bridging_module,
        platform = platform,
        copts = ["-DPLUGIN_BRIDGING=1"],
        tags = ["manual"],
    )
    bridging_swift = native.existing_rules()[bridging]

    return struct(
        pure_swift = pure_swift,
        pure_objc = pure_objc,
        mixed = mixed,
        mixed_module = module,
        shadow_mixed = shadow_mixed,
        shadow_module = shadow_module,
        shadow_header_dir = shadow_header_dir,
        mixed_swift_generates_header = mixed_swift["generates_header"],
        mixed_swift_generated_header_name = mixed_swift["generated_header_name"],
        mixed_swift_copts = mixed_swift["copts"],
        bridging_module = bridging_module,
        bridging_swift_copts = bridging_swift["copts"],
        pure_swift_kinds = pure_swift_kinds,
        pure_objc_kinds = pure_objc_kinds,
        mixed_kinds = mixed_kinds,
    )

def _apple_plugin_config_settings(platform):
    """The config settings that analyze an Apple plugin fixture off a Mac."""
    return {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % platform)),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    }

_IOS_APPLE_PLUGIN_TEST_SETTINGS = _apple_plugin_config_settings("ios")
_MACOS_APPLE_PLUGIN_TEST_SETTINGS = _apple_plugin_config_settings("macos")

_ios_mixed_plugin_swift_header_test = analysistest.make(
    _mixed_plugin_swift_header_test_impl,
    attrs = {"expected_header_name": attr.string(mandatory = True)},
    config_settings = _IOS_APPLE_PLUGIN_TEST_SETTINGS,
)
_ios_mixed_plugin_objc_input_test = analysistest.make(
    _mixed_plugin_objc_input_test_impl,
    attrs = {
        "excluded_quote_include_suffix": attr.string(),
        "expected_header_basename": attr.string(),
        "expected_modulemap_suffix": attr.string(mandatory = True),
    },
    config_settings = _IOS_APPLE_PLUGIN_TEST_SETTINGS,
)
_ios_apple_plugin_public_test = analysistest.make(
    _apple_plugin_public_test_impl,
    attrs = {
        "expected_header_basenames": attr.string_list(mandatory = True),
        "expected_modulemap_suffix": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
        "expected_platform": attr.string(mandatory = True),
        "expected_sdk_dylibs": attr.string_list(mandatory = True),
        "expected_sdk_frameworks": attr.string_list(mandatory = True),
    },
    config_settings = _IOS_APPLE_PLUGIN_TEST_SETTINGS,
)

_macos_mixed_plugin_swift_header_test = analysistest.make(
    _mixed_plugin_swift_header_test_impl,
    attrs = {"expected_header_name": attr.string(mandatory = True)},
    config_settings = _MACOS_APPLE_PLUGIN_TEST_SETTINGS,
)
_macos_mixed_plugin_objc_input_test = analysistest.make(
    _mixed_plugin_objc_input_test_impl,
    attrs = {
        "excluded_quote_include_suffix": attr.string(),
        "expected_header_basename": attr.string(),
        "expected_modulemap_suffix": attr.string(mandatory = True),
    },
    config_settings = _MACOS_APPLE_PLUGIN_TEST_SETTINGS,
)
_macos_apple_plugin_public_test = analysistest.make(
    _apple_plugin_public_test_impl,
    attrs = {
        "expected_header_basenames": attr.string_list(mandatory = True),
        "expected_modulemap_suffix": attr.string(mandatory = True),
        "expected_module_name": attr.string(mandatory = True),
        "expected_platform": attr.string(mandatory = True),
        "expected_sdk_dylibs": attr.string_list(mandatory = True),
        "expected_sdk_frameworks": attr.string_list(mandatory = True),
    },
    config_settings = _MACOS_APPLE_PLUGIN_TEST_SETTINGS,
)

def _apple_plugin_analysis_tests(
        name,
        fixtures,
        platform,
        swift_header_test,
        objc_input_test,
        public_test):
    """Declare the analysis tests over one platform's plugin fixtures.

    Args:
      name: Prefix for the test targets.
      fixtures: The struct returned by `apple_plugin_fixtures`.
      platform: `"ios"` or `"macos"`.
      swift_header_test: The platform's generated-header analysis rule.
      objc_input_test: The platform's ObjC-input analysis rule.
      public_test: The platform's public-provider analysis rule.

    Returns:
      The test target names.
    """
    header = fixtures.mixed_module + "-Swift.h"
    if platform == "ios":
        platform_framework = "UIKit/UIKit.h"
        modulemap = "Flutter.framework/Modules/module.modulemap"
    elif platform == "macos":
        platform_framework = "AppKit/AppKit.h"
        modulemap = "FlutterMacOS.framework/Modules/module.modulemap"
    else:
        fail("apple_plugin_fixtures: platform must be 'ios' or 'macos', got '%s'" % platform)
    swift_header_name = name + "_mixed_swift_header"
    objc_input_name = name + "_mixed_objc_header_input"
    shadow_objc_input_name = name + "_shadow_mixed_objc_header_input"
    public_name = name + "_mixed_public_providers"
    bridging_name = name + "_bridging_header_copts"
    swift_header_test(
        name = swift_header_name,
        target_under_test = ":_" + fixtures.mixed + "__swift",
        expected_header_name = header,
    )
    objc_input_test(
        name = objc_input_name,
        target_under_test = ":_" + fixtures.mixed + "__objc",
        expected_header_basename = header,
        expected_modulemap_suffix = modulemap,
    )
    objc_input_test(
        name = shadow_objc_input_name,
        size = "small",
        target_under_test = ":_" + fixtures.shadow_mixed + "__objc",
        expected_header_basename = fixtures.shadow_module + "-Swift.h",
        excluded_quote_include_suffix = fixtures.shadow_header_dir,
        expected_modulemap_suffix = modulemap,
    )
    public_test(
        name = public_name,
        target_under_test = ":" + fixtures.mixed,
        expected_header_basenames = [fixtures.mixed + ".h", header],
        expected_modulemap_suffix = modulemap,
        expected_module_name = fixtures.mixed_module,
        expected_platform = platform,
        expected_sdk_dylibs = ["sqlite3"],
        expected_sdk_frameworks = ["AVFoundation"],
    )
    pure_objc_headers_name = name + "_pure_objc_modulemap_headers"
    objc_input_test(
        name = pure_objc_headers_name,
        size = "small",
        target_under_test = ":_" + fixtures.pure_objc + "__objc",
        expected_modulemap_suffix = modulemap,
    )
    objc_module_headers_name = name + "_mixed_objc_module_modulemap_headers"
    objc_input_test(
        name = objc_module_headers_name,
        size = "small",
        target_under_test = ":_" + fixtures.mixed + "__objc_module",
        expected_modulemap_suffix = modulemap,
    )
    pure_objc_public_name = name + "_pure_objc_modulemap_public"
    objc_input_test(
        name = pure_objc_public_name,
        size = "small",
        target_under_test = ":" + fixtures.pure_objc,
        expected_modulemap_suffix = modulemap,
    )
    _apple_plugin_bridging_copts_test(
        name = bridging_name,
        bridging_copts = fixtures.bridging_swift_copts,
        expected_header = fixtures.bridging_module + "-Bridging-Header.h",
        mixed_swift_copts = fixtures.mixed_swift_copts,
        platform_framework = platform_framework,
        probe_copt = "-DPLUGIN_BRIDGING=1",
    )

    pure_swift_kinds = {
        fixtures.pure_swift: "swift_library",
    }
    pure_objc_kinds = {
        "_" + fixtures.pure_objc + "__swift_placeholder": "_write_file",
        "_" + fixtures.pure_objc + "__objc": "objc_library",
        fixtures.pure_objc: "swift_library",
    }
    mixed_kinds = {
        "_" + fixtures.mixed + "__objc_module": "objc_library",
        "_" + fixtures.mixed + "__swift": "swift_library",
        "_" + fixtures.mixed + "__swift_include": "_swift_generated_header_include",
        "_" + fixtures.mixed + "__objc": "objc_library",
        fixtures.mixed: "flutter_apple_plugin_bundle",
    }
    attrs_name = name + "_mixed_swift_attrs"
    _apple_plugin_swift_attrs_test(
        name = attrs_name,
        expected_header_name = header,
        observed_generates_header = fixtures.mixed_swift_generates_header,
        observed_header_name = fixtures.mixed_swift_generated_header_name,
    )
    surface_name = name + "_mixed_surface"
    _apple_plugin_surface_test(
        name = surface_name,
        expected_kinds = mixed_kinds,
        observed_kinds = fixtures.mixed_kinds,
    )
    pure_swift_name = name + "_pure_swift_surface"
    _apple_plugin_surface_test(
        name = pure_swift_name,
        expected_kinds = pure_swift_kinds,
        observed_kinds = fixtures.pure_swift_kinds,
    )
    pure_objc_name = name + "_pure_objc_surface"
    _apple_plugin_surface_test(
        name = pure_objc_name,
        expected_kinds = pure_objc_kinds,
        observed_kinds = fixtures.pure_objc_kinds,
    )

    return [
        swift_header_name,
        objc_input_name,
        shadow_objc_input_name,
        public_name,
        pure_objc_headers_name,
        objc_module_headers_name,
        pure_objc_public_name,
        bridging_name,
        attrs_name,
        surface_name,
        pure_swift_name,
        pure_objc_name,
    ]

def ios_apple_plugin_analysis_tests(name, fixtures):
    """Declare the iOS plugin analysis tests over `fixtures`.

    Args:
      name: Prefix for the test targets.
      fixtures: The struct returned by `apple_plugin_fixtures`.

    Returns:
      The test target names.
    """
    return _apple_plugin_analysis_tests(
        name,
        fixtures,
        "ios",
        _ios_mixed_plugin_swift_header_test,
        _ios_mixed_plugin_objc_input_test,
        _ios_apple_plugin_public_test,
    )

def macos_apple_plugin_analysis_tests(name, fixtures):
    """Declare the macOS plugin analysis tests over `fixtures`.

    Args:
      name: Prefix for the test targets.
      fixtures: The struct returned by `apple_plugin_fixtures`.

    Returns:
      The test target names.
    """
    return _apple_plugin_analysis_tests(
        name,
        fixtures,
        "macos",
        _macos_mixed_plugin_swift_header_test,
        _macos_mixed_plugin_objc_input_test,
        _macos_apple_plugin_public_test,
    )
