"""Flutter rules for Android builds.

Two tiers of API:

    Tier 1 — flutter_android_app (self-contained, recommended):

        load("@rules_flutter//flutter:android.bzl", "flutter_android_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_android_app(
            name = "my_app_android",
            application = ":my_app",
            package_name = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=android .` in your package to
    generate the conventional `android/app/src/main/` directory with
    AndroidManifest.xml, resources, and Kotlin sources. The macro handles everything
    automatically — no edits to the flutter create output needed.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:android.bzl",
            "ANDROID_MIN_SDK_VERSION",
            "ANDROID_TARGET_SDK_VERSION",
            "flutter_android_apk_overlay",
            "flutter_android_bundle",
            "flutter_android_engine",
            "flutter_android_manifest_gen",
            "flutter_android_manifest_merge",
            "flutter_android_runner_lib_gen")

        flutter_android_bundle(name = "my_bundle", application = ":my_app")
        flutter_android_engine(name = "my_engine")
        flutter_android_manifest_gen(name = "my_manifest", package_name = "com.example.myapp")

        flutter_android_runner_lib_gen(
            name = "my_runner",
            package_name = "com.example.myapp",
            engine = ":my_engine",
        )

        android_binary(
            name = "my_apk",
            manifest = ":my_manifest",
            deps = [":my_bundle_native_libs", ":my_engine", ":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", _android_binary = "android_binary")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")
load("@rules_kotlin//kotlin:android.bzl", _kt_android_library = "kt_android_library")
load(
    "//flutter/private:constants.bzl",
    _ANDROID_MIN_SDK_VERSION = "ANDROID_MIN_SDK_VERSION",
    _ANDROID_TARGET_SDK_VERSION = "ANDROID_TARGET_SDK_VERSION",
)
load(
    "//flutter/private:flutter_android_apk_overlay.bzl",
    _flutter_android_apk_overlay = "flutter_android_apk_overlay",
    _overlay_signing_select = "overlay_signing_select",
)
load(
    "//flutter/private:flutter_android_application.bzl",
    _android_internal_tags = "android_internal_tags",
    _flutter_android_aar = "flutter_android_aar",
    _flutter_android_bundle = "flutter_android_bundle",
)
load(
    "//flutter/private:flutter_android_binary_proxy.bzl",
    _FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS = "FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS",
    _build_overlay_kwargs = "build_overlay_kwargs",
    _flutter_android_binary_proxy = "flutter_android_binary_proxy",
    _flutter_drive_test = "flutter_drive_test",
)
load("//flutter/private:flutter_android_engine.bzl", _flutter_android_engine = "flutter_android_engine")
load("//flutter/private:flutter_android_engine_jar.bzl", _flutter_android_engine_jar = "flutter_android_engine_jar")
load("//flutter/private:flutter_android_manifest_merge.bzl", _flutter_android_manifest_merge = "flutter_android_manifest_merge")
load(
    "//flutter/private:flutter_android_plugin_library.bzl",
    _declare_android_bundle_targets = "declare_android_bundle_targets",
    _declare_android_plugin_closure = "declare_android_plugin_closure",
    _flutter_android_plugin_library = "flutter_android_plugin_library",
)
load(
    "//flutter/private:flutter_android_registrant.bzl",
    _android_discover_runner = "android_discover_runner",
    _android_registrant = "android_registrant",
    _flutter_android_aab_emit = "flutter_android_aab_emit",
    _flutter_android_registrant = "flutter_android_registrant",
    _short_abi_to_full = "short_abi_to_full",
    _variant_overlay = "variant_overlay",
)

visibility("public")

# Re-export constants for user BUILD files.
ANDROID_MIN_SDK_VERSION = _ANDROID_MIN_SDK_VERSION
ANDROID_TARGET_SDK_VERSION = _ANDROID_TARGET_SDK_VERSION

# -- Composable rules (Tier 2) ------------------------------------------------

flutter_android_bundle = _flutter_android_bundle

# Packages a flutter_application as an AAR for a native Android host app, with
# the pinned engine flutter.jar in the `engine_maven` output group.
flutter_android_aar = _flutter_android_aar

# Finishes a payload-free android_binary into a signed APK by injecting the
# Flutter payload (native libraries and flutter_assets) after resource
# linking. Wired automatically by flutter_android_app; expose for Tier-2
# control when assembling an `android_binary` by hand.
flutter_android_apk_overlay = _flutter_android_apk_overlay

# The aapt2 default no-compress extension list that both the overlay tool and
# android_binary's own packaging apply.
FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS = _FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS

# Runs a host-side driver script against an Android emulator or iOS simulator app.
flutter_drive_test = _flutter_drive_test

# Merges a variant AndroidManifest.xml overlay (e.g. flutter create's
# android/app/src/debug/AndroidManifest.xml) into a base manifest — the
# Bazel counterpart of Gradle's per-variant manifest merge. Wired
# automatically by flutter_android_app; expose for Tier-2 control.
flutter_android_manifest_merge = _flutter_android_manifest_merge

def flutter_android_permissions_manifest(name, permissions, **kwargs):
    """Writes an overlay manifest declaring `permissions`, and nothing else.

    The overlay half of the additive permission seam: pair it with
    `flutter_android_manifest_merge` to add `<uses-permission>` elements to
    any base manifest — including one produced by
    `flutter_android_manifest_gen`, which has no permission attribute of its
    own. `flutter_android_app(permissions = [...])` composes exactly these
    two rules; do it by hand when assembling an `android_binary` yourself.

    Args:
        name: Target name. Pass as `overlay` to
            `flutter_android_manifest_merge`.
        permissions: Fully-qualified permission names, e.g.
            `["android.permission.INTERNET"]`.
        **kwargs: Additional arguments (e.g. visibility, tags). `tags`
            defaults to `["manual"]`.
    """
    if not permissions:
        fail("flutter_android_permissions_manifest(name = %r): `permissions` " % name +
             "is empty. Drop the target rather than merging nothing.")
    tags = kwargs.pop("tags", ["manual"])
    write_file(
        name = name,
        out = "%s/AndroidManifest.xml" % name,
        content = [
            "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">",
        ] + [
            "    <uses-permission android:name=\"%s\"/>" % permission
            for permission in permissions
        ] + [
            "</manifest>",
            "",
        ],
        tags = tags,
        **kwargs
    )

def flutter_android_plugin_library(name, flutter_engine = None, tags = None, **kwargs):
    """Wrap a Flutter plugin's Android Kotlin/Java sources in a kt_android_library.

    For pub.dev plugins, `flutter_pub_package` emits this automatically; expose
    it here so users can wire a workspace plugin's BUILD.bazel without going
    through the ext/ overlay system. When `flutter_engine` is omitted, a
    private `neverlink = True` engine target is created automatically.

    Args:
        name: Target name. Pass to `flutter_plugin(android_libs = [...])` or
            `flutter_android_app(deps = [...])`.
        flutter_engine: Optional `flutter_android_engine` target declared with
            `neverlink = True`. If omitted, a private compile-only engine is
            synthesized automatically.
        tags: Bazel tags. Defaults to `["manual"]`.
        **kwargs: Forwarded to `_flutter_android_plugin_library`.
    """
    if flutter_engine == None:
        engine_tags = tags if tags != None else ["manual"]
        flutter_android_engine(
            name = "_%s__engine" % name,
            neverlink = True,
            tags = engine_tags,
            visibility = ["//visibility:private"],
        )
        flutter_engine = ":_%s__engine" % name
    _flutter_android_plugin_library(
        name = name,
        flutter_engine = flutter_engine,
        tags = tags,
        **kwargs
    )

# Registrant rule that emits GeneratedPluginRegistrant.java from a
# flutter_application's transitive FlutterInfo. Wired automatically by
# flutter_android_app; expose for Tier-2 control.
flutter_android_registrant = _flutter_android_registrant

flutter_android_engine = _flutter_android_engine

flutter_android_engine_jar = _flutter_android_engine_jar

def flutter_android_manifest_gen(
        name,
        package_name,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        **kwargs):
    """Generates an AndroidManifest.xml from the default Bazel template.

    The template uses FlutterActivity as the main activity with embedding v2.

    Debug builds (`-c dbg`) declare `android.permission.INTERNET`, matching
    the permission Gradle merges from flutter create's debug variant
    manifest: Android enforces INTERNET at the kernel level (AID_INET group
    membership), so without it the Dart VM service cannot bind even its
    loopback socket and debugging/hot reload are impossible. Release builds
    declare no permissions.

    That grant is the *debugger's*, not the app's, and this template has a
    fixed key set with no permission attribute. An app that networks in
    release declares it for itself — through
    `flutter_android_app(permissions = [...])`, or, when assembling an
    `android_binary` by hand, by composing this manifest with
    `flutter_android_permissions_manifest` +
    `flutter_android_manifest_merge`:

        flutter_android_manifest_gen(name = "base", package_name = "...")
        flutter_android_permissions_manifest(
            name = "extra",
            permissions = ["android.permission.INTERNET"],
        )
        flutter_android_manifest_merge(
            name = "manifest",
            base = ":base",
            overlay = ":extra",
        )

    Args:
        name: Target name. Pass to android_binary manifest.
        package_name: Android package name (e.g. "com.example.myapp").
        app_name: Display name for the app. Defaults to package_name.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    display_name = app_name or package_name

    substitutions = {
        "PACKAGE_NAME": package_name,
        "APP_NAME": display_name,
        "MIN_SDK_VERSION": min_sdk_version,
        "TARGET_SDK_VERSION": target_sdk_version,
    }

    expand_template(
        name = "__%s_dbg" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_dbg/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "<uses-permission android:name=\"android.permission.INTERNET\"/>",
        },
        tags = tags,
    )

    expand_template(
        name = "__%s_opt" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_opt/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "",
        },
        tags = tags,
    )

    native.alias(
        name = name,
        actual = select({
            "@rules_flutter//flutter/private:dbg": "__%s_dbg" % name,
            # Profile serves the VM service too, so it needs the socket.
            "@rules_flutter//flutter/private:profile": "__%s_dbg" % name,
            "//conditions:default": "__%s_opt" % name,
        }),
        tags = tags,
        **kwargs
    )

