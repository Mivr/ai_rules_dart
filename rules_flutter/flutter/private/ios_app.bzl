"""Tier 1 iOS application assembly (private implementation).

Holds `flutter_ios_app` with the engine import, the internal build steps and
the storyboard constants the bundle resolves. `flutter/ios.bzl` loads the
public names back and re-exports them, so user BUILD files are unaffected.

Usage: see flutter/ios.bzl for public API.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_apple//apple:ios.bzl", "ios_application")
load("@rules_apple//apple:resources.bzl", "apple_resource_group")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _IOS_MINIMUM_OS_VERSION = "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load(
    "//flutter/private:flutter_ios_application.bzl",
    _flutter_ios_application = "flutter_ios_application",
    _flutter_ios_framework_rule = "flutter_ios_framework",
    _flutter_ios_native_frameworks_rule = "flutter_ios_native_frameworks",
    _flutter_ios_privacy_manifests_rule = "flutter_ios_privacy_manifests",
)
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:flutter_xtool_bundle.bzl", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import", _flutter_xtool_ios_bundle = "flutter_xtool_ios_bundle")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")
load("//flutter/private:xtool_version.bzl", _resolve_xtool_version = "resolve_xtool_version")

visibility(["//flutter/..."])

IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION

IOS_DEFAULT_LAUNCH_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard"
IOS_DEFAULT_MAIN_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"

# The Dart VM service's Info.plist keys, merged into non-release builds so
# the engine can advertise the service over mDNS. Matches flutter_tools'
# xcode_backend.dart, which only adds them for non-release configurations.
_DART_VM_SERVICE_PLIST = "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist"

def _engine_xcframework_select():
    """Selects the Flutter.xcframework engine for the active compilation mode.

    Debug (-c dbg): JIT engine (simulator). Profile (-c opt with
    `//flutter:profile`): the profile AOT engine (device). Release (-c opt /
    default): AOT engine (device). The labels resolve through rules_flutter's
    own repo mapping, so a consumer needs none of these repos in `use_repo`.
    """
    return select({
        Label("@rules_flutter//flutter/private:dbg"): [Label("@flutter_ios_engine//:Flutter_xcframework_debug")],
        Label("@rules_flutter//flutter/private:profile"): [Label("@flutter_ios_engine_profile//:Flutter_xcframework")],
        "//conditions:default": [Label("@flutter_ios_engine//:Flutter_xcframework")],
    })

# rule_test_coverage: no-actions
def flutter_ios_engine(name, backend = "rules_apple", **kwargs):
    """Imports the Flutter.xcframework engine, auto-selecting debug or release.

    Debug mode (-c dbg): JIT engine for simulator.
    Release mode (-c opt / default): AOT engine for device.

    Args:
        name: Target name. Add to swift_library deps for runner.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_engine: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])

    if backend == "rules_apple":
        apple_dynamic_xcframework_import(
            name = name,
            xcframework_imports = _engine_xcframework_select(),
            tags = tags,
            **kwargs
        )
    else:
        _flutter_darwin_xcframework_import(
            name = name,
            framework_name = "Flutter",
            xcframework_imports = _engine_xcframework_select(),
            tags = tags,
            **kwargs
        )

def _ios_resolve_entitlements(name, entitlements, additional_entitlements, internal_tags):
    """Discovers the Runner entitlements and folds the app's additions in.

    `base` may legitimately be None here: an iOS app without Xcode
    capabilities ships no entitlements file, and then the additions are the
    entitlements.
    """
    resolved = resolve_ios_entitlements(
        entitlements,
        discovered = "ios/Runner/Runner.entitlements" if native.glob(
            ["ios/Runner/Runner.entitlements"],
            allow_empty = True,
        ) else None,
    )
    if additional_entitlements:
        _flutter_entitlements_merge(
            name = "__%s_entitlements" % name,
            base = resolved,
            additions = additional_entitlements,
            tags = internal_tags,
        )
        resolved = "__%s_entitlements" % name
    return resolved

def _ios_discover_app_icons(app_icons, backend):
    """Discovers the conventional asset catalog `flutter create` writes.

    `None` means discover, `[]` means ship none: both states are sayable, and
    an app with no catalog at all is the second without having to write it.
    """
    if app_icons == None and backend == "rules_apple":
        return native.glob(
            ["ios/Runner/Assets.xcassets/AppIcon.appiconset/**"],
            allow_empty = True,
        )
    return app_icons

def _ios_registrant_settings(generated_registrant, exclude_plugins):
    """Groups the plugin-registrant options the app passes down.

    Args:
        generated_registrant: Whether the macro generates the Swift registrant.
        exclude_plugins: Plugin module names left out of the generated registrant.

    Returns:
        A struct with `generated` and `exclude_plugins`.
    """
    return struct(
        generated = generated_registrant,
        exclude_plugins = exclude_plugins,
    )

