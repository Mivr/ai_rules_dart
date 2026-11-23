"""`xtool_pack` bundle action for the `xtool` backend (private implementation).

Holds the shared framework/runner input collection, the hermeticity
validation, and `run_xtool_pack_bundle`, which compiles the runner and packs
the archive for `flutter_xtool_ios_bundle` and `flutter_xtool_macos_bundle`
(both defined in `flutter/private/flutter_xtool_bundle.bzl`).

Usage: see flutter/private/flutter_xtool_bundle.bzl for public API.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo")
load(":flutter_xtool_bundle_frameworks.bzl", "collect_framework_args_and_inputs")
load(":xtool_darwin_sdk_repo.bzl", "FlutterXtoolSdkInfo", "UNCONFIGURED_SDK_ERROR")
load(":xtool_import.bzl", "xtool_target_arch")
load(":xtool_version.bzl", "FlutterXtoolVersionInfo")

visibility(["//flutter/..."])

# -- Shared bundle helpers -----------------------------------------------------

_SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".c", ".cc", ".cpp")

def _classify_runner_file(seen, buckets, f):
    """Sort one file into the runner's source/header/modulemap buckets, deduplicated by path."""
    if f.path in seen:
        return
    seen[f.path] = True
    if f.path.endswith(_SOURCE_SUFFIXES):
        buckets["sources"].append(f)
    elif f.path.endswith(".h"):
        buckets["headers"].append(f)
    elif f.path.endswith(".modulemap"):
        buckets["modulemaps"].append(f)

def _add_sdk_name(seen_names, ordered, value):
    """Append an SDK framework/dylib name once, preserving first-seen order."""
    if value and value not in seen_names:
        seen_names[value] = True
        ordered.append(value)

def _collect_runner_own_files(ctx, seen, buckets):
    """Classify the runner's own `srcs` and `registrant` files."""
    for f in ctx.files.srcs:
        _classify_runner_file(seen, buckets, f)
    for f in ctx.files.registrant:
        _classify_runner_file(seen, buckets, f)

def _collect_runner_linker_sdk_names(target, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib):
    """Record the SDK frameworks/dylibs named by a dep's linker flags."""
    for li in target[CcInfo].linking_context.linker_inputs.to_list():
        flags = li.user_link_flags
        for idx in range(len(flags)):
            if flags[idx] == "-framework" and idx + 1 < len(flags):
                _add_sdk_name(seen_sdk_fw, sdk_frameworks, flags[idx + 1])
            elif flags[idx].startswith("-l") and len(flags[idx]) > 2:
                _add_sdk_name(seen_sdk_dylib, sdk_dylibs, flags[idx][2:])

def _collect_runner_dep_files(
        ctx,
        seen,
        buckets,
        sdk_frameworks,
        seen_sdk_fw,
        sdk_dylibs,
        seen_sdk_dylib,
        transitive_sets):
    """Classify plugin/dep files and record their SDK frameworks, dylibs and header sets."""
    for target in ctx.attr.plugins + ctx.attr.deps:
        for f in target[DefaultInfo].files.to_list():
            _classify_runner_file(seen, buckets, f)
        if FlutterApplePluginInfo in target:
            for fw in target[FlutterApplePluginInfo].sdk_frameworks:
                _add_sdk_name(seen_sdk_fw, sdk_frameworks, fw)
            for dylib in target[FlutterApplePluginInfo].sdk_dylibs:
                _add_sdk_name(seen_sdk_dylib, sdk_dylibs, dylib)
        if CcInfo in target:
            cc_hdrs = target[CcInfo].compilation_context.headers
            transitive_sets.append(cc_hdrs)
            for f in cc_hdrs.to_list():
                _classify_runner_file(seen, buckets, f)
            _collect_runner_linker_sdk_names(target, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib)

