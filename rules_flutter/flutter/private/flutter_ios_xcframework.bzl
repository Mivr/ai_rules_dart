"""Add-to-app iOS xcframework assembly (private implementation).

Produces the xcframework set an existing Xcode app links for Flutter's
documented add-to-app path:

- `App.xcframework`: a device arm64 slice and an arm64/x86_64 simulator slice,
  both assembled from `flutter_ios_framework`;
- `Flutter.xcframework`: the pinned iOS engine the rules already select for the
  build configuration, symlinked file for file (never copied);
- `FlutterPluginRegistrant.xcframework`: a dynamic framework linked from the
  application's generated `GeneratedPluginRegistrant.swift`;
- one `<Plugin>.xcframework` per native iOS plugin in the application's
  transitive graph.

Layout and every `Info.plist` are written by the Starlark rule. No
`xcodebuild -create-xcframework` runs, and the only tools the actions use are
the `macho_edit` host tool the Apple targets already need and the runner's
existing Swift toolchain.

The public macro lives in `flutter/ios.bzl`; usage is documented there and in
`docs/ios-add-to-app.md`.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION")
load(
    "//flutter/private:flutter_apple_plugins_aggregator.bzl",
    _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator",
)
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_framework_rule = "flutter_ios_framework")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load(
    "//flutter/private:flutter_ios_xcframework_plist.bzl",
    "IOS_DEVICE",
    "IOS_SIMULATOR",
    "framework_info_plist",
    "xcframework_info_plist",
)
load(
    "//flutter/private:flutter_ios_xcframework_transitions.bzl",
    "ios_device_transition",
    "ios_sim_arm64_transition",
    "ios_sim_x64_transition",
)
load("//flutter/private:ios_app.bzl", _flutter_ios_engine = "flutter_ios_engine")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

visibility(["//flutter/..."])

_DART_EXEC_TOOLCHAIN_TYPE = Label("@rules_dart//dart:exec_tools_toolchain_type")

_RESERVED_FRAMEWORKS = ["App", "Flutter", "FlutterPluginRegistrant"]

def validate_xcframework_application(application):
    """Fails with the macro's own message when `application` is missing.

    Args:
        application: The caller's `application` value.
    """
    if not application:
        fail(
            "flutter_ios_xcframeworks: application is required; pass a " +
            "flutter_application target whose xcframeworks an Xcode app links.",
        )

def _framework_members(target, framework_name):
    """Returns the files under one `.framework` directory keyed by relative path."""
    marker = "/%s.framework/" % framework_name
    members = {}
    for f in target[DefaultInfo].files.to_list():
        if marker in f.path:
            members[f.path.rsplit(marker, 1)[1]] = f
    if "Info.plist" not in members:
        fail(
            "flutter_ios_xcframeworks: %s has no %s.framework/Info.plist; " % (
                target.label,
                framework_name,
            ) + "expected a flutter_ios_framework output.",
        )
    return members

def _attr_target(ctx, name):
    """Returns the single target behind a label attribute.

    Attributes with an outgoing Starlark transition reach the implementation as
    a one-element list, so the target is read from index zero; untransitioned
    attributes already hold the target itself.
    """
    value = getattr(ctx.attr, name)
    if type(value) == "list":
        if len(value) != 1:
            fail("flutter_ios_xcframeworks: attribute %s resolved to %d targets; expected one." % (name, len(value)))
        return value[0]
    return value

def _declare_symlink(ctx, path, source):
    """Declares `path` as a symlink to `source` and returns the output file."""
    out = ctx.actions.declare_file(path)
    ctx.actions.symlink(output = out, target_file = source)
    return out

def _copy_tree(ctx, source, path):
    """Copies a framework's tree artifact into this xcframework slice."""
    out = ctx.actions.declare_directory(path)
    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "copy-assets",
            "--src",
            source.path,
            "--dst",
            out.path,
        ],
        inputs = depset(
            direct = [source, ctx.executable._macho_edit],
        ),
        outputs = [out],
        mnemonic = "FlutterIOSXcframeworkAssets",
        progress_message = "Copying App.framework assets into %s" % ctx.label,
        toolchain = _DART_EXEC_TOOLCHAIN_TYPE,
    )
    return out