def _ios_build_frameworks(name, application, patching, backend, engine, registrant, internal_tags):
    """Emits the registrant, intermediates, App.framework and engine targets.

    Args:
        name: The app name; internal targets derive from it.
        application: The flutter_application target.
        patching: Struct of `minimum_os_version` (minimum iOS version) and `allow_non_macho` (binary
            names allowed through unpatched).
        backend: Apple bundling backend.
        engine: The caller's engine target, or None to generate one.
        registrant: The registrant settings struct.
        internal_tags: Tags for the generated targets.

    Returns:
      The engine target label to link the runner against.
    """

    # 1. Generate iOS Swift plugin registrant. An app that supplies its own
    #    registrant, through `generated_registrant = False` and an
    #    `additional_deps` library, names no target here at all.
    if registrant.generated:
        _flutter_ios_registrant_rule(
            name = "__%s_registrant" % name,
            application = application,
            exclude_plugins = registrant.exclude_plugins,
            tags = internal_tags,
        )

    # 2. Extract intermediates (AOT dylib + flutter_assets + native_libs).
    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = internal_tags,
    )

    # 3. Assemble App.framework from the AOT dylib (or debug stub + kernel).
    #    On rules_apple a debug build leaves flutter_assets out of the
    #    framework so the import processor does not re-copy the kernel on
    #    every Dart edit. The xtool bundle reads the assets from the framework
    #    it receives, so it keeps the base layout.
    _flutter_ios_framework_rule(
        name = "__%s_app_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = patching.minimum_os_version,
        allow_non_macho = patching.allow_non_macho,
        split_debug_assets = backend == "rules_apple",
        tags = internal_tags,
    )

    # 4. Wrap App.framework for rules_apple.
    #    In debug mode, bundle_only=True embeds the framework without linking
    #    (the stub binary only exists for rules_apple compatibility and isn't
    #    loaded at runtime — Flutter uses the JIT kernel blob instead).
    if backend == "rules_apple":
        # 4a. Read the split debug assets out of the framework's output group
        #     and let the bundle place them at the app root. The strip prefix
        #     is this target's own framework directory, so the directory
        #     arrives as `flutter_assets/...` beside the app binary. An AOT
        #     build's output group is empty and no root copy is added.
        native.filegroup(
            name = "__%s_split_debug_assets" % name,
            srcs = [":__%s_app_framework" % name],
            output_group = "flutter_assets",
            tags = internal_tags,
        )
        apple_resource_group(
            name = "__%s_split_debug_assets_group" % name,
            structured_resources = [":__%s_split_debug_assets" % name],
            strip_structured_resources_prefixes = [
                "__%s_app_framework/App.framework" % name,
                "__%s_app_framework/kernel" % name,
            ],
            tags = internal_tags,
        )
        apple_dynamic_framework_import(
            name = "__%s_app_bundle" % name,
            framework_imports = ["__%s_app_framework" % name],
            bundle_only = select({Label("@rules_flutter//flutter/private:dbg"): True, "//conditions:default": False}),
            tags = internal_tags,
        )

    # 5. Import Flutter.xcframework engine — auto-selects debug/release and backend.
    if engine:
        return engine
    flutter_ios_engine(
        name = "__%s_engine" % name,
        backend = backend,
        tags = internal_tags,
    )
    return "__%s_engine" % name

def _ios_build_native_frameworks(name, application, patching, internal_tags):
    """Wraps native plugin/native-asset dylibs in .frameworks for bundling.

    Args:
        name: The app name; internal targets derive from it.
        application: The flutter_application target.
        patching: Struct of `minimum_os_version` and `allow_non_macho`.
        internal_tags: Tags for the generated targets.
    """

    # 6. Wrap native plugin/native-asset dylibs in .frameworks for bundling.
    _flutter_ios_native_frameworks_rule(
        name = "__%s_native_frameworks" % name,
        application = application,
        minimum_os_version = patching.minimum_os_version,
        allow_non_macho = patching.allow_non_macho,
        tags = internal_tags,
    )

    # 6b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_ios_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = internal_tags,
    )