def _collect_runner_compile_inputs(ctx):
    sources = []
    headers = []
    modulemaps = []
    sdk_frameworks = []
    sdk_dylibs = []
    seen = {}
    seen_sdk_fw = {}
    seen_sdk_dylib = {}
    transitive_sets = []
    buckets = {"sources": sources, "headers": headers, "modulemaps": modulemaps}

    _collect_runner_own_files(ctx, seen, buckets)
    _collect_runner_dep_files(
        ctx,
        seen,
        buckets,
        sdk_frameworks,
        seen_sdk_fw,
        sdk_dylibs,
        seen_sdk_dylib,
        transitive_sets,
    )

    return sources, headers, modulemaps, sdk_frameworks, sdk_dylibs, transitive_sets

def _check_resource_file_for_xtool(ctx, file_obj, attr_name):
    lower = file_obj.short_path.lower()
    segments = lower.split("/")
    for seg in segments:
        if seg.endswith(".storyboard") or seg.endswith(".xib"):
            return "%s: '%s' contains Interface Builder source %r which requires Xcode 'ibtool' to compile into a runtime .storyboardc/.nib bundle, and has no hermetic implementation on the xtool backend." % (
                ctx.label,
                attr_name,
                file_obj.short_path,
            )
        if seg.endswith(".xcassets") or seg.endswith(".appiconset") or seg.endswith(".icon"):
            return "%s: '%s' contains uncompiled asset catalog %r which requires Xcode 'actool' to compile into Assets.car/.icns, and has no hermetic implementation on the xtool backend." % (
                ctx.label,
                attr_name,
                file_obj.short_path,
            )
    return None

def _fail_on_xtool_unsupported_attrs(ctx):
    """Fail on xtool-backend attribute combinations that have no hermetic implementation."""
    if ctx.attr.unsupported_kwargs:
        fail(
            "%s (backend = 'xtool'): unsupported attribute(s) %s are not supported on the xtool backend." % (
                ctx.label,
                ", ".join(["'%s'" % k for k in sorted(ctx.attr.unsupported_kwargs)]),
            ),
        )

    if ctx.attr.invalid_version_error:
        fail(ctx.attr.invalid_version_error)

    if ctx.attr.certificate_password:
        fail(
            "%s: plain-text 'certificate_password' is not supported because signing secrets must never appear on action command lines. Use 'certificate_password_file' (a File label) or 'certificate_password_env' (an environment variable name) instead." % ctx.label,
        )

def _collect_xtool_ib_errors(ctx):
    """The Interface Builder / asset catalog errors for resources needing Xcode tools."""
    ib_errors = []
    if hasattr(ctx.file, "launch_storyboard") and ctx.file.launch_storyboard:
        ib_errors.append(
            "%s: 'launch_storyboard' (%s) is not supported on the xtool backend because compiling .storyboard files requires Xcode 'ibtool', which has no hermetic cross-platform implementation." % (
                ctx.label,
                ctx.file.launch_storyboard.short_path,
            ),
        )

    if hasattr(ctx.file, "menu_xib") and ctx.file.menu_xib:
        ib_errors.append(
            "%s: 'menu_xib' (%s) is not supported on the xtool backend because compiling .xib files requires Xcode 'ibtool', which has no hermetic cross-platform implementation. Remove %s (and omit 'menu_xib') to use the default programmatic menu, or use backend = \"rules_apple\"." % (
                ctx.label,
                ctx.file.menu_xib.short_path,
                ctx.file.menu_xib.short_path,
            ),
        )

    if ctx.files.app_icons:
        fail(
            "%s: 'app_icons' (%s) is not supported on the xtool backend because compiling asset catalogs (.xcassets / .appiconset / .icon) requires Xcode 'actool', which has no hermetic cross-platform implementation." % (
                ctx.label,
                ctx.files.app_icons[0].short_path,
            ),
        )

    for res_file in ctx.files.resources:
        err = _check_resource_file_for_xtool(ctx, res_file, "resources")
        if err:
            ib_errors.append(err)
    return ib_errors