def _fat_binary(ctx, arm64, x86_64, output):
    """Builds one universal simulator Mach-O from its two thin slices."""
    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "fat",
            "--output",
            output.path,
            arm64.path,
            x86_64.path,
        ],
        inputs = depset(
            direct = [arm64, x86_64, ctx.executable._macho_edit],
        ),
        outputs = [output],
        mnemonic = "FlutterIOSXcframeworkFat",
        progress_message = "Building universal simulator binary for %s" % ctx.label,
        toolchain = _DART_EXEC_TOOLCHAIN_TYPE,
    )

def _patch_binary(ctx, source, output, platform, minimum_os_version, install_name):
    """Retags one linked binary as an iOS framework executable."""
    ctx.actions.run(
        executable = ctx.executable._macho_edit,
        arguments = [
            "patch",
            "--input",
            source.path,
            "--output",
            output.path,
            "--platform",
            platform,
            "--min-os",
            minimum_os_version,
            "--sdk-version",
            minimum_os_version,
            "--install-name",
            install_name,
        ],
        inputs = depset(
            direct = [source, ctx.executable._macho_edit],
        ),
        outputs = [output],
        mnemonic = "FlutterIOSXcframeworkPatch",
        progress_message = "Retagging %s for %s" % (source.basename, platform),
        toolchain = _DART_EXEC_TOOLCHAIN_TYPE,
    )

def _single_binary(target):
    """Returns the one linkable binary a target produced."""
    files = [f for f in target[DefaultInfo].files.to_list() if not f.is_directory]
    for f in files:
        if f.extension in ("dylib", "so"):
            return f
    for f in files:
        if f.basename in ("App", target.label.name):
            return f
    if len(files) == 1:
        return files[0]
    fail(
        "flutter_ios_xcframeworks: %s produced %d files and none is a " % (
            target.label,
            len(files),
        ) + "dynamic library; expected the registrant's linked binary.",
    )

def _app_xcframework(ctx):
    """Declares App.xcframework and returns its outputs and runfiles."""
    device = _framework_members(_attr_target(ctx, "device_app_framework"), "App")
    sim_arm64 = _framework_members(_attr_target(ctx, "sim_arm64_app_framework"), "App")
    sim_x64 = _framework_members(_attr_target(ctx, "sim_x64_app_framework"), "App")

    root = ctx.label.name + "/App.xcframework"
    outputs = []

    device_dir = root + "/%s/App.framework" % IOS_DEVICE
    device_binary = _declare_symlink(ctx, device_dir + "/App", device["App"])
    outputs.append(device_binary)
    outputs.append(_declare_symlink(ctx, device_dir + "/Info.plist", device["Info.plist"]))
    outputs.append(_copy_tree(ctx, device["flutter_assets"], device_dir + "/flutter_assets"))

    sim_dir = root + "/%s/App.framework" % IOS_SIMULATOR
    sim_binary = ctx.actions.declare_file(sim_dir + "/App")
    _fat_binary(ctx, sim_arm64["App"], sim_x64["App"], sim_binary)
    outputs.append(sim_binary)
    outputs.append(_declare_symlink(ctx, sim_dir + "/Info.plist", sim_arm64["Info.plist"]))
    outputs.append(_copy_tree(ctx, sim_arm64["flutter_assets"], sim_dir + "/flutter_assets"))

    info_plist = ctx.actions.declare_file(root + "/Info.plist")
    ctx.actions.write(info_plist, xcframework_info_plist("App"))
    outputs.append(info_plist)
    return outputs

def _flutter_xcframework(ctx):
    """Declares Flutter.xcframework by symlinking the pinned engine's files."""
    files = ctx.attr.engine[DefaultInfo].files.to_list()
    marker = "/Flutter.xcframework/"
    root = ctx.label.name + "/Flutter.xcframework"
    outputs = []
    for f in files:
        if marker not in f.path:
            continue
        relative = f.path.rsplit(marker, 1)[1]
        outputs.append(_declare_symlink(ctx, root + "/" + relative, f))
    if not any([o.basename == "Info.plist" for o in outputs]):
        fail(
            "flutter_ios_xcframeworks: engine %s has no Flutter.xcframework/Info.plist; " % ctx.attr.engine.label +
            "expected the pinned Flutter.xcframework filegroup.",
        )
    return outputs

