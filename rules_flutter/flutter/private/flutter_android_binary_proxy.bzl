"""Android binary proxy: scope rules_go pure mode to Flutter Android apps.

rules_android's Go host tools (`src/tools/ak` and friends, all cgo-free)
link through rules_go's cgo path, which resolves the hermetic LLVM C++ toolchain
and compiles its runtimes (compiler-rt builtins, libc++, libc++abi, libunwind)
from source: hundreds of C++ actions in every clean Android build.
`--@rules_go//go/config:pure=true` removes them, but as a global flag it would
also force pure mode on a consumer's own cgo Go code, so it is not something to
ask users to set.

`flutter_android_app` therefore puts this proxy rule where the `android_binary`
used to be, and the proxy's outgoing edge transition sets
`@rules_go//go/config:pure` on the binary behind it. The setting is
universal-scoped, so it propagates from the binary's target configuration into
the execution configuration the Go host tools build in (rules_go's own tool
transitions inherit it too). Nothing outside the proxy's subtree sees it:
desktop apps and the consumer's own Go targets keep their configuration.

The proxy forwards the binary's providers and exposes the signed APK under the
proxy's own `<name>.apk` name, so `bazel build`, `data = [...]` consumers and
APK-verifying tests see the same files as before. The binary behind the proxy
is tagged `manual`, so wildcard builds (`//...`) only build the app once,
through the proxy; nothing should reference the private
`__<name>_binary` target directly.
"""

load(
    "@rules_android//providers:providers.bzl",
    "AndroidFeatureFlagSet",
    "AndroidInstrumentationInfo",
    "ApkInfo",
    "StarlarkApkInfo",
)
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_drive_test.bzl", _flutter_drive_test = "flutter_drive_test")

visibility(["//flutter/..."])

# Re-exported so `flutter/android.bzl` reaches the rule through its existing dep.
flutter_drive_test = _flutter_drive_test

# The aapt2 default no-compress extension list that both the overlay tool and
# android_binary's own packaging apply. Reference apps in e2e tests pass this to
# android_binary's nocompress_extensions so entry-by-entry parity checks
# compare the same compression policy on both APKs.
FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS = [
    "jpg",
    "jpeg",
    "png",
    "gif",
    "wav",
    "mp2",
    "mp3",
    "ogg",
    "aac",
    "mpg",
    "mpeg",
    "mid",
    "midi",
    "smf",
    "jet",
    "rtttl",
    "imy",
    "xmf",
    "mp4",
    "m4a",
    "m4v",
    "3gp",
    "3gpp",
    "3g2",
    "3gpp2",
    "amr",
    "awb",
    "wma",
    "wmv",
    "webm",
    "mkv",
    "webp",
]

def _pure_go_transition_impl(settings, _attr):
    """Set rules_go pure mode for the Android binary subtree, unless opted out.

    Args:
        settings: The incoming configuration. Only `//flutter:android_pure_go`
            is read; everything else passes through untouched.
        _attr: Unused (the opt-out is a flag, not a rule attribute).

    Returns:
        `{"@rules_go//go/config:pure": True}` by default, `{}` when the user
        opts out with `--@rules_flutter//flutter:android_pure_go=false`
        (an empty dict leaves the configuration exactly as it was).
    """
    if settings["//flutter:android_pure_go"]:
        return {"@rules_go//go/config:pure": True}
    return {}

flutter_android_pure_go_transition = transition(
    implementation = _pure_go_transition_impl,
    inputs = ["//flutter:android_pure_go"],
    outputs = ["@rules_go//go/config:pure"],
)

def _extract_depset_output_groups(output_group_info, exclude = ()):
    """Extracts valid depset output groups from OutputGroupInfo, skipping excluded names.

    Args:
        output_group_info: OutputGroupInfo provider instance or None.
        exclude: Sequence of attribute names to exclude.

    Returns:
        Dict mapping output group names to depsets.
    """
    groups = {}
    if not output_group_info:
        return groups
    for name in dir(output_group_info):
        if name in ("to_json", "to_proto") or name in exclude:
            continue
        val = getattr(output_group_info, name, None)
        if type(val) == "depset":
            groups[name] = val
    return groups

def _collect_proxy_output_groups(binary):
    """Collects output group mapping from the binary target.

    Args:
        binary: The inner binary target.

    Returns:
        Dict mapping output group names to depsets.
    """
    if OutputGroupInfo not in binary:
        return {}
    return _extract_depset_output_groups(binary[OutputGroupInfo])

def _handle_proxy_analyze_size(ctx, output_groups):
    """Processes analyze_size output for the proxy target.

    Args:
        ctx: Rule context.
        output_groups: Dict of collected output groups to update.

    Returns:
        The declared APK size File, or None.
    """
    if not ctx.attr.analyze_size:
        return None
    if ctx.var.get("COMPILATION_MODE") == "dbg":
        fail("%s: analyze_size is not supported in debug mode: gen_snapshot does not run in debug mode" % ctx.label)
    if "analyze_size" not in output_groups:
        return None
    size_list = output_groups["analyze_size"].to_list()
    if not size_list:
        return None
    apk_size = ctx.actions.declare_file(ctx.label.name + "_size.json")
    ctx.actions.symlink(output = apk_size, target_file = size_list[0])
    output_groups["analyze_size"] = depset([apk_size])
    return apk_size