def _ios_discover_runner_srcs(srcs):
    """Discovers the runner Swift sources, failing when there are none."""
    runner_srcs = srcs if srcs != None else native.glob(["ios/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in ios/Runner/. " +
             "Run 'flutter create --platforms=ios .' to generate runner files.")
    return runner_srcs

def _ios_resolve_info_plist(name, info_plist, module_name, internal_tags):
    """Preprocesses the Info.plist to resolve Xcode variables rules_apple misses."""
    if info_plist:
        return info_plist
    expand_template(
        name = "__%s_info_plist" % name,
        template = "ios/Runner/Info.plist",
        out = "__%s_Info.plist" % name,
        substitutions = {
            "$(DEVELOPMENT_LANGUAGE)": "en",
            # UISceneDelegateClassName is <module>.SceneDelegate: the
            # flutter create SceneDelegate carries no @objc, so its
            # runtime name is module-qualified and must track module_name.
            "$(PRODUCT_MODULE_NAME)": module_name,
            "$(FLUTTER_BUILD_NAME)": "1.0",
            "$(FLUTTER_BUILD_NUMBER)": "1",
        },
        tags = internal_tags,
    )
    return "__%s_info_plist" % name

def _ios_resolve_version(name, backend, version, internal_tags, kwargs):
    """Creates the default apple_bundle_version (rules_apple) or resolves it (xtool).

    Returns:
      A `(version, invalid_version_error)` tuple.
    """
    if backend == "rules_apple":
        if not version:
            apple_bundle_version(
                name = "__%s_version" % name,
                build_version = "1.0",
                short_version_string = "1.0",
                tags = internal_tags,
            )
            return ":%s" % ("__%s_version" % name), ""
        return version, ""
    version, version_bv, version_sv, invalid_version_error = _resolve_xtool_version(
        name,
        "flutter_ios_app",
        version,
        internal_tags,
    )
    if version_bv and "build_version" not in kwargs:
        kwargs["build_version"] = version_bv
    if version_sv and "short_version" not in kwargs:
        kwargs["short_version"] = version_sv
    return version, invalid_version_error

def _ios_resolve_launch_storyboard(launch_storyboard, backend):
    """Resolves the launch storyboard, discovering the conventional one."""
    if launch_storyboard == False:
        return None
    if not launch_storyboard:
        launch_candidates = native.glob(["ios/Runner/Base.lproj/LaunchScreen.storyboard"], allow_empty = True)
        if launch_candidates:
            return launch_candidates[0]
        if backend == "rules_apple":
            return IOS_DEFAULT_LAUNCH_STORYBOARD
    return launch_storyboard

def _ios_dev_infoplists(name, actual_info_plist, internal_tags):
    """Merges the Dart VM service keys into a dev Info.plist and selects it.

    The keys are *merged into* the app's Info.plist rather than passed
    beside it. rules_apple's plisttool hard-fails when two plists
    declare the same key with different values, so an app declaring
    its own NSLocalNetworkUsageDescription — the documented way to
    request iOS 14+ Local Network Privacy, and the key a LAN app
    needs in release — could not build in `-c dbg` at all. The
    supplement merge keeps the app's own values and unions its
    NSBonjourServices with `_dartVmService._tcp`.
    """
    _flutter_plist_merge(
        name = "__%s_info_plist_dev" % name,
        base = actual_info_plist,
        additions = [_DART_VM_SERVICE_PLIST],
        mode = "supplement",
        output_basename = "Info.plist",
        tags = internal_tags,
    )
    return select({
        "@rules_flutter//flutter:release": [actual_info_plist],
        "//conditions:default": ["__%s_info_plist_dev" % name],
    })

def _ios_build_runner(name, runner):
    """Aggregates Apple plugins and builds the runner swift_library (rules_apple backend only).

    Args:
        name: The app name; internal targets derive from it.
        runner: Struct with `application`, `backend`, `engine_target`,
            `srcs` (discovered runner Swift sources), `registrant_srcs` (the
            generated registrant, or none), `copts` (the caller's
            `swift_copts`, left unset when empty), `module_name`, `deps`
            (extra runner deps),
            `internal_tags`, and `discovered_main_storyboard`.
    """
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = runner.application,
        platform = "ios",
        tags = runner.internal_tags,
    )

    if runner.backend == "rules_apple":
        swift_library(
            name = "__%s_runner" % name,
            srcs = runner.srcs + runner.registrant_srcs,
            data = runner.discovered_main_storyboard,
            module_name = runner.module_name,
            # An empty `swift_copts` leaves the attribute unset, so the
            # runner `swift_library` an app declares today is unchanged.
            # Only a caller's flags add the attribute.
            copts = runner.copts if runner.copts else None,
            tags = runner.internal_tags,
            deps = [
                runner.engine_target,
                "__%s_apple_plugins" % name,
            ] + runner.deps,
        )

_SKIP_SIM_CODESIGN = "apple.skip_codesign_simulator_bundles"

def _ios_rules_apple_features(kwargs):
    """Returns the `features` for the rules_apple bundle, with the debug default.

    A `-c dbg` build enables rules_apple's `apple.skip_codesign_simulator_bundles`
    (rules_apple applies it to simulator bundles only, so device signing is
    untouched); other modes keep the caller's list. The caller's features follow
    the default, so `-apple.skip_codesign_simulator_bundles` wins, and a caller
    who lists the feature already gets it once.

    Args:
        kwargs: The macro's pass-through attributes, read for `features`.

    Returns:
        The `features` value for `ios_application`.
    """
    caller = kwargs.get("features", [])
    if type(caller) == "list" and _SKIP_SIM_CODESIGN in caller:
        return caller
    return select({
        Label("@rules_flutter//flutter/private:dbg"): [_SKIP_SIM_CODESIGN] + caller,
        "//conditions:default": caller,
    })