def _registrant_xcframework(ctx):
    """Declares FlutterPluginRegistrant.xcframework from linked registrants."""
    root = ctx.label.name + "/FlutterPluginRegistrant.xcframework"
    device_patched = ctx.actions.declare_file("__%s_registrant_device" % ctx.label.name)
    arm64_patched = ctx.actions.declare_file("__%s_registrant_sim_arm64" % ctx.label.name)
    x64_patched = ctx.actions.declare_file("__%s_registrant_sim_x64" % ctx.label.name)
    install_name = "@rpath/FlutterPluginRegistrant.framework/FlutterPluginRegistrant"
    _patch_binary(
        ctx,
        _single_binary(_attr_target(ctx, "device_registrant")),
        device_patched,
        "ios",
        ctx.attr.minimum_os_version,
        install_name,
    )
    _patch_binary(
        ctx,
        _single_binary(_attr_target(ctx, "sim_arm64_registrant")),
        arm64_patched,
        "iossim",
        ctx.attr.minimum_os_version,
        install_name,
    )
    _patch_binary(
        ctx,
        _single_binary(_attr_target(ctx, "sim_x64_registrant")),
        x64_patched,
        "iossim",
        ctx.attr.minimum_os_version,
        install_name,
    )

    outputs = []
    device_dir = root + "/%s/FlutterPluginRegistrant.framework" % IOS_DEVICE
    outputs.append(_declare_symlink(ctx, device_dir + "/FlutterPluginRegistrant", device_patched))
    outputs.append(_write_framework_plist(ctx, device_dir, "FlutterPluginRegistrant", ctx.attr.minimum_os_version))

    sim_dir = root + "/%s/FlutterPluginRegistrant.framework" % IOS_SIMULATOR
    sim_binary = ctx.actions.declare_file(sim_dir + "/FlutterPluginRegistrant")
    _fat_binary(ctx, arm64_patched, x64_patched, sim_binary)
    outputs.append(sim_binary)
    outputs.append(_write_framework_plist(ctx, sim_dir, "FlutterPluginRegistrant", ctx.attr.minimum_os_version))

    info_plist = ctx.actions.declare_file(root + "/Info.plist")
    ctx.actions.write(info_plist, xcframework_info_plist("FlutterPluginRegistrant"))
    outputs.append(info_plist)
    return outputs

def _write_framework_plist(ctx, directory, name, minimum_os_version):
    """Writes the framework `Info.plist` inside one slice and returns it."""
    out = ctx.actions.declare_file(directory + "/Info.plist")
    ctx.actions.write(out, framework_info_plist(
        name,
        minimum_os_version,
        "io.flutter.flutter.plugin.%s" % name.lower().replace("_", "-"),
    ))
    return out

def _plugin_name(entry):
    """Returns the framework name for one plugin library entry."""
    if entry.package:
        return entry.package
    return entry.label.name

def _plugin_binary(entry):
    """Returns the compiled plugin file that becomes the framework binary."""
    files = [f for f in entry.files.to_list() if not f.is_directory]
    for f in files:
        if f.extension in ("a", "dylib"):
            return f
    if files:
        return files[0]
    fail(
        "flutter_ios_xcframeworks: plugin %s has no compiled files; " % entry.label +
        "expected an ios_libs/flutter_apple_plugin_library target with sources.",
    )

def _plugin_binaries(application):
    """Maps each native iOS plugin framework name to its compiled archive."""
    binaries = {}
    for entry in application[FlutterApplicationInfo].apple_plugin_libraries.to_list():
        if entry.platform != "ios":
            continue
        name = _plugin_name(entry)
        if name in _RESERVED_FRAMEWORKS:
            fail(
                "flutter_ios_xcframeworks: plugin framework name %r collides " % name +
                "with the add-to-app framework of the same name; rename the plugin package.",
            )
        if name not in binaries:
            binaries[name] = _plugin_binary(entry)
    return binaries