def _collect_xtool_additional_contents(ctx, ib_errors):
    """Validate `additional_contents` and return its `(subdir=file)` pairs and files."""
    additional_content_pairs = []
    additional_content_files = []
    for target, subdir in ctx.attr.additional_contents.items():
        if not subdir or subdir.startswith("/") or ".." in subdir.split("/"):
            fail(
                "%s: invalid 'additional_contents' subdirectory %r for %s; must be a relative bundle subdirectory without '..'." % (
                    ctx.label,
                    subdir,
                    target.label,
                ),
            )
        for f in target[DefaultInfo].files.to_list():
            err = _check_resource_file_for_xtool(ctx, f, "additional_contents")
            if err:
                ib_errors.append(err)
            additional_content_pairs.append("%s=%s" % (subdir, f.path))
            additional_content_files.append(f)
    return additional_content_pairs, additional_content_files

def _xtool_sdk_availability(ctx):
    """Whether the xtool SDK repo resolved, plus its files for action inputs."""
    sdk_available = False
    sdk_transitive = []
    if ctx.attr._xtool_sdk_status and FlutterXtoolSdkInfo in ctx.attr._xtool_sdk_status:
        sdk_info = ctx.attr._xtool_sdk_status[FlutterXtoolSdkInfo]
        sdk_available = sdk_info.sdk_available
        sdk_transitive.append(sdk_info.sdk_files)
    return sdk_available, sdk_transitive

def _compile_xtool_runner(ctx, platform, app_name, arch, sdk_available, frameworks, sdk_transitive):
    """Compile the runner executable via `xtool_pack compile-runner`; returns its File."""
    executable_file = ctx.actions.declare_file("%s_runner_bin" % ctx.label.name)
    collected = _collect_runner_compile_inputs(ctx)
    sources, headers, modulemaps, sdk_frameworks, sdk_dylibs, plugin_transitive_sets = collected

    runner_args = ctx.actions.args()
    runner_args.add("compile-runner")
    runner_args.add("--platform", platform)
    runner_args.add("--arch", arch)
    runner_args.add("--app-name", app_name)
    runner_args.add("--minimum-os-version", ctx.attr.minimum_os_version)
    runner_args.add("--sdk-available", "true" if sdk_available else "false")
    runner_args.add("--output", executable_file.path)

    for src in sources:
        runner_args.add("--source", src.path)
    for hdr in headers:
        runner_args.add("--header", hdr.path)
    for mm in modulemaps:
        runner_args.add("--modulemap", mm.path)
    for fw_dir in frameworks.compile.dirs:
        runner_args.add("--framework", fw_dir)
    for sdk_fw in sdk_frameworks:
        runner_args.add("--sdk-framework", sdk_fw)
    for sdk_dylib in sdk_dylibs:
        runner_args.add("--sdk-dylib", sdk_dylib)

    ctx.actions.run(
        executable = ctx.executable._xtool_pack,
        arguments = [runner_args],
        env = {"TMPDIR": executable_file.dirname},
        use_default_shell_env = False,
        inputs = depset(
            direct = sources + headers + modulemaps,
            transitive = frameworks.compile.transitive_inputs + plugin_transitive_sets + sdk_transitive,
        ),
        outputs = [executable_file],
        mnemonic = "FlutterXtoolRunner",
        progress_message = "Compiling runner executable for %s (%s) via xtool_pack" % (ctx.label, platform),
        toolchain = None,
    )
    return executable_file

def _add_xtool_bundle_content_args(
        ctx,
        args,
        families,
        fw_dirs,
        native_libs,
        resources,
        additional_content_pairs,
        infoplists):
    """Append the bundle payload flags (families, defines, plists, frameworks, libs, resources)."""
    for fam in families:
        args.add("--family", fam)
    if ctx.attr.build_version:
        args.add("--define", "FLUTTER_BUILD_NUMBER=%s" % ctx.attr.build_version)
    if ctx.attr.short_version:
        args.add("--define", "FLUTTER_BUILD_NAME=%s" % ctx.attr.short_version)
    for k, v in ctx.attr.defines.items():
        args.add("--define", "%s=%s" % (k, v))

    for plist in infoplists:
        args.add("--info-plist", plist.path)

    for fw_dir in fw_dirs:
        args.add("--framework", fw_dir)

    for dylib in native_libs:
        args.add("--native-lib", dylib.path)

    for res in resources:
        args.add("--resource", res.path)

    for pair in additional_content_pairs:
        args.add("--additional-content", pair)