def _ios_emit_rules_apple_bundle(name, bundle):
    """Emits the final rules_apple ios_application bundle target.

    Args:
        name: The app target name.
        bundle: The final bundle's settings struct.
    """
    kwargs = dict(bundle.kwargs)
    kwargs["features"] = _ios_rules_apple_features(kwargs)

    # A debug build carries the split flutter_assets at the app root; an AOT
    # build keeps them inside App.framework and gets no root copy.
    root_assets = select({
        Label("@rules_flutter//flutter/private:dbg"): ["__%s_split_debug_assets_group" % name],
        "//conditions:default": [],
    })
    ios_application(
        name = name,
        bundle_id = bundle.bundle_id,
        bundle_name = bundle.display_name,
        entitlements = bundle.entitlements,
        families = bundle.families,
        minimum_os_version = bundle.minimum_os_version,
        infoplists = bundle.selected_infoplists,
        version = bundle.version,
        launch_storyboard = bundle.actual_launch_storyboard,
        provisioning_profile = bundle.provisioning_profile,
        app_icons = bundle.app_icons,
        resources = bundle.resources + ["__%s_privacy_manifests" % name] + root_assets,
        deps = [
            "__%s_runner" % name,
            "__%s_app_bundle" % name,
            "__%s_native_frameworks" % name,
        ] + bundle.additional_deps,
        tags = bundle.tags,
        visibility = bundle.visibility,
        **kwargs
    )

def _ios_emit_xtool_bundle(name, bundle, invalid_version_error, runner):
    """Emits the final xtool iOS bundle target, forwarding only its kwargs.

    Args:
        name: The app name; internal targets derive from it.
        bundle: The final bundle's settings struct.
        invalid_version_error: The version error the rule reports, or None.
        runner: The runner struct `_ios_build_runner` takes; the bundle reads its
            `srcs`, `deps`, `engine_target` and `discovered_main_storyboard`.
    """
    valid_xtool_kwargs = (
        "additional_contents",
        "build_version",
        "certificate",
        "certificate_password",
        "certificate_password_env",
        "certificate_password_file",
        "compatible_with",
        "defines",
        "env",
        "exec_compatible_with",
        "executable",
        "features",
        "require_sdk",
        "restricted_to",
        "short_version",
        "target_compatible_with",
        "testonly",
        "zsign",
    )
    forwarded_kwargs = {k: v for k, v in bundle.kwargs.items() if k in valid_xtool_kwargs}
    unsupported_kwargs = [k for k in bundle.kwargs if k not in valid_xtool_kwargs]
    _flutter_xtool_ios_bundle(
        name = name,
        app_name = bundle.display_name,
        bundle_id = bundle.bundle_id,
        families = bundle.families,
        minimum_os_version = bundle.minimum_os_version,
        version = bundle.version,
        invalid_version_error = invalid_version_error,
        infoplists = bundle.selected_infoplists,
        launch_storyboard = bundle.actual_launch_storyboard,
        app_icons = bundle.app_icons if bundle.app_icons != None else [],
        srcs = runner.srcs,
        registrant = bundle.registrant,
        plugins = [":__%s_apple_plugins" % name],
        deps = runner.deps + bundle.additional_deps,
        frameworks = [
            ":__%s_app_framework" % name,
            runner.engine_target,
            ":__%s_native_frameworks" % name,
        ],
        resources = bundle.resources + runner.discovered_main_storyboard + ["__%s_privacy_manifests" % name],
        provisioning_profile = bundle.provisioning_profile,
        entitlements = bundle.entitlements if bundle.entitlements != False else None,
        tags = bundle.tags,
        visibility = bundle.visibility,
        unsupported_kwargs = unsupported_kwargs,
        **forwarded_kwargs
    )

def _ios_analysis_error_impl(ctx):
    """Fails analysis with the error the macro selected."""
    fail(ctx.attr.message)

_ios_analysis_error = rule(
    implementation = _ios_analysis_error_impl,
    attrs = {
        "message": attr.string(
            mandatory = True,
            doc = "The analysis-time failure text, including the app target's name.",
        ),
    },
    doc = "Stands in for a bundle target that cannot be built, failing analysis with a named error.",
)

# Attributes that ask for code signing. With `signing = False` they contradict
# the request, so the macro refuses them instead of silently dropping them.
_SIGNING_ATTRIBUTES = (
    "certificate",
    "certificate_password",
    "certificate_password_env",
    "certificate_password_file",
    "zsign",
)

def _ios_unsigned_conflict(name, kwargs):
    """Returns the analysis error for signing attributes passed to an unsigned build.

    Args:
        name: The app target name, for the error message.
        kwargs: Pass-through attributes, read for signing-only attributes.

    Returns:
        The conflict message, or None when no signing attribute is present.
    """
    conflicts = [key for key in _SIGNING_ATTRIBUTES if key in kwargs]
    if not conflicts:
        return None
    return (
        "%s: signing = False conflicts with %s; an unsigned build cannot use attributes that ask for signing" %
        (name, ", ".join(["'%s'" % key for key in conflicts]))
    )