def _plugin_xcframeworks(ctx):
    """Declares one xcframework per native iOS plugin in the application graph.

    The device slice holds the archive built for iOS devices. The simulator
    slice holds a universal archive fused from the arm64 and x86_64 simulator
    builds of the same plugin, so every slice carries code for its own platform.
    """
    device = _plugin_binaries(_attr_target(ctx, "application"))
    sim_arm64 = _plugin_binaries(_attr_target(ctx, "sim_arm64_application"))
    sim_x64 = _plugin_binaries(_attr_target(ctx, "sim_x64_application"))
    outputs = []
    for name, binary in device.items():
        if name not in sim_arm64 or name not in sim_x64:
            fail(
                "flutter_ios_xcframeworks: plugin %s is built for devices but not for " % name +
                "the simulator; give its ios_libs the same platform conditions for both.",
            )
        root = "%s/%s.xcframework" % (ctx.label.name, name)
        device_dir = "%s/%s/%s.framework" % (root, IOS_DEVICE, name)
        outputs.append(_declare_symlink(ctx, device_dir + "/" + name, binary))
        outputs.append(_write_framework_plist(ctx, device_dir, name, ctx.attr.minimum_os_version))

        sim_dir = "%s/%s/%s.framework" % (root, IOS_SIMULATOR, name)
        sim_binary = ctx.actions.declare_file(sim_dir + "/" + name)
        _fat_binary(ctx, sim_arm64[name], sim_x64[name], sim_binary)
        outputs.append(sim_binary)
        outputs.append(_write_framework_plist(ctx, sim_dir, name, ctx.attr.minimum_os_version))

        info_plist = ctx.actions.declare_file(root + "/Info.plist")
        ctx.actions.write(info_plist, xcframework_info_plist(name))
        outputs.append(info_plist)
    return outputs

def _flutter_ios_xcframework_impl(ctx):
    """Assembles the App, Flutter, registrant and plugin xcframeworks."""
    outputs = _app_xcframework(ctx)
    outputs.extend(_flutter_xcframework(ctx))
    outputs.extend(_registrant_xcframework(ctx))
    outputs.extend(_plugin_xcframeworks(ctx))

    transitive = [
        target[DefaultInfo].files
        for target in [
            _attr_target(ctx, "device_app_framework"),
            _attr_target(ctx, "sim_arm64_app_framework"),
            _attr_target(ctx, "sim_x64_app_framework"),
            _attr_target(ctx, "device_registrant"),
            _attr_target(ctx, "sim_arm64_registrant"),
            _attr_target(ctx, "sim_x64_registrant"),
            ctx.attr.engine,
        ]
    ]
    for application in [_attr_target(ctx, "application"), _attr_target(ctx, "sim_arm64_application"), _attr_target(ctx, "sim_x64_application")]:
        for entry in application[FlutterApplicationInfo].apple_plugin_libraries.to_list():
            transitive.append(entry.files)
    return [DefaultInfo(
        files = depset(outputs),
        runfiles = ctx.runfiles(transitive_files = depset(transitive = transitive)),
    )]