def _add_xtool_version_args(ctx, args, direct_inputs):
    """Append the `--version-file` flag and register the version file as an input."""
    version_files = ctx.files.version
    if not version_files:
        fail(
            "%s: 'version' target %s did not produce a version file; expected an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON file with 'build_version' and 'short_version_string'." % (
                ctx.label,
                ctx.attr.version.label,
            ),
        )
    vf = version_files[0]
    if FlutterXtoolVersionInfo not in ctx.attr.version and not (vf.basename.endswith(".json") or vf.basename.endswith(".bundle_version")):
        fail(
            "%s: 'version' target %s (%s) is not supported on the xtool backend; expected an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON file with 'build_version' and 'short_version_string'." % (
                ctx.label,
                ctx.attr.version.label,
                vf.short_path,
            ),
        )
    args.add("--version-file", vf.path)
    direct_inputs.append(vf)

def _add_xtool_signing_args(ctx, args, direct_inputs):
    """Append the signing flags, registering each referenced file as an input."""
    if ctx.file.provisioning_profile:
        args.add("--provisioning-profile", ctx.file.provisioning_profile.path)
        direct_inputs.append(ctx.file.provisioning_profile)

    if ctx.file.entitlements:
        args.add("--entitlements", ctx.file.entitlements.path)
        direct_inputs.append(ctx.file.entitlements)

    if ctx.executable.zsign:
        args.add("--zsign", ctx.executable.zsign.path)
        direct_inputs.append(ctx.executable.zsign)

    if ctx.file.certificate:
        args.add("--certificate", ctx.file.certificate.path)
        direct_inputs.append(ctx.file.certificate)

    if ctx.file.certificate_password_file:
        args.add("--certificate-password-file", ctx.file.certificate_password_file.path)
        direct_inputs.append(ctx.file.certificate_password_file)

def _xtool_bundle_action_env(ctx, default_tmpdir):
    """The hermetic environment for the `xtool_pack bundle` action.

    Args:
        ctx: The rule context.
        default_tmpdir: The `TMPDIR` used when the caller sets none (an
            action-scoped output directory).

    Returns:
        The environment dict, keeping any explicit non-empty `TMPDIR`.
    """
    action_env = dict(ctx.attr.env)
    if ctx.attr.certificate_password_env:
        if ctx.attr.certificate_password_env not in action_env:
            action_env[ctx.attr.certificate_password_env] = ""
    if not action_env.get("TMPDIR"):
        action_env["TMPDIR"] = default_tmpdir
    return action_env

def _xtool_bundle_base_args(ctx, platform, app_name, executable_file, archive_file, app_dir):
    """The leading `xtool_pack bundle` flags identifying the app and its outputs."""
    args = ctx.actions.args()
    args.add("bundle")
    args.add("--platform", platform)
    args.add("--app-name", app_name)
    args.add("--bundle-id", ctx.attr.bundle_id)
    args.add("--executable", executable_file.path)
    args.add("--minimum-os-version", ctx.attr.minimum_os_version)
    args.add("--temp-dir", archive_file.path + ".tmp")
    args.add("--output-archive", archive_file.path)
    args.add("--output-app-dir", app_dir.path)
    return args

def _add_xtool_env_args(ctx, args, archive_file):
    """Adds the isolated-environment flags and returns the action's `env`.

    Args:
        ctx: Rule context of the calling bundle rule.
        args: The `ctx.actions.args()` being built.
        archive_file: The bundle archive; its directory is the action's tmp dir.

    Returns:
        The environment dict for the pack action.
    """
    action_env = _xtool_bundle_action_env(ctx, archive_file.dirname)
    args.add("--isolated-env")
    for env_key in sorted(ctx.attr.env.keys()):
        if env_key != "TMPDIR" and env_key != "TEST_TMPDIR":
            args.add("--declared-env", env_key)
    if ctx.attr.certificate_password_env:
        args.add("--certificate-password-env", ctx.attr.certificate_password_env)
        if ctx.attr.certificate_password_env not in action_env:
            action_env[ctx.attr.certificate_password_env] = ""
    return action_env