def _build_proxy_providers(ctx, binary, default_files, output_groups):
    """Builds the provider list returned by the proxy rule.

    Args:
        ctx: Rule context.
        binary: The inner binary target.
        default_files: List of default output files.
        output_groups: Dict of forwarded output groups.

    Returns:
        List of providers.
    """
    binary_default = binary[DefaultInfo]
    default_runfiles = binary_default.default_runfiles.merge(
        ctx.runfiles(files = default_files),
    )
    data_runfiles = default_runfiles
    if binary_default.data_runfiles:
        data_runfiles = binary_default.data_runfiles.merge(ctx.runfiles(files = default_files))
    providers = [
        DefaultInfo(
            files = depset(default_files),
            default_runfiles = default_runfiles,
            data_runfiles = data_runfiles,
        ),
        binary[ApkInfo],
        binary[JavaInfo],
    ]
    if output_groups:
        providers.append(OutputGroupInfo(**output_groups))
    for prov in (AndroidFeatureFlagSet, StarlarkApkInfo, AndroidInstrumentationInfo):
        if prov in binary:
            providers.append(binary[prov])
    return providers

def _flutter_android_binary_proxy_impl(ctx):
    """Builds the proxy rule forwarding providers and signed APK.

    Args:
        ctx: Rule context.

    Returns:
        List of providers forwarded from the inner binary.
    """
    binary = ctx.attr.binary[0]
    signed_apk = binary[ApkInfo].signed_apk

    apk = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.symlink(output = apk, target_file = signed_apk)

    default_files = [apk]
    output_groups = _collect_proxy_output_groups(binary)
    apk_size = _handle_proxy_analyze_size(ctx, output_groups)
    if apk_size:
        default_files.append(apk_size)

    return _build_proxy_providers(ctx, binary, default_files, output_groups)

flutter_android_binary_proxy = rule(
    implementation = _flutter_android_binary_proxy_impl,
    attrs = {
        "analyze_size": attr.bool(
            doc = "Whether to expose instructions-size JSON in default outputs and analyze_size group.",
            default = False,
        ),
        "binary": attr.label(
            doc = "The APK target built behind this proxy (the apk overlay), in pure-Go configuration.",
            mandatory = True,
            providers = [ApkInfo],
            cfg = flutter_android_pure_go_transition,
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = """Builds an android_binary with rules_go pure mode scoped to its subtree.

Forwards the binary's providers and re-exposes its signed APK as `<name>.apk`.
Created by the `flutter_android_app` macro; not for direct use.
""",
)

testing = struct(
    pure_go_transition_impl = _pure_go_transition_impl,
    pure_go_transition = flutter_android_pure_go_transition,
)

def overlay_output_groups(base_groups, deploy_info, merged_manifest):
    """Forwards the base output groups, replacing android_deploy_info.

    The fresh group is overlay-owned: the freshly written deploy_info pointing
    at the overlay signed APK, paired with the merged manifest.

    Args:
        base_groups: The OutputGroupInfo from the base binary.
        deploy_info: The regenerated deploy_info file.
        merged_manifest: The merged manifest file.

    Returns:
        Dict of output group names to depsets.
    """
    group_kwargs = _extract_depset_output_groups(base_groups, exclude = ("android_deploy_info",))
    group_kwargs["android_deploy_info"] = depset([deploy_info, merged_manifest])
    return group_kwargs

def build_overlay_kwargs(apk, passthrough):
    """Collects kwargs for flutter_android_apk_overlay from apk struct and passthrough attrs.

    Args:
        apk: Struct containing apk options and signing settings.
        passthrough: Dict of passthrough attributes (compatible_with, restricted_to, testonly).

    Returns:
        Dict of kwargs for flutter_android_apk_overlay.
    """
    overlay_kwargs = {}
    for key in (
        "debug_key",
        "debug_signing_keys",
        "debug_signing_lineage_file",
        "key_rotation_min_sdk",
        "zipalign_alignment",
    ):
        if key in apk.kwargs:
            overlay_kwargs[key] = apk.kwargs[key]
    if apk.nocompress_extensions != None:
        overlay_kwargs["nocompress_extensions"] = apk.nocompress_extensions
    for key, value in (
        ("keystore", apk.signing.keystore),
        ("keystore_password_file", apk.signing.keystore_password_file),
        ("key_alias", apk.signing.key_alias),
        ("key_password_file", apk.signing.key_password_file),
    ):
        if value != None:
            overlay_kwargs[key] = value
    for key in ("compatible_with", "restricted_to", "testonly"):
        if key in passthrough:
            overlay_kwargs[key] = passthrough[key]
    return overlay_kwargs
