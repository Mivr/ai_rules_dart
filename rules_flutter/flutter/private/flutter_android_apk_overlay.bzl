"""Post-link APK assembly for `flutter_android_app`.

`android_binary` feeds its `assets` through aapt2 resource linking and its
Java deps through desugaring and the dex/multidex chain. The Flutter payload —
`libapp.so` (or `kernel_blob.bin` inside `flutter_assets/` in debug builds) —
therefore re-runs resource linking (~78.5 G per debug edit at M), the dex
chain and the second resource link on every Dart edit, even though none of
those steps' outputs change.

`flutter_android_app` instead builds its `android_binary` without the Flutter
payload and finishes the APK here, the way the flutter tool adds Flutter files
after resource linking:

1. `apk-overlay` (the `apk-overlay` subcommand of
   `//flutter/private/tools:android_bundle`) splices the payload — the
   bundle's `native_libs.jar` entries plus its `flutter_assets/` tree — into a
   copy of the base unsigned APK, preserving every pre-existing entry
   byte-for-byte. Native libraries are stored uncompressed so `zipalign` can
   page-align them.
2. The Android SDK `zipalign` (`-P 16`, same as `android_binary`) aligns the
   result.
3. The Android SDK `apksigner` signs it with the same keystore and the same
   v1/v2 scheme selection `android_binary` would have used.

A Dart edit then re-runs only the overlay, align and sign steps (~7 G); the
aapt2 link, desugar, dex, shard and merge steps re-run only when Android
resources, the manifest or Java/Kotlin inputs change. The final APK is
identical in entry content, native-library alignment and signature validity to
an `android_binary` that packaged the payload itself (entry order differs:
payload entries come last).
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//providers:providers.bzl", "AndroidFeatureFlagSet", "AndroidInstrumentationInfo", "ApkInfo", "StarlarkApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_android_binary_proxy.bzl", _overlay_output_groups = "overlay_output_groups")

visibility(["//flutter/..."])

_ANDROID_SDK_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android_sdk:toolchain_type")
_DART_EXEC_TOOLCHAIN_TYPE = Label("@rules_dart//dart:exec_tools_toolchain_type")

# The `split` name in the payload split's manifest.
_SPLIT_NAME = "flutter_payload"

_ANDROID_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android:toolchain_type")

# The flags' default targets: "unset" is label identity with these, never an
# empty file list, so a flag pointing at an empty or multi-file target fails
# analysis instead of silently falling back to debug signing.
_RELEASE_KEYSTORE_UNSET = Label("//flutter:_android_release_keystore_none")
_RELEASE_KEYSTORE_PASSWORD_FILE_UNSET = Label("//flutter:_android_release_keystore_password_file_none")

def release_execution_requirements(release):
    """Execution requirements for the `ApkSignerTool` action.

    Public (no leading underscore) so the analysis suite can pin it:
    `analysistest` actions expose argv, inputs, env and outputs but not
    execution requirements.

    The release signer reads the keystore and the password files. Under a
    remote executor Bazel would upload those secrets, and under any remote or
    disk cache their digests would land in the shared action cache — an
    offline brute-force oracle for a human-chosen password. Release signing
    therefore always runs locally. The debug keystore is public, so debug
    signing keeps the default requirements.

    Args:
      release: The resolved release-signing struct, or None for debug signing.

    Returns:
      `{"no-remote": "1"}` when the signer reads release secrets, else `{}`.
    """
    if release == None:
        return {}
    return {"no-remote": "1"}

def run_zipalign(ctx, sdk, overlay_unsigned, suffix = ""):
    """Aligns the overlaid APK, exactly as android_binary does (`-P 16`).

    Args:
      ctx: Rule context.
      sdk: The Android SDK info, for `zip_align`.
      overlay_unsigned: The unsigned APK to align.
      suffix: Appended to the output name, to tell the debug splits apart.

    Returns:
      The aligned APK.
    """
    aligned = ctx.actions.declare_file("zipaligned_" + ctx.label.name + suffix + ".apk")
    align_args = ctx.actions.args()
    align_args.add("-P", "16")
    align_args.add(str(ctx.attr.zipalign_alignment))
    align_args.add(overlay_unsigned)
    align_args.add(aligned)
    ctx.actions.run(
        executable = sdk.zip_align,
        arguments = [align_args],
        inputs = [overlay_unsigned],
        outputs = [aligned],
        mnemonic = "AndroidZipAlign",
        progress_message = "Zipaligning APK with Flutter payload %s" % ctx.label,
        toolchain = _ANDROID_SDK_TOOLCHAIN_TYPE,
    )
    return aligned

def _release_sign_args(sign_args, release):
    """Adds the caller's keystore to the apksigner arguments.

    Both passwords travel as `file:` references to password-file inputs, so
    their text never appears on the command line. Without a key password
    file `--key-pass` is omitted and apksigner unlocks the key with the
    keystore password.
    """
    sign_args.add("--ks", release.keystore)
    sign_args.add("--ks-key-alias", release.alias)
    sign_args.add("--ks-pass", "file:" + release.ks_pass.path)
    if release.key_pass:
        sign_args.add("--key-pass", "file:" + release.key_pass.path)

def run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk, release, suffix = ""):
    """Signs the aligned APK with the keystore and scheme android_binary would use.

    `lineage` is the File passed with `--lineage`, or None: the caller drops
    the debug lineage under release signing, so a release APK never carries
    it. `signing` mirrors `@rules_android//flags:apk_signing_method` (wired by
    the macro via select); v4 (fs-verity) stays with android_binary — route
    it there. With `release` set, apksigner signs with the caller's keystore
    instead of the debug keys; without it every argument below is exactly the
    debug invocation.

    Args:
      ctx: Rule context.
      sdk: The Android SDK info, for `apk_signer`.
      aligned: The aligned APK to sign.
      signing_keys: The debug keystores.
      lineage: The `--lineage` File, or None.
      rotation_min_sdk: The rotation minimum SDK, or empty.
      release: The resolved release-signing struct, or None for debug signing.
      suffix: Appended to the output name, to tell the debug splits apart.

    Returns:
      The signed APK.
    """
    signing = ctx.attr.signing
    if signing == "v4":
        fail(
            "flutter_android_apk_overlay %s: apk_signing_method=v4 is not " % ctx.label +
            "supported for apps whose Flutter payload is injected after " +
            "resource linking. Sign the android_binary directly (Tier 2) instead.",
        )
    v1_enabled = signing in ("v1", "v1_v2")
    v2_enabled = signing in ("v2", "v1_v2")

    signed = ctx.actions.declare_file(ctx.label.name + suffix + ".apk")
    sign_args = ctx.actions.args()
    sign_args.add("sign")
    sign_args.add("--alignment-preserved", "true")
    if lineage:
        sign_args.add("--lineage", lineage)
    if release:
        _release_sign_args(sign_args, release)
    else:
        for i, key in enumerate(signing_keys):
            if i > 0:
                sign_args.add("--next-signer")
            sign_args.add("--ks", key)
            sign_args.add("--ks-pass", "pass:android")
    sign_args.add("--v1-signing-enabled", v1_enabled)
    sign_args.add("--v1-signer-name", "CERT")
    sign_args.add("--v2-signing-enabled", v2_enabled)

    # L-4: pass --v4-signing-enabled explicitly so apksigner never writes an
    # undeclared .idsig sidecar next to the APK output. V4 stays unsupported
    # (see the fail() above); the value here is always false.
    sign_args.add("--v4-signing-enabled", False)
    if rotation_min_sdk:
        sign_args.add("--rotation-min-sdk-version", rotation_min_sdk)
    sign_args.add("--out", signed)
    sign_args.add(aligned)
    if release:
        sign_inputs = [aligned, release.keystore, release.ks_pass]
        if release.key_pass:
            sign_inputs.append(release.key_pass)
    else:
        sign_inputs = [aligned] + signing_keys
    ctx.actions.run(
        executable = sdk.apk_signer,
        arguments = [sign_args],
        inputs = sign_inputs + ([lineage] if lineage else []),
        outputs = [signed],
        mnemonic = "ApkSignerTool",
        progress_message = "Signing APK with Flutter payload %s" % ctx.label,
        execution_requirements = release_execution_requirements(release),
        toolchain = _ANDROID_SDK_TOOLCHAIN_TYPE,
    )
    return signed

def run_overlay_tool(ctx, output_name, tool_args, inputs, message):
    """Registers one `apk-overlay` invocation that writes `output_name`.

    `tool_args` is a list of `(flag, value)` pairs placed before `--output`;
    the caller's `nocompress_extensions` and, in debug builds, `--debug` follow.

    Args:
      ctx: Rule context of the overlay rule.
      output_name: Name of the unsigned APK to declare.
      tool_args: List of `(flag, value)` pairs; a File or string value, or None for a bare flag.
      inputs: The action's input Files, besides the tool.
      message: Progress message with one `%s` for the label.

    Returns:
      The unsigned APK.
    """
    unsigned = ctx.actions.declare_file(output_name)
    overlay_args = ctx.actions.args()
    overlay_args.add("apk-overlay")
    for flag, value in tool_args:
        if value == None:
            overlay_args.add(flag)
        else:
            overlay_args.add(flag, value if type(value) == "string" else value.path)
    overlay_args.add("--output", unsigned.path)
    if ctx.attr.nocompress_extensions:
        overlay_args.add_joined("--nocompress-extensions", ctx.attr.nocompress_extensions, join_with = ",")
    if ctx.var.get("COMPILATION_MODE", "") == "dbg":
        overlay_args.add("--debug")
    ctx.actions.run(
        executable = ctx.executable._overlay_tool,
        arguments = [overlay_args],
        inputs = depset(direct = [ctx.executable._overlay_tool] + inputs),
        outputs = [unsigned],
        mnemonic = "FlutterApkOverlay",
        progress_message = message % ctx.label,
        toolchain = _DART_EXEC_TOOLCHAIN_TYPE,
    )
    return unsigned

def split_apk_groups(ctx, sdk, inputs, signing):
    """Builds the debug-only base and payload split APKs, signed like the full APK.

    The base split is the payload-free base plus the native libraries; the payload
    split is a code-free manifest plus `flutter_assets/`. A Dart edit changes only
    the payload split's inputs, so the base split is neither re-aligned nor re-signed.
    Release configurations register nothing and report empty groups.

    Args:
      ctx: Rule context.
      sdk: The Android SDK info (zipalign, apksigner).
      inputs: Struct of `base_unsigned`, `native_libs_jar`, `flutter_assets`, `merged_manifest`.
      signing: Struct of `keys`, `lineage`, `rotation`, `release`, as the full APK signs.

    Returns:
      A dict of the `base_apk` and `payload_apk` output groups.
    """
    if ctx.var.get("COMPILATION_MODE", "") != "dbg":
        return {"base_apk": depset(), "payload_apk": depset()}
    base_unsigned = run_overlay_tool(
        ctx,
        ctx.label.name + "_base_unsigned.apk",
        [
            ("--base", inputs.base_unsigned),
            ("--native-libs-jar", inputs.native_libs_jar),
            ("--no-flutter-assets", None),
        ],
        [inputs.base_unsigned, inputs.native_libs_jar],
        "Assembling base split APK %s",
    )
    payload_unsigned = run_overlay_tool(
        ctx,
        ctx.label.name + "_payload_unsigned.apk",
        [
            ("--split-name", _SPLIT_NAME),
            ("--manifest", inputs.merged_manifest),
            ("--flutter-assets", inputs.flutter_assets),
        ],
        [inputs.merged_manifest, inputs.flutter_assets],
        "Assembling payload split APK %s",
    )
    groups = {}
    splits = (("base_apk", base_unsigned, "_base"), ("payload_apk", payload_unsigned, "_payload"))
    for group, unsigned, suffix in splits:
        aligned = run_zipalign(ctx, sdk, unsigned, suffix)
        signed = run_apksign(
            ctx,
            sdk,
            aligned,
            signing.keys,
            signing.lineage,
            signing.rotation,
            signing.release,
            suffix,
        )
        groups[group] = depset([signed])
    return groups

def overlay_signing_select(min_sdk_version):
    """Selects the APK signature scheme based on minimum SDK and compilation mode.

    In debug builds (`-c dbg`), apps with `minSdkVersion` 24 or higher default
    to APK Signature Scheme v2 alone (`v2`) for faster archive-level hashing.
    Apps below API 24 fall back to `v1_v2` so they remain installable on Android
    devices lacking standalone v2 support. Release builds keep the default
    `v1_v2` scheme. An explicit `@rules_android//flags:apk_signing_method` flag
    overrides this default in all configurations.

    Args:
      min_sdk_version: Minimum Android SDK version (int or string).

    Returns:
      A select() dictionary expression resolving to the signing scheme string.
    """
    sdk = int(min_sdk_version) if min_sdk_version != None else 21
    if sdk >= 24:
        return select({
            "@rules_flutter//flutter/private:apk_signing_v1_dbg": "v1",
            "@rules_flutter//flutter/private:apk_signing_v2_dbg": "v2",
            "@rules_flutter//flutter/private:apk_signing_v4_dbg": "v4",
            "@rules_flutter//flutter:apk_signing_v1": "v1",
            "@rules_flutter//flutter:apk_signing_v2": "v2",
            "@rules_flutter//flutter:apk_signing_v4": "v4",
            "@rules_flutter//flutter/private:dbg": "v2",
            "//conditions:default": "v1_v2",
        })
    return select({
        "@rules_flutter//flutter:apk_signing_v1": "v1",
        "@rules_flutter//flutter:apk_signing_v2": "v2",
        "@rules_flutter//flutter:apk_signing_v4": "v4",
        "//conditions:default": "v1_v2",
    })

def _single_secret_file(ctx, files, setting, source):
    """Returns the one file a release-signing setting must name, failing closed.

    Args:
      ctx: Rule context, for the label in the error.
      files: The resolved files behind the setting.
      setting: The user-facing name of the setting (attribute or flag).
      source: The label the setting names.

    Returns:
      The single File.
    """
    if len(files) == 1:
        return files[0]
    fail(
        "%s: %s names %s with %s files; " % (ctx.label, setting, source, len(files)) +
        "it must name a target with exactly one file — never an `allow_empty` glob.",
    )

def _resolve_release_keystore(ctx):
    """Resolves the release keystore file, or None to keep debug signing.

    An explicit `keystore` attribute always wins over the flag. The flag
    counts as unset only while it still names its default target.
    """
    if ctx.attr.keystore != None:
        return _single_secret_file(ctx, ctx.files.keystore, "`keystore`", ctx.attr.keystore.label)
    if ctx.attr._release_keystore.label == _RELEASE_KEYSTORE_UNSET:
        return None
    return _single_secret_file(
        ctx,
        ctx.files._release_keystore,
        "`//flutter:android_release_keystore`",
        ctx.attr._release_keystore.label,
    )

def _resolve_release_keystore_password(ctx):
    """Resolves the keystore password file, or None when neither source names one."""
    if ctx.attr.keystore_password_file != None:
        return _single_secret_file(
            ctx,
            ctx.files.keystore_password_file,
            "`keystore_password_file`",
            ctx.attr.keystore_password_file.label,
        )
    if ctx.attr._release_keystore_password_file.label == _RELEASE_KEYSTORE_PASSWORD_FILE_UNSET:
        return None
    return _single_secret_file(
        ctx,
        ctx.files._release_keystore_password_file,
        "`//flutter:android_release_keystore_password_file`",
        ctx.attr._release_keystore_password_file.label,
    )

def _resolve_release_key_password(ctx):
    """Resolves the key password file, or None when the attribute is unset."""
    if ctx.attr.key_password_file == None:
        return None
    return _single_secret_file(
        ctx,
        ctx.files.key_password_file,
        "`key_password_file`",
        ctx.attr.key_password_file.label,
    )

def _overlay_merged_manifest(ctx, base):
    """Recovers the merged manifest from the base binary's deploy-info group.

    ApkInfo carries no merged manifest; the base binary's android_deploy_info
    output group pairs the base deploy_info.pb with the merged manifest (see
    rules_android's apk_packaging).

    Returns:
      A `(merged_manifest, base_groups)` tuple.
    """
    base_groups = base[OutputGroupInfo] if OutputGroupInfo in base else None
    base_deploy_files = []
    if base_groups:
        base_deploy_group = getattr(base_groups, "android_deploy_info", None)
        if type(base_deploy_group) == "depset":
            base_deploy_files = base_deploy_group.to_list()
    merged_manifests = [
        f
        for f in base_deploy_files
        if not f.basename.endswith(".pb")
    ]
    if len(merged_manifests) != 1:
        fail(
            "flutter_android_apk_overlay %s: expected exactly one merged " % ctx.label +
            "manifest in the base android_deploy_info group, got %s" %
            [f.path for f in base_deploy_files],
        )
    return merged_manifests[0], base_groups

def _run_apk_overlay(ctx, base_unsigned, native_libs_jar, flutter_assets):
    """Splices the Flutter payload into a copy of the base unsigned APK."""
    return run_overlay_tool(
        ctx,
        ctx.label.name + "_overlay_unsigned.apk",
        [("--base", base_unsigned), ("--native-libs-jar", native_libs_jar), ("--flutter-assets", flutter_assets)],
        [base_unsigned, native_libs_jar, flutter_assets],
        "Injecting Flutter payload into base APK %s",
    )

def _overlay_signing_keys(ctx):
    """Collects the debug signing keys, falling back to the debug keystore."""
    signing_keys = list(ctx.files.debug_signing_keys)
    if not signing_keys and ctx.file.debug_key:
        signing_keys.append(ctx.file.debug_key)
    return signing_keys

def resolve_release_signing(ctx):
    """Resolves the release keystore, or None to keep debug signing.

    An explicit attribute always wins over its `//flutter:android_release_*`
    flag, so a target that names its keystore signs with it while a target
    that names none takes the secret from the command line (or the debug key
    when no flag is set either). "Unset" is label identity with the flag's
    default target — never an empty file list — so a flag pointing at an
    empty or multi-file target fails analysis naming the flag, the label and
    the file count instead of silently debug-signing. A resolved keystore
    without its password file or alias fails, naming the missing attribute.

    Shared by `flutter_android_apk_overlay` and the `flutter_android_aab` file
    rule: both declare the same signing attributes and flags.

    Args:
      ctx: Rule context of a rule declaring the release-signing attributes and flags.

    Returns:
      A struct of `keystore`, `ks_pass`, `alias` and `key_pass` files, or None for no release signing.
    """
    keystore = _resolve_release_keystore(ctx)
    if keystore == None:
        return None
    ks_pass = _resolve_release_keystore_password(ctx)
    if ks_pass == None:
        fail(
            "%s: `keystore` is set but " % ctx.label +
            "`keystore_password_file` is not. Set both to sign with a release keystore.",
        )
    alias = ctx.attr.key_alias or ctx.attr._release_key_alias[BuildSettingInfo].value
    if not alias:
        fail(
            "%s: `keystore` is set but " % ctx.label +
            "`key_alias` is not. Set both to sign with a release keystore.",
        )

    # No `key_password_file` means no `--key-pass`: apksigner then unlocks
    # the key with the keystore password. Repeating the keystore password
    # file here would NOT do the same — apksigner consumes one line per
    # password read, so a second read from the same single-line file fails
    # with "end of file reached".
    return struct(
        keystore = keystore,
        ks_pass = ks_pass,
        alias = alias,
        key_pass = _resolve_release_key_password(ctx),
    )

def _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed):
    """Regenerates deploy info against the overlay's own signed APK and manifest.

    Exactly as android_binary's WriteDeployInfo action does (deploy_info_writer
    from the android toolchain, --manifest/--apk/--deploy_info form), so
    mobile-install/deploy tooling sees the APK this rule actually produced.
    """
    deploy_info = ctx.actions.declare_file(ctx.label.name + ".deploy_info.pb")
    ctx.actions.run(
        executable = android_toolchain.deploy_info_writer.files_to_run,
        arguments = [
            "--manifest",
            merged_manifest.path,
            "--apk",
            signed.path,
            "--deploy_info",
            deploy_info.path,
        ],
        inputs = depset(direct = [merged_manifest, signed]),
        outputs = [deploy_info],
        mnemonic = "WriteDeployInfo",
        progress_message = "Writing deploy info for overlay APK %s" % ctx.label,
        toolchain = _ANDROID_TOOLCHAIN_TYPE,
    )
    return deploy_info

def _flutter_android_apk_overlay_impl(ctx):
    base = ctx.attr.binary
    base_apk_info = base[ApkInfo]
    base_unsigned = base_apk_info.unsigned_apk
    sdk = ctx.toolchains[_ANDROID_SDK_TOOLCHAIN_TYPE].android_sdk_info
    android_toolchain = ctx.toolchains[_ANDROID_TOOLCHAIN_TYPE]

    merged_manifest, base_groups = _overlay_merged_manifest(ctx, base)

    native_libs_jar = ctx.file.native_libs_jar
    flutter_assets = ctx.file.flutter_assets

    # 1. Splice the Flutter payload into a copy of the base unsigned APK.
    overlay_unsigned = _run_apk_overlay(ctx, base_unsigned, native_libs_jar, flutter_assets)

    # 2. Align, exactly as android_binary does (`-P 16`, same alignment).
    aligned = run_zipalign(ctx, sdk, overlay_unsigned)

    # 3. Sign with the same keystore and scheme selection android_binary
    # would have used — or the caller's release keystore when configured.
    # A release signature never carries the debug lineage: the apksigner run
    # below omits `--lineage`, and the providers report None. Debug signing
    # keeps the lineage exactly as before.
    signing_keys = _overlay_signing_keys(ctx)
    lineage = ctx.file.debug_signing_lineage_file
    rotation_min_sdk = ctx.attr.key_rotation_min_sdk
    release = resolve_release_signing(ctx)
    effective_lineage = None if release else lineage
    effective_rotation = rotation_min_sdk if rotation_min_sdk else None
    signed = run_apksign(ctx, sdk, aligned, signing_keys, effective_lineage, rotation_min_sdk, release)

    # 4. Regenerate deploy info against the overlay's own signed APK and
    # merged manifest.
    deploy_info = _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed)

    # Forward the base output groups verbatim EXCEPT android_deploy_info.
    group_kwargs = _overlay_output_groups(base_groups, deploy_info, merged_manifest)

    # Debug builds also expose the base and the Dart payload as separate signed splits.
    group_kwargs.update(split_apk_groups(
        ctx,
        sdk,
        struct(
            base_unsigned = base_unsigned,
            native_libs_jar = native_libs_jar,
            flutter_assets = flutter_assets,
            merged_manifest = merged_manifest,
        ),
        struct(keys = signing_keys, lineage = effective_lineage, rotation = rotation_min_sdk, release = release),
    ))
    if ctx.file.size_json:
        group_kwargs["analyze_size"] = depset([ctx.file.size_json])

    keystore = release.keystore if release else (signing_keys[0] if signing_keys else None)
    release_signing_keys = [release.keystore] if release else signing_keys
    providers = [
        DefaultInfo(files = depset([signed])),
        ApkInfo(
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
            deploy_jar = base_apk_info.deploy_jar,
            coverage_metadata = base_apk_info.coverage_metadata,
            signing_keys = release_signing_keys,
            signing_lineage = effective_lineage,
            signing_min_v3_rotation_api_version = effective_rotation,
            keystore = keystore,
        ),
        StarlarkApkInfo(
            keystore = keystore,
            signing_keys = release_signing_keys,
            signing_lineage = effective_lineage,
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
        ),
        base[JavaInfo],
        OutputGroupInfo(**group_kwargs),
    ]
    if AndroidFeatureFlagSet in base:
        providers.append(base[AndroidFeatureFlagSet])
    if AndroidInstrumentationInfo in base:
        providers.append(base[AndroidInstrumentationInfo])
    return providers

flutter_android_apk_overlay = rule(
    implementation = _flutter_android_apk_overlay_impl,
    attrs = {
        "binary": attr.label(
            doc = "The payload-free android_binary whose unsigned APK is the overlay base.",
            mandatory = True,
            providers = [ApkInfo],
        ),
        "native_libs_jar": attr.label(
            doc = "The bundle's native_libs.jar; its lib/<abi>/*.so entries are stored into the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "flutter_assets": attr.label(
            doc = "The bundle's flutter_assets directory; archived as assets/flutter_assets/ in the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "size_json": attr.label(
            doc = "The size JSON file from the bundle if analyze_size was enabled.",
            allow_single_file = True,
        ),
        "signing": attr.string(
            doc = "APK signature schemes, mirroring @rules_android//flags:apk_signing_method. One of v1, v1_v2, v2.",
            default = "v1_v2",
            values = ["v1", "v1_v2", "v2", "v4"],
        ),
        "zipalign_alignment": attr.int(
            doc = "Alignment in bytes, matching android_binary's zipalign_alignment.",
            default = 4,
        ),
        "nocompress_extensions": attr.string_list(
            doc = "Extra asset extensions stored uncompressed in the overlaid APK, " +
                  "on top of the aapt2 defaults, matching android_binary's " +
                  "nocompress_extensions. Matched case-sensitively by suffix.",
        ),
        "debug_key": attr.label(
            doc = "Debug keystore, matching android_binary's debug_key.",
            cfg = "exec",
            default = Label("@rules_android//tools/android:debug_keystore"),
            allow_single_file = True,
        ),
        "debug_signing_keys": attr.label_list(
            doc = "Debug keystores, matching android_binary's debug_signing_keys.",
            allow_files = True,
        ),
        "debug_signing_lineage_file": attr.label(
            doc = "Signing lineage, matching android_binary's debug_signing_lineage_file. " +
                  "Debug signing passes it to apksigner with `--lineage`. A release-signed APK " +
                  "(a `keystore` here or the `//flutter:android_release_keystore` flag) signs " +
                  "without it and reports no lineage.",
            allow_single_file = True,
        ),
        "key_rotation_min_sdk": attr.string(
            doc = "Rotation minimum SDK, matching android_binary's key_rotation_min_sdk. " +
                  "Passed to apksigner with `--rotation-min-sdk-version` when set; the " +
                  "overlay's ApkInfo reports the value its own signing run used.",
            default = "",
        ),
        "keystore": attr.label(
            doc = "Release keystore (.jks or PKCS#12 .p12) signing this APK instead of the debug keystore. " +
                  "Needs `keystore_password_file` and `key_alias`; without them analysis fails. " +
                  "Must name a target with exactly one file: an empty or multi-file target fails analysis " +
                  "instead of falling back to debug signing. " +
                  "Release signing omits the debug lineage: even with `debug_signing_lineage_file` set, " +
                  "apksigner gets no `--lineage` and the overlay reports no lineage. " +
                  "When unset (with the `//flutter:android_release_keystore` flag unset) the APK signs " +
                  "with the debug keystore exactly as before. An explicit keystore always wins over the flag.",
            allow_files = True,
        ),
        "keystore_password_file": attr.label(
            doc = "File holding the release keystore's password, read by apksigner at execution time " +
                  "through `--ks-pass file:<path>`. Mandatory with `keystore`; the password text never " +
                  "appears on the command line. Only the first line is read; end the file with a newline. " +
                  "Must name a target with exactly one file. " +
                  "Falls back to the `//flutter:android_release_keystore_password_file` flag.",
            allow_files = True,
        ),
        "key_alias": attr.string(
            doc = "Alias of the signing key inside `keystore`. Mandatory with `keystore`. " +
                  "Falls back to the `//flutter:android_release_key_alias` flag.",
            default = "",
        ),
        "key_password_file": attr.label(
            doc = "File holding the signing key's own password, read through `--key-pass file:<path>`. " +
                  "When unset `--key-pass` is omitted and apksigner unlocks the key with the keystore " +
                  "password. Only the first line is read; end the file with a newline. " +
                  "When set it must name a target with exactly one file.",
            allow_files = True,
        ),
        "_release_keystore": attr.label(
            default = Label("//flutter:android_release_keystore"),
            doc = "Release keystore flag (a label_flag BuildSettingInfo).",
        ),
        "_release_keystore_password_file": attr.label(
            default = Label("//flutter:android_release_keystore_password_file"),
            doc = "Release keystore password-file flag (a label_flag BuildSettingInfo).",
        ),
        "_release_key_alias": attr.label(
            default = Label("//flutter:android_release_key_alias"),
            doc = "Release key alias flag (a string BuildSettingInfo).",
        ),
        "_overlay_tool": attr.label(
            doc = "Tool that splices the Flutter payload into a copy of the base unsigned APK.",
            default = Label("//flutter/private/tools:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
        "@rules_android//toolchains/android_sdk:toolchain_type",
        "@rules_android//toolchains/android:toolchain_type",
    ],
    doc = """Finishes a payload-free android_binary into a signed APK by injecting the Flutter payload after resource linking.

Takes the base unsigned APK, splices the bundle's native libraries and
flutter_assets into it, then zipaligns and signs with the Android SDK tools —
the same steps android_binary would have run. Created by the
`flutter_android_app` macro; use directly only when assembling an
`android_binary` by hand without the macro.
""",
)