def flutter_android_runner_lib_gen(
        name,
        package_name,
        engine,
        manifest = None,
        **kwargs):
    """Generates a kt_android_library with a default Flutter runner Activity.

    Uses template MainActivity.kt from rules_flutter. This provides a
    custom Activity subclass for users who don't have `flutter create`
    output but want a named Activity class (e.g. for deep links or
    intent filters).

    For most apps, FlutterActivity can be used directly in the manifest
    without a custom runner — see flutter_android_manifest_gen.

    Args:
        name: Target name. Add to android_binary deps.
        package_name: Android package name (e.g. "com.example.myapp").
            Used for template substitution in MainActivity.kt.
        engine: A flutter_android_engine target (flutter.jar).
        manifest: AndroidManifest.xml for the library. If not provided,
            a minimal one is generated.
        **kwargs: Additional arguments passed to kt_android_library.
    """
    tags = kwargs.pop("tags", ["manual"])

    # Generate the MainActivity.kt with the correct package name.
    expand_template(
        name = "__%s_main_activity" % name,
        template = "@rules_flutter//flutter/private/runners/android:MainActivity.kt",
        out = "__%s_runner/MainActivity.kt" % name,
        substitutions = {
            "PACKAGE_NAME": package_name,
        },
        tags = tags,
    )

    # Generate a minimal manifest for android_library if not provided.
    actual_manifest = manifest
    if not actual_manifest:
        expand_template(
            name = "__%s_lib_manifest" % name,
            template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
            out = "__%s_lib_manifest/AndroidManifest.xml" % name,
            substitutions = {
                "PACKAGE_NAME": package_name,
                "APP_NAME": package_name,
                "MIN_SDK_VERSION": ANDROID_MIN_SDK_VERSION,
                "TARGET_SDK_VERSION": ANDROID_TARGET_SDK_VERSION,
                # Never a permission here: this is a LIBRARY manifest, and
                # rules_android's merger strips library permissions unless
                # --merge_android_manifest_permissions is set — the permission
                # would silently come and go with a flag. The binary manifest
                # (flutter_android_manifest_gen) owns INTERNET.
                "INTERNET_PERMISSION": "",
            },
            tags = tags,
        )
        actual_manifest = "__%s_lib_manifest" % name

    _kt_android_library(
        name = name,
        srcs = ["__%s_main_activity" % name],
        manifest = actual_manifest,
        tags = tags,
        deps = [engine],
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def _android_bundle_and_engine(name, application, android_abi, internal_tags, analyze_size = False):
    """Emits the bundle, native-libs wiring, engine and overlay-assets targets."""
    flutter_android_engine(
        name = "__%s_engine_raw" % name,
        android_abi = android_abi,
        tags = internal_tags,
    )
    _declare_android_bundle_targets(
        name = name,
        application = application,
        full_abi = _short_abi_to_full(android_abi),
        tags = internal_tags,
        analyze_size = analyze_size,
        java_import_fn = _java_import,
    )
    native.filegroup(
        name = "__%s_overlay_assets" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "flutter_assets",
        tags = internal_tags,
    )

def _android_resolve_manifest(name, base_manifest, binary_deps, deps, manifest):
    """Resolves the effective manifest: variants, template, permissions.

    Folds each variant's permissions into its own mode's APKs, the merge
    Gradle performs per build type. Release APKs keep the main manifest,
    byte-identical to a build without the variants. The app's own
    permissions go last and in every compilation mode, so a permission the
    app needs cannot go missing from the release APK the way `flutter
    create`'s debug-variant INTERNET does. Library permissions are lifted
    as Gradle does, whatever the merger flags.
    """
    debug_overlay = _variant_overlay(name, "debug", manifest.debug_manifest, base_manifest)
    profile_overlay = _variant_overlay(name, "profile", manifest.profile_manifest, base_manifest)

    if base_manifest == None:
        # No flutter create output — generate manifest from template. The
        # generated manifest handles the debug and profile INTERNET
        # permission itself (see flutter_android_manifest_gen).
        flutter_android_manifest_gen(
            name = "__%s_manifest" % name,
            package_name = manifest.package_name,
            app_name = manifest.display_name,
            min_sdk_version = manifest.min_sdk_version,
            target_sdk_version = manifest.target_sdk_version,
            tags = manifest.internal_tags,
        )
        actual_manifest = "__%s_manifest" % name
    elif debug_overlay != None or profile_overlay != None:
        variants = {}
        for mode, overlay in [("dbg", debug_overlay), ("profile", profile_overlay)]:
            if overlay == None:
                continue
            flutter_android_manifest_merge(
                name = "__%s_manifest_merged_%s" % (name, mode),
                base = base_manifest,
                overlay = overlay,
                tags = manifest.internal_tags,
            )
            variants["@rules_flutter//flutter/private:" + mode] = "__%s_manifest_merged_%s" % (name, mode)
        actual_manifest = select(variants | {"//conditions:default": base_manifest})
    else:
        actual_manifest = base_manifest

    if manifest.permissions:
        flutter_android_permissions_manifest(
            name = "__%s_permissions" % name,
            permissions = manifest.permissions,
            tags = manifest.internal_tags,
        )
        flutter_android_manifest_merge(
            name = "__%s_manifest_with_permissions" % name,
            base = actual_manifest,
            overlay = "__%s_permissions" % name,
            tags = manifest.internal_tags,
        )
        actual_manifest = "__%s_manifest_with_permissions" % name

    flutter_android_manifest_merge(
        name = "__%s_manifest_with_library_permissions" % name,
        base = actual_manifest,
        libraries = ["__%s_native_libs" % name] + binary_deps + deps,
        placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
        tags = manifest.internal_tags,
    )
    return "__%s_manifest_with_library_permissions" % name

def _android_binary_and_overlay(name, binary_deps, deps, apk):
    """Emits the payload-free android_binary, the payload overlay and the proxy.

    The android_binary builds a payload-free base APK: neither the
    native_libs java_import (whose jar carries libapp.so through the dex
    chain) nor flutter_assets (which aapt2 would link into the resources
    APK) are its inputs, so Dart edits re-run neither resource linking nor
    dexing. The overlay injects both after resource linking, then aligns
    and signs — the same steps android_binary would have run.

    Args:
        name: The app name; internal targets derive from it.
        binary_deps: Binary dependency labels for the android_binary.
        deps: Extra dependency labels for the android_binary.
        apk: Struct with `package_name`, `min_sdk_version`,
            `target_sdk_version`, `actual_manifest`, `resources`,
            `nocompress_extensions`, `tags`, `internal_tags`, `kwargs` (the
            passthrough keyword args for the binary), and `signing` (a struct
            with `keystore`, `keystore_password_file`, `key_alias`, and
            `key_password_file`).
    """

    # 9. Final android_binary, behind a proxy that scopes rules_go pure mode
    # to this app (see flutter_android_binary_proxy.bzl).
    # `android_binary` resolves `_cc_toolchain` in the outer target
    # configuration before transitioning to Android, so it can be analyzed on
    # host or Android platforms (both of which register a CC toolchain) but not
    # when the top-level `--platforms` is iOS.
    apk.kwargs.setdefault(
        "target_compatible_with",
        select({
            Label("@platforms//os:ios"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
    )

    # Attributes describing the app target itself, mirrored onto both the proxy
    # (what users build) and the binary behind it so the two agree on where the
    # app can build and how it is released. Everything else configures the
    # binary alone.
    passthrough = {}
    for key in ("compatible_with", "deprecation", "restricted_to", "target_compatible_with", "testonly", "visibility"):
        if key in apk.kwargs:
            passthrough[key] = apk.kwargs.pop(key)
    binary_kwargs = dict(apk.kwargs)
    binary_kwargs.update(passthrough)
    if apk.nocompress_extensions != None:
        binary_kwargs["nocompress_extensions"] = apk.nocompress_extensions

    # Like every other internal target, the binary stays out of wildcard
    # builds (see internal_tags above): the proxy is the only entry point.
    _android_binary(
        name = "__%s_binary" % name,
        manifest = apk.actual_manifest,
        manifest_values = {
            "applicationId": apk.package_name,
            "minSdkVersion": apk.min_sdk_version,
            "targetSdkVersion": apk.target_sdk_version,
        },
        resource_files = apk.resources if apk.resources else None,
        deps = binary_deps + deps,
        tags = apk.internal_tags,
        **binary_kwargs
    )

    # 10. Inject the Flutter payload after resource linking, then align and
    # sign — the same steps android_binary would have run. `signing` follows
    # @rules_android//flags:apk_signing_method so the overlay signs exactly
    # like the binary would have. Signing/alignment overrides passed for the
    # binary apply to the overlay too.
    overlay_kwargs = _build_overlay_kwargs(apk, passthrough)
    if apk.analyze_size:
        overlay_kwargs["size_json"] = ":__%s_size_json" % name
    _flutter_android_apk_overlay(
        name = "__%s_overlay" % name,
        binary = "__%s_binary" % name,
        native_libs_jar = "__%s_native_libs_jar" % name,
        flutter_assets = "__%s_overlay_assets" % name,
        signing = _overlay_signing_select(apk.min_sdk_version),
        tags = apk.internal_tags,
        **overlay_kwargs
    )

    # The user-facing target: same providers and the same `<name>.apk` output
    # as the android_binary used to be, with pure Go scoped to its subtree.
    proxy_kwargs = dict(passthrough)
    if apk.analyze_size:
        proxy_kwargs["analyze_size"] = True
    _flutter_android_binary_proxy(
        name = name,
        binary = ":__%s_overlay" % name,
        tags = apk.tags,
        **proxy_kwargs
    )

def _android_app_parts(name, app):
    """Emits the internal targets both app macros share and returns their wiring.

    Steps 1-8 of the app pipeline: bundle, engine, registrant, runner
    discovery and the resolved manifest. The bundle's `native_libs` java_import
    is not in the returned `binary_deps`.

    Args:
        name: The app name; internal targets derive from it.
        app: Struct with `application`, `android_abi`, `deps`, `internal_tags`,
            `analyze_size`, `resources` and `manifest` (a struct of
            `package_name`, `display_name`, `min_sdk_version`,
            `target_sdk_version`, `permissions`, `internal_tags`,
            `debug_manifest`, `profile_manifest` and `base`).

    Returns:
        Struct with `actual_manifest`, `resources` and `binary_deps`.
    """
    _android_bundle_and_engine(
        name,
        app.application,
        app.android_abi,
        app.internal_tags,
        analyze_size = app.analyze_size,
    )

    # 6. Auto-wire the plugin closure and registrant. `deps` and
    # `flutter_plugin(android_libs = ...)` too: a plugin written in the
    # workspace reaches the app through them, and the registrant names its
    # class.
    _declare_android_plugin_closure(
        name = name,
        application = app.application,
        android_abi = _short_abi_to_full(app.android_abi),
        engine = ":__%s_engine" % name,
        tags = app.internal_tags,
    )
    registrant_deps = _android_registrant(
        name,
        app.application,
        app.android_abi,
        app.deps,
        app.internal_tags,
    )
    _kt_android_library(
        name = "__%s_registrant" % name,
        srcs = ["__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        tags = app.internal_tags,
        deps = registrant_deps,
    )

    # 7. The payload (native_libs, flutter_assets) is not a base dep: see the
    # callers. 8. Plugin auto-wiring: the closure target carries the Android
    # library of each plugin the app's Dart graph reaches, and no other.
    binary_deps = ["__%s_engine" % name, "__%s_registrant" % name, "__%s_android_plugin_deps" % name]
    base_manifest, resources = _android_discover_runner(
        name,
        app.manifest.package_name,
        app.resources,
        binary_deps,
        app.manifest.base,
        app.internal_tags,
    )

    # 8b/8c. Variant overlays, the app's own permissions and the permissions
    # its Android libraries declare, resolved into one manifest.
    actual_manifest = _android_resolve_manifest(name, base_manifest, binary_deps, app.deps, app.manifest)
    return struct(actual_manifest = actual_manifest, resources = resources, binary_deps = binary_deps)

def flutter_android_app(
        name,
        application,
        package_name,
        app_name = None,
        android_abi = "arm64",
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        debug_manifest = None,
        profile_manifest = None,
        permissions = [],
        resources = [],
        deps = [],
        pub_hub_name = "deps",
        nocompress_extensions = None,
        keystore = None,
        keystore_password_file = None,
        key_alias = None,
        key_password_file = None,
        analyze_size = False,
        **kwargs):
    """Builds a Flutter Android APK from a flutter_application target.

    Discovers runner files from the conventional `android/app/src/main/`
    directory (as generated by `flutter create --platforms=android .`) and
    wires up all internal targets automatically.

    Three modes, and which one an app is in decides what it can express:
      1. `manifest` provided → uses it directly, with **no** `${...}`
         placeholder preprocessing and no resource/Kotlin auto-discovery.
         Handing this attribute the same `android/app/src/main/`
         AndroidManifest.xml mode 2 would have discovered therefore fails —
         `flutter create` writes `android:name="${applicationName}"` and
         nothing substitutes it. Use mode 2 for `flutter create` output;
         mode 1 is for a manifest you wrote yourself.
      2. android/app/src/main/AndroidManifest.xml found → uses flutter create
         manifest (preprocessed for Gradle variables), discovers resources
         and Kotlin sources from android/app/src/main/. The main manifest is
         used in **every** compilation mode.
      3. No manifest found → generates manifest from template.

    `permissions` adds `<uses-permission>` elements to the effective manifest
    in every mode and every compilation mode, so it is the answer in all
    three — see the attribute's documentation below.

    Debug variant manifests (the Gradle merge Bazel lacks): flutter create
    declares `android.permission.INTERNET` only in
    `android/app/src/debug/AndroidManifest.xml`. Without it a debug APK
    cannot host the Dart VM service (Android enforces INTERNET at the
    kernel level via AID_INET), so hot reload and debugging are impossible.
    This macro folds the debug variant into `-c dbg` APKs, controlled by
    `debug_manifest`:
      - None (default) → discover android/app/src/debug/AndroidManifest.xml;
        when present, its permissions are merged into the main manifest for
        `-c dbg` builds only. Requires a main manifest (mode 1 or 2).
      - a label → merge that variant manifest instead of discovering one.
      - False → no debug variant handling, even if the file exists.
    Release (`-c opt`, the default) APKs always use the main manifest
    unchanged — so a `flutter create` app that networks perfectly in `-c dbg`
    has **no** `INTERNET` permission in release, and Android enforces that at
    the kernel level (AID_INET group membership): every socket fails with
    `EACCES`, with no build error and no diagnostic. The dbg-only grant is a
    *debugging* requirement, not the app's network grant. An app that
    networks must declare it for itself, via `permissions`.
    `profile_manifest` does the same for profile builds (`-c opt` with
    `--@rules_flutter//flutter:profile`), from
    android/app/src/profile/AndroidManifest.xml, which `flutter create`
    writes with the `INTERNET` permission the VM service needs.

    When Kotlin sources are found in android/app/src/main/kotlin/, they are
    compiled via kt_android_library with the Flutter engine and AndroidX deps.

    Plugin auto-wiring:
      - Generates a `flutter_android_registrant` target whose application is
        `application`, then compiles the resulting Java into a private
        `kt_android_library` that goes into `binary_deps`. Every plugin
        whose `flutter.plugin.platforms.android.pluginClass` is set ends up
        registered with the FlutterEngine on startup — no manual wiring.
      - Adds the Android library (Kotlin/Java sources and resources) of
        each plugin in the app's transitive Dart dependencies to
        `binary_deps`, through one `flutter_android_plugin_closure` target.
        A plugin the app does not depend on contributes nothing.
      - Permissions that plugins and AARs declare in their own manifests
        (e.g. record_android's RECORD_AUDIO) are lifted into the app's
        manifest, as AGP merges them. Bazel's own merger drops library
        permissions unless `--merge_android_manifest_permissions` is set;
        the app no longer depends on that flag.

    The app target builds rules_android's Go host tools in rules_go pure
    mode (no C++ toolchain, so the hermetic LLVM runtimes are never
    compiled from source), scoped to this app:
    `--@rules_flutter//flutter:android_pure_go=false` opts out, for example
    when the app's own subtree needs cgo. See the README's Android section
    for the trade-off.

    Release signing: by default the APK signs with the debug keystore, as an
    `android_binary` does. To sign the APK with a release key, pass `keystore` (a `.jks`
    or PKCS#12 `.p12` file label) together with `keystore_password_file` (a
    file label) and `key_alias` (a string); set `key_password_file` (a file
    label) as well when the key has its own password. The
    overlay then signs with `--ks`, `--ks-key-alias`, `--ks-pass
    file:<path>` and, when `key_password_file` is set, `--key-pass
    file:<path>`: both passwords are read from files at execution time and
    never appear on the command line. When `key_password_file` is unset,
    `--key-pass` is omitted and apksigner unlocks the key with the keystore
    password. A `keystore` without `keystore_password_file` or `key_alias` fails
    analysis naming the missing attribute. When `keystore` is unset, the
    `//flutter:android_release_keystore`,
    `//flutter:android_release_keystore_password_file` and
    `//flutter:android_release_key_alias` flags supply the same three
    values, so CI can inject a secret without editing BUILD files; an
    explicit attribute always wins over its flag. Every secret setting must
    name a target with exactly one file — an empty or multi-file target
    fails analysis instead of silently debug-signing — and the release
    signing action runs locally only (`no-remote`), so the secrets never
    reach remote execution or caches. Google Play takes new apps as an
    Android App Bundle, not an APK: see `flutter_android_aab`. See the
    README's Android section.

    Release signing never passes `debug_signing_lineage_file` to apksigner:
    the release APK carries no `--lineage` and the overlay reports no
    lineage, while debug signing keeps it (see
    `docs/android-release-signing.md`).

    Args:
        name: Target name (Bazel identifier). Produces the app APK (an android_binary behind a pure-Go proxy).
        application: A flutter_application target (required).
        package_name: Android package name, e.g. "com.example.myapp" (required).
        app_name: User-facing display name. Defaults to name.
        android_abi: Target ABI — "arm64" (default) or "x64". Selects the
            engine and the Android platform the application is built for.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        manifest: Override AndroidManifest.xml. If not set, auto-discovered
            from android/app/src/main/ or generated from template.
        debug_manifest: Debug variant manifest merged into `-c dbg` APKs.
            None (default) discovers android/app/src/debug/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        profile_manifest: Profile variant manifest merged into profile APKs.
            None (default) discovers android/app/src/profile/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        permissions: Permission names — e.g.
            `["android.permission.INTERNET"]` — added to the effective
            manifest in **every** compilation mode and in all three manifest
            modes. This is what a networked app needs: `flutter create`
            grants `INTERNET` in the debug variant only, so without this the
            release APK cannot open a socket. A permission the manifest
            already declares is not duplicated. For a permission wanted in
            `-c dbg` alone, use `debug_manifest` instead; this attribute is
            consumed by the macro and cannot be a `select()`.
        resources: Extra resource_files for android_binary.
        deps: Extra deps for android_binary (e.g. custom android_library).
            A plugin written in the workspace goes here as its
            `flutter_android_plugin_library`: the registrant compiles
            against these too, so the plugin is both packaged and
            registered. Pub plugins arrive through the Dart graph instead.
        pub_hub_name: Accepted for compatibility and no longer read: the
            app's plugins come from its Dart dependencies, so no hub is
            named. `@<hub>//android:all_android_plugin_libs` stays
            available to a caller that names it in `deps`.
        nocompress_extensions: Extra asset extensions stored uncompressed in
            the final APK, on top of the aapt2 defaults (see
            FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS). Forwarded to both the
            payload-free android_binary and the overlay that injects the
            Flutter payload, so both agree on the compression policy.
            Matched case-sensitively by suffix.
        keystore: Release keystore (a `.jks` or PKCS#12 `.p12` file label)
            signing the APK instead of the debug keystore. Needs
            `keystore_password_file` and `key_alias`; without them analysis
            fails naming the missing attribute. Unset (with the
            `//flutter:android_release_keystore` flag unset) keeps debug
            signing. An explicit keystore always wins over the flag.
        keystore_password_file: File holding the release keystore's
            password, read by apksigner at execution time through `--ks-pass
            file:<path>`. The password text never appears on the command
            line. Only the first line is read, so end the file with a
            newline. Falls back to the
            `//flutter:android_release_keystore_password_file` flag.
        key_alias: Alias of the signing key inside `keystore`. Falls back to
            the `//flutter:android_release_key_alias` flag.
        key_password_file: File holding the signing key's own password, read
            through `--key-pass file:<path>`. When unset, `--key-pass` is
            omitted and apksigner unlocks the key with the keystore password;
            the same first-line-and-newline rule applies when it is set.
        analyze_size: Whether to emit an instructions-size JSON (<name>_size.json)
            from gen_snapshot and expose it in default outputs and the
            analyze_size output group. Works in release and profile modes;
            fails analysis in debug mode.
        **kwargs: Passed through to android_binary.
    """
    _ = pub_hub_name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = _android_internal_tags(tags)
    parts = _android_app_parts(name, struct(
        application = application,
        android_abi = android_abi,
        deps = deps,
        internal_tags = internal_tags,
        analyze_size = analyze_size,
        manifest = struct(
            package_name = package_name,
            display_name = app_name or name,
            min_sdk_version = min_sdk_version,
            target_sdk_version = target_sdk_version,
            permissions = permissions,
            internal_tags = internal_tags,
            debug_manifest = debug_manifest,
            profile_manifest = profile_manifest,
            base = manifest,
        ),
        resources = resources,
    ))
    actual_manifest = parts.actual_manifest
    resources = parts.resources
    binary_deps = parts.binary_deps

    # 9. Final android_binary, behind a proxy that scopes rules_go pure mode
    # to this app, and 10. the payload overlay. The overlay is the target
    # users actually build; the proxy is the only entry point.
    apk = struct(
        package_name = package_name,
        min_sdk_version = min_sdk_version,
        target_sdk_version = target_sdk_version,
        actual_manifest = actual_manifest,
        resources = resources,
        nocompress_extensions = nocompress_extensions,
        analyze_size = analyze_size,
        tags = tags,
        internal_tags = internal_tags,
        kwargs = kwargs,
        signing = struct(
            keystore = keystore,
            keystore_password_file = keystore_password_file,
            key_alias = key_alias,
            key_password_file = key_password_file,
        ),
    )
    _android_binary_and_overlay(name, binary_deps, deps, apk)

def flutter_android_aab(
        name,
        application,
        package_name,
        app_name = None,
        android_abi = "arm64",
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        debug_manifest = None,
        profile_manifest = None,
        permissions = [],
        resources = [],
        deps = [],
        pub_hub_name = "deps",
        keystore = None,
        keystore_password_file = None,
        key_alias = None,
        key_password_file = None,
        **kwargs):
    """Builds an Android App Bundle (`<name>.aab`) from a flutter_application.

    Google Play requires an App Bundle for new apps. With a release keystore
    (`keystore`, or the `//flutter:android_release_keystore` flag) the bundle is
    signed with `jarsigner` from the Bazel-managed JDK toolchain, never a host
    tool; the passwords are read from their files at execution time and never
    appear on the command line. Without a keystore the bundle is **unsigned**:
    this rule never debug-signs a release bundle. The attributes, the
    `//flutter:android_release_*` flags, their precedence (an explicit attribute
    wins over its flag) and the fail-closed analysis errors are those of
    `flutter_android_app`; the signing action runs locally only (`no-remote`).

    It wires the same runner, registrant, plugins and manifest as
    `flutter_android_app`, then builds the bundle with rules_android's public
    `android_application` macro (`@rules_android//android:rules.bzl`) and a
    minimal bundle config. The proto-format resource link, the module
    conversion and `bundletool build-bundle` are that macro's own actions, with
    the sha256-pinned bundletool of its toolchain. The Flutter payload (native
    libraries per ABI and `flutter_assets`) goes into the base module.
    rules_android 0.8.0 is the floor this was built against.

    Example:

        flutter_android_aab(
            name = "my_app_aab",
            application = ":my_app",
            package_name = "com.example.myapp",
        )

    Signed with a release keystore:

        flutter_android_aab(
            name = "my_app_aab",
            application = ":my_app",
            package_name = "com.example.myapp",
            keystore = "release.jks",
            keystore_password_file = "release.storepass",
            key_alias = "upload",
        )

    Args:
        name: Target name. Produces `<name>.aab`.
        application: A flutter_application target (required).
        package_name: Android package name, e.g. "com.example.myapp" (required).
        app_name: User-facing display name. Defaults to name.
        android_abi: Target ABI, "arm64" (default) or "x64".
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        manifest: Override AndroidManifest.xml; see `flutter_android_app`.
        debug_manifest: Debug variant manifest; see `flutter_android_app`.
        profile_manifest: Profile variant manifest; see `flutter_android_app`.
        permissions: Permission names added to the manifest in every mode.
        resources: Extra resource_files for the base module.
        deps: Extra deps for the base module.
        pub_hub_name: Accepted for compatibility and no longer read; see `flutter_android_app`.
        keystore: Release keystore (`.jks` or PKCS#12 `.p12` file label) signing
            the bundle. Needs `keystore_password_file` and `key_alias`; without
            them analysis fails naming the missing attribute. Unset (with the
            flag unset) leaves the bundle unsigned. Wins over the flag.
        keystore_password_file: File holding the keystore password, read at
            execution time (`-storepass:file`). Falls back to the
            `//flutter:android_release_keystore_password_file` flag.
        key_alias: Alias of the signing key inside `keystore`. Falls back to
            the `//flutter:android_release_key_alias` flag.
        key_password_file: File holding the key's own password
            (`-keypass:file`); when unset jarsigner uses the keystore password.
        **kwargs: `tags` (defaults to `["manual"]`) and `visibility`.
    """
    _ = pub_hub_name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = _android_internal_tags(tags)
    parts = _android_app_parts(name, struct(
        application = application,
        android_abi = android_abi,
        deps = deps,
        internal_tags = internal_tags,
        analyze_size = False,
        manifest = struct(
            package_name = package_name,
            display_name = app_name or name,
            min_sdk_version = min_sdk_version,
            target_sdk_version = target_sdk_version,
            permissions = permissions,
            internal_tags = internal_tags,
            debug_manifest = debug_manifest,
            profile_manifest = profile_manifest,
            base = manifest,
        ),
        resources = resources,
    ))
    _flutter_android_aab_emit(name, struct(
        package_name = package_name,
        min_sdk_version = min_sdk_version,
        target_sdk_version = target_sdk_version,
        actual_manifest = parts.actual_manifest,
        resources = parts.resources,
        binary_deps = parts.binary_deps,
        deps = deps,
        tags = tags,
        internal_tags = internal_tags,
        visibility = kwargs.pop("visibility", None),
        signing = struct(
            keystore = keystore,
            keystore_password_file = keystore_password_file,
            key_alias = key_alias,
            key_password_file = key_password_file,
        ),
    ))