def _xtool_bundle_providers(ctx, archive_file, app_dir, executable_file):
    """The pack action's providers.

    Args:
        ctx: Rule context of the calling bundle rule.
        archive_file: The bundle archive.
        app_dir: The unpacked `.app` directory.
        executable_file: The runner binary inside the bundle.

    Returns:
        `DefaultInfo` with the archive, plus `OutputGroupInfo`.
    """
    return [
        DefaultInfo(
            files = depset([archive_file]),
            runfiles = ctx.runfiles(files = [archive_file]),
        ),
        OutputGroupInfo(
            archive = depset([archive_file]),
            app_dir = depset([app_dir]),
            runner_binary = depset([executable_file]),
        ),
    ]

def run_xtool_pack_bundle(
        ctx,
        *,
        platform,
        archive_ext,
        mnemonic,
        families = [],
        native_libs = []):
    """Assembles one Apple bundle with the `xtool_pack` host tool.

    Validates the rule attributes, compiles the runner when needed, then
    packs the `.app` bundle under the given mnemonic.

    Args:
        ctx: Rule context of the calling bundle rule.
        platform: Apple platform (`"ios"` or `"macos"`).
        archive_ext: Bundle archive extension (e.g. `".app.zip"`).
        mnemonic: Action mnemonic for the bundle step.
        families: Device families for iOS bundles.
        native_libs: Native libraries embedded via `additional_contents`.

    Returns:
        The bundle action's providers (`DefaultInfo` with the archive, plus
        `OutputGroupInfo`).
    """
    _fail_on_xtool_unsupported_attrs(ctx)
    ib_errors = _collect_xtool_ib_errors(ctx)
    additional_content_pairs, additional_content_files = _collect_xtool_additional_contents(ctx, ib_errors)

    if ib_errors:
        fail("\n".join(ib_errors))

    sdk_available, sdk_transitive = _xtool_sdk_availability(ctx)

    if ctx.attr.require_sdk and not sdk_available:
        fail(UNCONFIGURED_SDK_ERROR)

    app_name = ctx.attr.app_name if ctx.attr.app_name else ctx.label.name
    archive_file = ctx.actions.declare_file("%s%s" % (ctx.label.name, archive_ext))
    app_dir = ctx.actions.declare_directory("%s_bundle/%s.app" % (ctx.label.name, app_name))

    infoplists = ctx.files.infoplists
    resources = ctx.files.resources

    frameworks = collect_framework_args_and_inputs(
        ctx.attr.frameworks,
        ctx.attr.plugins + ctx.attr.deps,
    )

    arch = xtool_target_arch(ctx)

    executable_file = ctx.file.executable
    if not executable_file:
        executable_file = _compile_xtool_runner(
            ctx,
            platform,
            app_name,
            arch,
            sdk_available,
            frameworks,
            sdk_transitive,
        )

    args = _xtool_bundle_base_args(ctx, platform, app_name, executable_file, archive_file, app_dir)

    direct_inputs = (
        [executable_file] +
        infoplists +
        resources +
        native_libs +
        additional_content_files
    )

    if ctx.attr.version:
        _add_xtool_version_args(ctx, args, direct_inputs)

    _add_xtool_bundle_content_args(
        ctx,
        args,
        families,
        frameworks.bundle.dirs,
        native_libs,
        resources,
        additional_content_pairs,
        infoplists,
    )

    _add_xtool_signing_args(ctx, args, direct_inputs)

    action_env = _add_xtool_env_args(ctx, args, archive_file)

    ctx.actions.run(
        executable = ctx.executable._xtool_pack,
        arguments = [args],
        env = action_env,
        use_default_shell_env = False,
        inputs = depset(
            direct = direct_inputs,
            transitive = frameworks.bundle.transitive_inputs,
        ),
        outputs = [archive_file, app_dir],
        mnemonic = mnemonic,
        progress_message = "Packaging %s (%s) via xtool_pack" % (ctx.label, platform),
        toolchain = None,
    )

    return _xtool_bundle_providers(ctx, archive_file, app_dir, executable_file)