def _ios_attribute_error(name, registrant, backend, swift_copts):
    """Returns the analysis error for a registrant or Swift-flag conflict, if any.

    `exclude_plugins` edits the registrant the macro generates, so it cannot
    be combined with `generated_registrant = False`. The xtool bundle rule
    compiles the runner itself and has no seam for caller Swift flags, so a
    non-empty `swift_copts` is refused there instead of being dropped.

    Args:
        name: The app target name, for the error message.
        registrant: The registrant settings struct.
        backend: Apple bundling backend.
        swift_copts: The caller's extra runner Swift flags.

    Returns:
        The conflict message, or None when the attributes do not conflict.
    """
    if not registrant.generated and registrant.exclude_plugins:
        return (
            "flutter_ios_app: %s: 'generated_registrant' = False conflicts with 'exclude_plugins'; " +
            "exclude_plugins only edits a registrant the macro does not generate"
        ) % name
    if backend == "xtool" and swift_copts:
        return (
            "flutter_ios_app: %s: 'swift_copts' is not supported on the 'xtool' backend; " +
            "the xtool bundle rule compiles the runner itself and cannot take caller Swift flags"
        ) % name
    return None

def _ios_apply_signing_options(name, backend, signing, provisioning_profile, kwargs):
    """Resolves the analysis-time failure an unsigned build must raise, if any.

    Signing defaults to true, so nothing is checked and the caller's `features`
    pass through untouched. On `xtool`, an unsigned build keeps that feature
    list as well: its packer writes an unsigned bundle, and rules_apple's
    signing features have no meaning there. A rules_apple device build always
    requires a `provisioning_profile`, so an unsigned one is refused with a
    named analysis error instead of reaching rules_apple's own failure. On
    `xtool`, a `provisioning_profile` beside `signing = False` is the same
    contradiction it always was, and attributes that ask for signing are a
    conflict reported at analysis.

    Args:
        name: The app target name, for the error message.
        backend: Apple bundling backend.
        signing: Whether the app is code signed.
        provisioning_profile: The caller's provisioning profile label, or None.
        kwargs: Pass-through attributes, read for signing-only attributes.

    Returns:
        The analysis-time failure message for an unsigned build, or None.
    """
    if signing:
        return None
    if backend == "rules_apple":
        return (
            "%s: cannot build this app unsigned on the 'rules_apple' backend: " +
            "rules_apple requires a 'provisioning_profile' for every device build, " +
            "and an unsigned device bundle is not available on that backend; " +
            "use backend = \"xtool\" for an unsigned device bundle"
        ) % name
    if provisioning_profile:
        fail("%s: signing = False conflicts with provisioning_profile = %r; an unsigned build cannot name a profile" %
             (name, provisioning_profile))
    return _ios_unsigned_conflict(name, kwargs)

def _ios_emit_error(name, meta, kwargs, message):
    """Emits the failing target that stands in for an unbuildable app.

    Args:
        name: The app target name.
        meta: The bundle context, carrying tags and visibility.
        kwargs: Pass-through attributes, read for `testonly`.
        message: The analysis-time error text.
    """
    _ios_analysis_error(
        name = name,
        message = message,
        tags = meta.tags,
        visibility = meta.visibility,
        testonly = kwargs.get("testonly", False),
    )

