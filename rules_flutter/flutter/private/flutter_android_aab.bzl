"""Android App Bundle (`.aab`) emission for `flutter_android_aab`.

Builds the bundle with rules_android's public `android_application` macro and
exposes it as `<name>.aab`. With a release keystore (attribute or
`//flutter:android_release_*` flag) the file is signed by `jarsigner` from the
Bazel-managed JDK toolchain; without one it stays unsigned.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", "android_application")
load(
    "//flutter/private:flutter_android_apk_overlay.bzl",
    "release_execution_requirements",
    "resolve_release_signing",
)

visibility(["//flutter/..."])

# Android App Bundle (`.aab`) emission for `flutter_android_aab`: built by rules_android 0.8.0's public
# `android_application` macro; see `flutter_android_aab_emit`.
#
# The bundle config `bundletool build-bundle` is given: every setting at its
# default. The ".pb.json" suffix is what rules_android's attribute requires.
_BUNDLE_CONFIG = "{}\n"

def _aab_assets_impl(ctx):
    """Passes through only the `flutter_assets` tree of the bundle's mobile-install group."""
    trees = [
        f
        for f in ctx.attr.bundle[OutputGroupInfo].mobile_install.to_list()
        if f.is_directory and f.basename == "flutter_assets"
    ]
    if len(trees) != 1:
        fail("%s: expected one flutter_assets tree in the bundle, got %d" % (ctx.label, len(trees)))
    return [DefaultInfo(files = depset(trees))]

_aab_assets = rule(
    implementation = _aab_assets_impl,
    attrs = {
        "bundle": attr.label(
            doc = "The `flutter_android_bundle` target whose flutter_assets tree is passed through.",
            mandatory = True,
        ),
    },
    doc = "Selects the `flutter_assets/` tree of a `flutter_android_bundle`, for an `assets` attribute.",
)

_JDK_TOOLCHAIN_TYPE = "@bazel_tools//tools/jdk:toolchain_type"

def _jarsigner(ctx):
    """Returns the `jarsigner` File of the Bazel-managed JDK toolchain, never a host tool."""
    runtime = ctx.toolchains[_JDK_TOOLCHAIN_TYPE].java.java_runtime
    if runtime != None:
        for f in runtime.files.to_list():
            if f.path.endswith(("/bin/jarsigner", "/bin/jarsigner.exe")):
                return struct(tool = f, files = runtime.files)
    home = runtime.java_home if runtime != None else "<none>"
    fail("%s: the JDK toolchain %s ships no bin/jarsigner" % (ctx.label, home))

def _sign_aab(ctx, release, out):
    """Registers the `jarsigner` action; passwords are read from their files at execution time."""
    jarsigner = _jarsigner(ctx)
    args = ctx.actions.args()
    args.add("-keystore", release.keystore)
    args.add("-storepass:file", release.ks_pass)
    inputs = [ctx.file.unsigned_aab, release.keystore, release.ks_pass]
    if release.key_pass:
        args.add("-keypass:file", release.key_pass)
        inputs.append(release.key_pass)
    args.add("-signedjar", out)
    args.add(ctx.file.unsigned_aab)
    args.add(release.alias)
    ctx.actions.run(
        executable = jarsigner.tool,
        toolchain = _JDK_TOOLCHAIN_TYPE,
        arguments = [args],
        inputs = depset(inputs, transitive = [jarsigner.files]),
        outputs = [out],
        mnemonic = "AabJarsign",
        progress_message = "Signing %s" % out.short_path,
        execution_requirements = release_execution_requirements(release),
    )

def _aab_file_impl(ctx):
    """Exposes the `.aab` as `<name>.aab`: jarsigner-signed with a keystore, else the unsigned bundle."""
    out = ctx.outputs.aab
    release = resolve_release_signing(ctx)
    if release == None:
        ctx.actions.symlink(output = out, target_file = ctx.file.unsigned_aab)
    else:
        _sign_aab(ctx, release, out)
    return [DefaultInfo(files = depset([out]))]

flutter_android_aab_file = rule(
    implementation = _aab_file_impl,
    attrs = {
        "unsigned_aab": attr.label(
            doc = "The `<name>_unsigned.aab` output of an `android_application`.",
            allow_single_file = [".aab"],
            mandatory = True,
        ),
        "keystore": attr.label(
            doc = "Release keystore (.jks or PKCS#12 .p12); see `flutter_android_aab`.",
            allow_files = True,
        ),
        "keystore_password_file": attr.label(
            doc = "File holding the keystore password, read by jarsigner via `-storepass:file`.",
            allow_files = True,
        ),
        "key_alias": attr.string(
            doc = "Alias of the signing key inside `keystore`.",
            default = "",
        ),
        "key_password_file": attr.label(
            doc = "File holding the key password, read by jarsigner via `-keypass:file`.",
            allow_files = True,
        ),
        "_release_keystore": attr.label(
            default = Label("//flutter:android_release_keystore"),
            allow_files = True,
            doc = "Release keystore flag (a label_flag).",
        ),
        "_release_keystore_password_file": attr.label(
            default = Label("//flutter:android_release_keystore_password_file"),
            allow_files = True,
            doc = "Release keystore password-file flag (a label_flag).",
        ),
        "_release_key_alias": attr.label(
            default = Label("//flutter:android_release_key_alias"),
            doc = "Release key alias flag (a string BuildSettingInfo).",
        ),
    },
    toolchains = [_JDK_TOOLCHAIN_TYPE],
    outputs = {"aab": "%{name}.aab"},
    doc = "Exposes the bundle as `<name>.aab`, signed with jarsigner when a release keystore is given.",
)

def flutter_android_aab_emit(name, aab):
    """Emits the base-module inputs, the `android_application` and the `<name>.aab` rule.

    Args:
        name: The `flutter_android_aab` name; internal targets derive from it.
        aab: Struct with `package_name`, `min_sdk_version`, `target_sdk_version`,
            `actual_manifest`, `resources`, `binary_deps`, `deps`, `tags`,
            `internal_tags`, `visibility` and `signing` (a struct of `keystore`,
            `keystore_password_file`, `key_alias` and `key_password_file`).
    """
    _aab_assets(
        name = "__%s_aab_assets" % name,
        bundle = "__%s_bundle" % name,
        tags = aab.internal_tags,
    )
    write_file(
        name = "__%s_bundle_config" % name,
        out = "__%s_bundle_config.pb.json" % name,
        content = [_BUNDLE_CONFIG],
        tags = aab.internal_tags,
    )
    android_application(
        name = "__%s_application" % name,
        manifest = aab.actual_manifest,
        manifest_values = {
            "applicationId": aab.package_name,
            "minSdkVersion": aab.min_sdk_version,
            "targetSdkVersion": aab.target_sdk_version,
            "versionCode": "1",
        },
        resource_files = aab.resources if aab.resources else None,
        assets = ["__%s_aab_assets" % name],
        assets_dir = "__%s_bundle_mi/assets" % name,
        bundle_config_file = "__%s_bundle_config.pb.json" % name,
        deps = ["__%s_native_libs" % name] + aab.binary_deps + aab.deps,
        tags = aab.internal_tags,
        target_compatible_with = select({
            Label("@platforms//os:ios"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
    )
    flutter_android_aab_file(
        name = name,
        unsigned_aab = "__%s_application_unsigned.aab" % name,
        keystore = aab.signing.keystore,
        keystore_password_file = aab.signing.keystore_password_file,
        key_alias = aab.signing.key_alias,
        key_password_file = aab.signing.key_password_file,
        tags = aab.tags,
        visibility = aab.visibility,
    )