flutter_ios_xcframework = rule(
    implementation = _flutter_ios_xcframework_impl,
    attrs = dicts.add({
        "application": attr.label(
            doc = "A flutter_application target whose plugins become xcframeworks, read in the device configuration so its iOS device plugin libraries are selected.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
            cfg = ios_device_transition,
        ),
        "sim_arm64_application": attr.label(
            doc = "The same flutter_application target, read in the simulator arm64 configuration so its simulator plugin archives are selected.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
            cfg = ios_sim_arm64_transition,
        ),
        "sim_x64_application": attr.label(
            doc = "The same flutter_application target, read in the simulator x86_64 configuration so its simulator plugin archives are selected.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
            cfg = ios_sim_x64_transition,
        ),
        "device_app_framework": attr.label(
            doc = "The device arm64 App.framework target, built through the device transition.",
            mandatory = True,
            cfg = ios_device_transition,
        ),
        "sim_arm64_app_framework": attr.label(
            doc = "The simulator arm64 App.framework target, built through the simulator transition.",
            mandatory = True,
            cfg = ios_sim_arm64_transition,
        ),
        "sim_x64_app_framework": attr.label(
            doc = "The simulator x86_64 App.framework target, built through the simulator transition.",
            mandatory = True,
            cfg = ios_sim_x64_transition,
        ),
        "device_registrant": attr.label(
            doc = "The device arm64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = ios_device_transition,
        ),
        "sim_arm64_registrant": attr.label(
            doc = "The simulator arm64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = ios_sim_arm64_transition,
        ),
        "sim_x64_registrant": attr.label(
            doc = "The simulator x86_64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = ios_sim_x64_transition,
        ),
        "engine": attr.label(
            doc = "The pinned Flutter.xcframework filegroup for the active configuration.",
            mandatory = True,
            allow_files = True,
        ),
        "minimum_os_version": attr.string(
            doc = "Minimum iOS deployment target written into every new framework plist.",
            default = IOS_MINIMUM_OS_VERSION,
        ),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
            doc = "The `macho_edit` host tool that retags and fuses Mach-O slices.",
        ),
    }),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Assembles App, Flutter, plugin-registrant and plugin xcframeworks for add-to-app.",
)

def flutter_ios_xcframeworks(name, application = None, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Builds the xcframework set an existing Xcode app links (add-to-app).

    See `flutter/ios.bzl` for the public documentation of every argument.

    Args:
        name: Target name; its files are the xcframework set.
        application: A `flutter_application` target (required).
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Common target attributes (e.g. `visibility`, `tags`,
            `target_compatible_with`).
    """
    validate_xcframework_application(application)
    validate_minimum_os_version(
        "flutter_ios_xcframeworks",
        name,
        minimum_os_version,
        IOS_MINIMUM_OS_VERSION,
        "iOS",
    )

    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]
    visibility = kwargs.pop("visibility", None)
    target_compatible_with = kwargs.pop("target_compatible_with", ["@platforms//os:macos"])

    for suffix, platform in [
        ("device_app_framework", "device"),
        ("sim_arm64_app_framework", "simulator"),
        ("sim_x64_app_framework", "simulator"),
    ]:
        _flutter_ios_framework_rule(
            name = "__%s_%s" % (name, suffix),
            application = application,
            minimum_os_version = minimum_os_version,
            allow_simulator_aot = platform == "simulator",
            tags = internal_tags,
        )

    _flutter_ios_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = internal_tags,
    )
    _flutter_ios_engine(
        name = "__%s_engine" % name,
        tags = internal_tags,
    )
    _flutter_apple_plugins_aggregator(
        name = "__%s_plugins" % name,
        application = application,
        platform = "ios",
        tags = internal_tags,
    )
    swift_library(
        name = "__%s_registrant_lib" % name,
        srcs = [":__%s_registrant" % name],
        module_name = "GeneratedPluginRegistrant",
        deps = [
            ":__%s_engine" % name,
            ":__%s_plugins" % name,
        ],
        tags = internal_tags,
    )
    cc_binary(
        name = "__%s_registrant_binary" % name,
        deps = [":__%s_registrant_lib" % name],
        linkshared = True,
        tags = internal_tags,
    )

    flutter_ios_xcframework(
        name = name,
        application = application,
        sim_arm64_application = application,
        sim_x64_application = application,
        device_app_framework = ":__%s_device_app_framework" % name,
        sim_arm64_app_framework = ":__%s_sim_arm64_app_framework" % name,
        sim_x64_app_framework = ":__%s_sim_x64_app_framework" % name,
        device_registrant = ":__%s_registrant_binary" % name,
        sim_arm64_registrant = ":__%s_registrant_binary" % name,
        sim_x64_registrant = ":__%s_registrant_binary" % name,
        engine = select({
            Label("@rules_flutter//flutter/private:dbg"): Label("@flutter_ios_engine//:Flutter_xcframework_debug"),
            Label("@rules_flutter//flutter/private:profile"): Label(
                "@flutter_ios_engine_profile//:Flutter_xcframework",
            ),
            "//conditions:default": Label("@flutter_ios_engine//:Flutter_xcframework"),
        }),
        minimum_os_version = minimum_os_version,
        tags = tags,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
        **kwargs
    )