def _ios_bundle_context(name, app_name, backend, signing, provisioning_profile, kwargs):
    """Resolves the display name, tags, visibility and signing attributes.

    Args:
        name: The app target name.
        app_name: The caller's display name, or None to use `name`.
        backend: Apple bundling backend.
        signing: Whether the app is code signed.
        provisioning_profile: The caller's provisioning profile label, or None.
        kwargs: Pass-through attributes to `ios_application`.

    Returns:
        A struct with the resolved `display_name`, `tags`, `internal_tags`,
        `visibility` and the `unsigned_error` analysis message, if any.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]
    visibility = kwargs.pop("visibility", None)
    unsigned_error = _ios_apply_signing_options(name, backend, signing, provisioning_profile, kwargs)
    return struct(
        display_name = display_name,
        tags = tags,
        internal_tags = internal_tags,
        visibility = visibility,
        unsigned_error = unsigned_error,
    )

def flutter_ios_app(
        name,
        application,
        bundle_id,
        families = ["iphone"],
        app_name = None,
        minimum_os_version = IOS_MINIMUM_OS_VERSION,
        info_plist = None,
        version = None,
        launch_storyboard = None,
        entitlements = None,
        additional_entitlements = [],
        provisioning_profile = None,
        signing = True,
        app_icons = None,
        resources = [],
        runner_deps = [],
        srcs = None,
        engine = None,
        exclude_plugins = [],
        generated_registrant = True,
        swift_copts = [],
        additional_deps = [],
        allow_non_macho = [],
        backend = "rules_apple",
        **kwargs):
    """Builds a Flutter iOS .app bundle from a flutter_application target.

    Discovers runner files from the conventional `ios/Runner/` directory
    (as generated by `flutter create --platforms=ios .`) and wires up all
    internal targets automatically.

    Prerequisites — the package must contain:
        - `ios/Runner/*.swift` (AppDelegate, SceneDelegate, etc.)
    Generate these with: `flutter create --platforms=ios .`

    The app's Flutter flavor is the one its `application` was declared with:
    `flutter_ios_app` has no `flavor` attribute, and the app's Dart compile
    (`-DFLUTTER_APP_FLAVOR`), assets and shaders all come from `application`.
    Declare one `flutter_application` per flavor and one `flutter_ios_app` over
    each; there is no second way to set the flavor.

    Simulator builds need no code signing. Device builds require
    `provisioning_profile`: rules_apple adds a provisioning-profile step to
    every device build, so without a profile `ios_application` fails at
    analysis with "The provisioning_profile attribute must be set for device
    builds on this platform (ios)". `signing = False` is refused at analysis on
    that backend for the same reason; an unsigned device bundle is the `xtool`
    backend's output. See the README's "Running an iOS example on a physical
    device" for how to obtain a profile without an Xcode project.

    Non-release builds carry two extra `Info.plist` keys —
    `NSBonjourServices` and `NSLocalNetworkUsageDescription` — so the engine
    can advertise the Dart VM service over mDNS, matching flutter_tools'
    `xcode_backend.dart`. Release builds drop them, which is correct: they
    exist for the debugger, not for the app. An app that needs iOS 14+ Local
    Network Privacy for *itself* must declare `NSLocalNetworkUsageDescription`
    (and its own `NSBonjourServices`) in `ios/Runner/Info.plist`, where it
    survives into release; the macro merges the VM service keys into that
    plist rather than beside it, so the app's own values win and its Bonjour
    service list is preserved.

    Args:
        name: Target name (Bazel identifier). The runner's Swift module name
            is derived from it, so it must be a bare Swift identifier.
        application: A `flutter_application` target (required). Its flavor is
            the iOS app's flavor; declare one `flutter_application` and one
            `flutter_ios_app` per flavor, as there is no second way to set it.
        bundle_id: CFBundleIdentifier (required — rules_apple constraint).
        families: Device families (default ["iphone"]; `flutter create` targets iPhone and iPad. An iPhone-only app runs in a small window on iPadOS. Adding "ipad" makes actool reject the 76x76@1x icon in `flutter create`'s icon set, so drop that entry first).
        app_name: User-facing display name. Defaults to name.
        minimum_os_version: Minimum iOS version.
        info_plist: Override conventional ios/Runner/Info.plist. The macro
            substitutes `$(PRODUCT_MODULE_NAME)` in the conventional plist
            with the runner's module name; an overriding plist that spells
            `UISceneDelegateClassName` out as `Runner.SceneDelegate` will not
            find the scene delegate. Keep the `$(PRODUCT_MODULE_NAME)`
            variable, or write `<name>.SceneDelegate`.
        version: An apple_bundle_version target. Defaults to "1.0".
        launch_storyboard: Override launch storyboard. Defaults to
            ios/Runner/Base.lproj/LaunchScreen.storyboard.
        entitlements: Override entitlements wiring. By default the macro
            auto-discovers `ios/Runner/Runner.entitlements` and forwards
            it to `ios_application`. Unlike macOS (where flutter create
            always emits the entitlements files), iOS only ships
            Runner.entitlements when capabilities are enabled in Xcode;
            its absence is a valid, capability-less app and the macro
            ships nothing rather than synthesizing a default. Pass `False`
            to ship none although the file exists — a device build is
            signed against a profile, and an entitlement the profile does
            not grant fails it: `aps-environment`, which Xcode writes when
            Push is enabled, cannot be granted by a team wildcard profile
            at all. rules_apple reports that as "uses entitlements with
            the ... key, but the profile does not have this key", which
            names the profile and not the file — and the file is in the
            build because it is on disk, not because anyone named it.
        additional_entitlements: Entitlement plist files merged into the
            base entitlements in **every** compilation mode — the additive
            seam for an app that needs one more `com.apple.security.*` key
            without taking over `ios/Runner/Runner.entitlements`. A key the
            base already declares with the same value is deduped; a
            different value is a hard error naming the key and both files.
            Works when the app ships no entitlements file at all, in which
            case the additions become the entitlements.
        provisioning_profile: A `.mobileprovision` file (usually a
            `local_provisioning_profile` target) to sign a device build
            with. Required for device builds (`--ios_multi_cpus=arm64`) and
            unused by simulator builds.
        signing: Whether to code sign the bundle. Defaults to `True`, which
            keeps the `provisioning_profile` requirement for a device build.
            `False` is refused at analysis on the `rules_apple` backend,
            whose device pipeline always requires a `provisioning_profile`;
            an unsigned device bundle is the `xtool` backend's output. On
            `xtool`, `False` keeps the caller's `features` unchanged and
            rejects a `provisioning_profile` and any signing attribute
            (`zsign`, `certificate`, `certificate_password_file`,
            `certificate_password_env`, `certificate_password`).
        app_icons: The app icon, as the files of an `.appiconset` or of an
            Icon Composer `.icon` bundle. Defaults to the conventional
            `ios/Runner/Assets.xcassets/AppIcon.appiconset` that
            `flutter create` writes — so an app that has never thought about
            this ships the icon it already has on disk, which is what
            `flutter build ios` does with the same tree. Pass a list to name a
            different one; pass `[]` to ship no icon. rules_apple refuses an
            `.appiconset` and a `.icon` bundle together, so name exactly one.
            Discovery is per-platform and its absence is silent: a tree
            that only ever ran `flutter create --platforms=macos .` has no
            catalog here, and an app with neither a catalog nor an
            `app_icons` has said nothing either way, so it ships no icon and
            there is nothing to report.
        resources: Extra resources. Main.storyboard is wired separately,
            through the runner library, so that ibtool resolves its classes
            against the runner's module. Resources passed here are compiled
            against the app target's name instead, which is not a module any
            target produces — so a storyboard listed here cannot reference the
            runner's Swift classes (an `@objc` class name works regardless).
        runner_deps: Extra `swift_library` labels to link into the runner, so
            the runner's sources can `import` them and the binary carries
            their code. Added to the generated `__<name>_runner` library's
            `deps`; `deps` itself is the macro's and cannot be passed through
            **kwargs. For App Intents, pass the library here *and* to
            rules_apple's `app_intents` (which passes through **kwargs):
            `app_intents` only extracts the metadata, it does not link.
        srcs: Override conventional `ios/Runner/*.swift` runner sources.
        engine: Override default `@flutter_ios_engine//:engine` target.
        exclude_plugins: Plugin module names to leave out of the
            registrant. A name that is not a native iOS plugin of the
            application is an error, listing the valid names. iOS-only:
            the Android, Linux, macOS and Windows registrants always
            register every collected native plugin. It only edits a
            registrant the macro generates, so combining it with
            `generated_registrant = False` is an analysis error naming both.
        generated_registrant: Whether the macro generates the Swift plugin
            registrant and wires it into the app. Defaults to `True`, which
            is the behaviour every existing app already has. `False` defines
            no `__<name>_registrant` target and adds no registrant source to
            the runner: the app supplies its own registrant library through
            `additional_deps`, as an Objective-C app with an
            `AppDelegate.m` does. On the `xtool` backend the bundle gets no
            `registrant` either.
        swift_copts: Extra flags for the generated runner `swift_library`,
            appended after the flags the macro sets itself. Use it for an
            Objective-C bridging header (`-import-objc-header`) or any other
            flag the app's own sources need. Supported on the `rules_apple`
            backend only: the `xtool` bundle rule compiles the runner itself,
            so a non-empty list there fails at analysis instead of being
            dropped. A file named by a `$(execpath ...)` flag must also be an
            input of the runner, for example through a target listed in
            `runner_deps`, because an undeclared input fails the sandbox.
        additional_deps: Extra labels appended to the final bundle's `deps`,
            after the runner, `App.framework` and the native frameworks (or,
            on `xtool`, after the bundle's runner deps). An `objc_library`
            that implements the app's own registrant belongs here: it is
            linked into the app, not into the runner. This is separate from
            `runner_deps`, which adds libraries the runner's own sources
            import.
        allow_non_macho: Explicit allow-list of binary or framework names
            allowed to pass through unpatched when they are not 64-bit or
            universal Mach-O binaries. A 64-bit or universal Mach-O binary
            is always patched (and stripped when requested); patch failures
            are errors even for allowed names.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in). Note: `"xtool"` requires a
            user-supplied `darwin.artifactbundle` configured via
            `flutter.darwin_sdk` in compliance with Apple's SDK licensing
            terms; no Apple SDK is downloaded by default.
        **kwargs: Passed through to `ios_application` (or `_flutter_xtool_ios_bundle`
            when `backend = "xtool"`). For `backend = "xtool"` signing with
            `certificate` (`.p12`), pass the password via
            `certificate_password_file` (a file label read at execution time)
            or `certificate_password_env` (an environment variable name read at
            execution time); plain-text `certificate_password` is rejected so
            signing secrets never appear on action command lines. The macro sets
            `bundle_id`, `bundle_name`, `entitlements`, `families`,
            `minimum_os_version`, `infoplists`, `version`,
            `launch_storyboard`, `resources`, `provisioning_profile`,
            `app_icons`, `deps` and `tags` itself, so passing any of those
            here is a duplicate-keyword error — use the named parameter
            instead.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_app: backend must be 'rules_apple' or 'xtool', got %r" % backend)

    meta = _ios_bundle_context(name, app_name, backend, signing, provisioning_profile, kwargs)
    validate_minimum_os_version("flutter_ios_app", name, minimum_os_version, _IOS_MINIMUM_OS_VERSION, "iOS")
    registrant = _ios_registrant_settings(generated_registrant, exclude_plugins)
    error = _ios_attribute_error(name, registrant, backend, swift_copts) or meta.unsigned_error
    if error:
        _ios_emit_error(name, meta, kwargs, error)
        return

    module_name = runner_module_name("flutter_ios_app", name)

    # target_compatible_with doesn't work on ios_application (it transitions to
    # iOS platform, so macOS constraints would fail). Users should put
    # target_compatible_with on build_test instead.
    kwargs.pop("target_compatible_with", None)

    # Auto-discover ios/Runner/Runner.entitlements if the user hasn't
    # passed one. Its absence is convention-matching (no-capabilities
    # apps don't have an entitlements file); rules_apple's signing
    # pipeline still injects `get-task-allow=true` for debug builds.
    # `False` ships none although the file exists — see
    # `resolve_ios_entitlements` for the device build that needs it.
    entitlements = _ios_resolve_entitlements(name, entitlements, additional_entitlements, meta.internal_tags)

    # The app icon: the conventional catalog `flutter create` writes, unless
    # the caller named something else. Discovered for the same reason the
    # entitlements and the launch storyboard are — the scaffold is the app's
    # answer until it says otherwise — and leaving it undiscovered meant every
    # Bazel-built Flutter app shipped the generic icon while the sixteen PNGs
    # `flutter create` left behind were read by nothing.
    #
    # `None` means discover, `[]` means ship none: both states are sayable, and
    # an app with no catalog at all is the second without having to write it.
    app_icons = _ios_discover_app_icons(app_icons, backend)

    # -- Internal targets (all __{name}_ prefixed) --

    patching = struct(minimum_os_version = minimum_os_version, allow_non_macho = allow_non_macho)
    engine_target = _ios_build_frameworks(name, application, patching, backend, engine, registrant, meta.internal_tags)
    _ios_build_native_frameworks(name, application, patching, meta.internal_tags)

    # 7. Discover runner Swift sources and build swift_library.
    runner = struct(
        application = application,
        backend = backend,
        engine_target = engine_target,
        srcs = _ios_discover_runner_srcs(srcs),
        registrant_srcs = ["__%s_registrant" % name] if generated_registrant else [],
        copts = swift_copts,
        module_name = module_name,
        deps = runner_deps,
        internal_tags = meta.internal_tags,
        discovered_main_storyboard = native.glob(["ios/Runner/Base.lproj/Main.storyboard"], allow_empty = True),
    )
    _ios_build_runner(name, runner)

    # 8. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle.
    actual_info_plist = _ios_resolve_info_plist(name, info_plist, module_name, meta.internal_tags)

    # 9. Version — create default apple_bundle_version if not provided (rules_apple),
    #    or resolve/convert apple_bundle_version on xtool without Apple toolchains.
    version, invalid_version_error = _ios_resolve_version(name, backend, version, meta.internal_tags, kwargs)

    # 10. Resolve launch storyboard. On xtool, storyboards discovered in the
    #     conventional `flutter create` layout are forwarded so the rule
    #     reports a named ibtool error rather than silently dropping them.

    # 10b. Dart VM service keys for debug/profile builds — required for the
    #      Flutter engine to register the VM service via mDNS. Matches
    #      flutter_tools' xcode_backend.dart, which only adds them for
    #      non-release configurations.
    #
    #      These are *merged into* the app's Info.plist rather than passed
    #      beside it. rules_apple's plisttool hard-fails when two plists
    #      declare the same key with different values, so an app declaring
    #      its own NSLocalNetworkUsageDescription — the documented way to
    #      request iOS 14+ Local Network Privacy, and the key a LAN app
    #      needs in release — could not build in `-c dbg` at all. The
    #      supplement merge keeps the app's own values and unions its
    #      NSBonjourServices with `_dartVmService._tcp`.
    # 10b. Dart VM service keys for debug/profile builds — required for the
    #      Flutter engine to register the VM service via mDNS. Matches
    #      flutter_tools' xcode_backend.dart, which only adds them for
    #      non-release configurations.
    selected_infoplists = _ios_dev_infoplists(name, actual_info_plist, meta.internal_tags)

    # 11. Final bundle target — rules_apple (default) or explicit opt-in xtool.
    bundle = struct(
        display_name = meta.display_name,
        bundle_id = bundle_id,
        families = families,
        minimum_os_version = minimum_os_version,
        version = version,
        selected_infoplists = selected_infoplists,
        actual_launch_storyboard = _ios_resolve_launch_storyboard(launch_storyboard, backend),
        app_icons = app_icons,
        resources = resources,
        entitlements = entitlements,
        provisioning_profile = provisioning_profile,
        registrant = ":__%s_registrant" % name if generated_registrant else None,
        additional_deps = additional_deps,
        tags = meta.tags,
        visibility = meta.visibility,
        kwargs = kwargs,
    )
    if backend == "rules_apple":
        _ios_emit_rules_apple_bundle(name, bundle)
    else:
        _ios_emit_xtool_bundle(name, bundle, invalid_version_error, runner)
