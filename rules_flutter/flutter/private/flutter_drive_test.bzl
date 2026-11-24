"""`flutter_drive_test`: a host-run driver against an app on the Android emulator or iOS simulator.

Launches a debug app on the pinned headless Android emulator or an iOS simulator
the way `flutter_integration_test` does, runs `driver` on the host with the
app's Dart VM service URI in its environment, and exits with the driver's exit
status. Host Dart and driver packages come from the hermetic toolchain and the
pinned pub lock; no host Flutter or Dart is read, and no download is added.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "STABLE_SCHEME",
    "collect_packages",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "dart_analyzable_info",
    "generate_stable_package_config",
    "runfiles_path",
    "stable_entry_path",
)
load("//flutter:providers.bzl", "resolve_exec_dart_vm")
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT", "LAYERING_CHECK_ATTRS", "layering_check_drive")
load("//flutter/private/android_model:rules.bzl", "RdfApkInfo")

visibility(["//flutter/..."])

# The emulator needs the host (`/dev/kvm`, and loopback ports shared with its
# adb server), so this test runs unsandboxed exactly as
# `flutter_integration_test(platform = "android")` does. Kept here rather than
# imported: that file loads `//flutter:android.bzl`, which loads this one.
_DRIVE_TEST_EXECUTION_REQUIREMENTS = {"no-sandbox": ""}

_EXEC_TOOLS_TOOLCHAIN = "@rules_dart//dart:exec_tools_toolchain_type"

def _drive_ipa(ctx):
    """Resolves the simulator `.ipa` of an iOS `app` target, or `None`.

    Args:
        ctx: The rule context under analysis.

    Returns:
        The `.ipa` `File` of `ctx.attr.app`, or `None` when it has none.
    """

    # lint-allow: depset-flatten the app target's own outputs
    ipas = [f for f in ctx.attr.app[DefaultInfo].files.to_list() if f.path.endswith(".ipa")]
    return ipas[0] if ipas else None

def _drive_device(ctx, workspace_name):
    """Picks the device kind of `app` and returns its launcher inputs.

    Args:
        ctx: The rule context under analysis.
        workspace_name: The workspace name used to form runfiles paths.

    Returns:
        A struct with `env` (launcher variables), `files` and `transitive`
        runfiles inputs.
    """
    if not ctx.attr.app:
        fail("%s: attribute `app` is required: pass the `<name>_apk` of a `flutter_android_app` or an iOS simulator app target." % ctx.label)
    if RdfApkInfo in ctx.attr.app and ctx.file._android_emulator != None:
        # The whole APK of an app built from the pinned Gradle model (`<name>_apk`), which names
        # its own application id.
        apk = ctx.attr.app[RdfApkInfo].apk
        return struct(
            env = {
                "FLUTTER_DRIVE_ANDROID_ADB": runfiles_path(ctx.file._android_adb, workspace_name),
                "FLUTTER_DRIVE_ANDROID_APK": runfiles_path(apk, workspace_name),
                "FLUTTER_DRIVE_ANDROID_EMULATOR": runfiles_path(ctx.file._android_emulator, workspace_name),
                "FLUTTER_DRIVE_ANDROID_PACKAGE": ctx.attr.package_name or ctx.attr.app[RdfApkInfo].application_id,
            },
            files = [apk, ctx.file._android_emulator, ctx.file._android_adb],
            transitive = ctx.files._android_runtime_all_files,
        )
    ipa = _drive_ipa(ctx)
    if ipa == None:
        fail((
            "%s: attribute `app` (%s) is neither an Android app (the `<name>_apk` of a `flutter_android_app`) nor an " +
            "iOS simulator app (an `.ipa` from `ios_sim_debug_app`)."
        ) % (ctx.label, ctx.attr.app.label))
    bundle_id = ctx.attr.bundle_id or ctx.attr.package_name
    ios_env = {"FLUTTER_DRIVE_IOS_APP": runfiles_path(ipa, workspace_name)}
    if bundle_id:
        ios_env["FLUTTER_DRIVE_IOS_BUNDLE_ID"] = bundle_id
    return struct(
        env = ios_env,
        files = [ipa],
        transitive = [],
    )

def _exec_kernel_tools(ctx):
    """Resolves the hermetic Dart VM and kernel compiler from the exec toolchain.

    Args:
        ctx: The rule context declaring `@rules_dart//dart:exec_tools_toolchain_type`.

    Returns:
        A struct holding `dart`, `runtime_files`, `compile_files`,
        `dartaotruntime`, `gen_kernel` and `platform_dill`.
    """
    dart_exe, runtime_files = resolve_exec_dart_vm(ctx)
    sdk = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].dart_sdk_info
    dartaotruntime = None
    gen_kernel = None
    platform_dill = None

    # lint-allow: depset-flatten the SDK's own compile files
    for f in sdk.compile_files.to_list():
        if f.basename in ("dartaotruntime", "dartaotruntime.exe"):
            dartaotruntime = f
        elif f.basename == "gen_kernel_aot.dart.snapshot":
            gen_kernel = f
        elif f.basename == "vm_platform_strong.dill":
            platform_dill = f
    if not dartaotruntime or not gen_kernel or not platform_dill:
        fail("%s: Dart exec toolchain is missing kernel compiler files." % ctx.label)
    return struct(
        dart = dart_exe,
        runtime_files = runtime_files,
        compile_files = sdk.compile_files,
        dartaotruntime = dartaotruntime,
        gen_kernel = gen_kernel,
        platform_dill = platform_dill,
    )

def _compile_driver_dill(ctx, driver_src):
    """Compiles a `.dart` host driver script to a `.dill` kernel with the exec SDK.

    Args:
        ctx: The rule context under analysis.
        driver_src: The `.dart` entrypoint `File` passed to `driver`.

    Returns:
        A struct with `dill`, `dart`, `runtime_files` and `analyzable`.
    """
    tools = _exec_kernel_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    dep_srcs = collect_transitive_srcs(ctx.attr.deps)
    own_srcs = [driver_src] + ctx.files.srcs
    pkg_cfg = ctx.actions.declare_file(ctx.label.name + "_driver.package_config.json")
    ctx.actions.write(
        output = pkg_cfg,
        # lint-allow: depset-flatten terminal: the driver's whole-program package config, once
        content = generate_stable_package_config(packages, own_srcs + dep_srcs.to_list()),
    )
    dill = ctx.actions.declare_file(ctx.label.name + "_driver.dill")
    args = ctx.actions.args()
    args.add(tools.gen_kernel)
    args.add("--platform", tools.platform_dill)
    args.add("--packages", pkg_cfg)
    args.add("--filesystem-scheme", STABLE_SCHEME)
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("-Ddart.vm.product=false")
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    args.add("-o", dill)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, driver_src.path))
    action_env = (
        {
            "LOCALAPPDATA": dill.dirname,
            "TEMP": dill.dirname,
            "TMP": dill.dirname,
            "USERPROFILE": dill.dirname,
        } if tools.dart.basename.endswith(".exe") else {"HOME": dill.dirname, "TMPDIR": dill.dirname}
    )
    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = own_srcs + [pkg_cfg, tools.dartaotruntime, tools.gen_kernel, tools.platform_dill],
            transitive = [dep_srcs, tools.compile_files],
        ),
        outputs = [dill],
        mnemonic = "FlutterDriveKernel",
        progress_message = "Compiling host driver %s" % ctx.label,
        env = action_env,
        toolchain = _EXEC_TOOLS_TOOLCHAIN,
    )
    return struct(
        dill = dill,
        dart = tools.dart,
        runtime_files = tools.runtime_files,
        analyzable = [dart_analyzable_info(deps = ctx.attr.deps, srcs = own_srcs)],
    )

def _resolve_driver(ctx, workspace_name):
    """Resolves `driver` as either a prebuilt executable or a compiled `.dart` script.

    Args:
        ctx: The rule context under analysis.
        workspace_name: The workspace name used to form runfiles paths.

    Returns:
        A struct with `env`, `files`, `transitive`, `runfiles` and `providers`.
    """
    if not ctx.attr.driver:
        fail("%s: attribute `driver` is required: pass a `.dart` script or a `dart_binary` target." % ctx.label)
    exe = ctx.attr.driver[DefaultInfo].files_to_run.executable
    if (
        len(ctx.files.driver) == 1 and
        ctx.files.driver[0].path.endswith(".dart") and
        (exe == None or exe.path.endswith(".dart"))
    ):
        driver_src = ctx.files.driver[0]
        compiled = _compile_driver_dill(ctx, driver_src)
        return struct(
            env = {
                "FLUTTER_DRIVE_DART": runfiles_path(compiled.dart, workspace_name),
                "FLUTTER_DRIVE_DRIVER": runfiles_path(compiled.dill, workspace_name),
            },
            files = [driver_src, compiled.dill, compiled.dart] + ctx.files.srcs,
            transitive = [compiled.runtime_files, collect_transitive_resources(ctx.attr.deps)],
            runfiles = [],
            providers = compiled.analyzable,
            validation = layering_check_drive(ctx, driver_src),
        )
    if exe != None and not exe.is_source:
        if ctx.attr.deps or ctx.files.srcs:
            fail(
                "%s: `deps` and `srcs` apply only when `driver` is a `.dart` file; declare them on %s." % (
                    ctx.label,
                    ctx.attr.driver.label,
                ),
            )
        return struct(
            env = {"FLUTTER_DRIVE_DRIVER": runfiles_path(exe, workspace_name)},
            files = [exe],
            transitive = [],
            runfiles = [ctx.attr.driver[DefaultInfo].default_runfiles],
            providers = [],
            validation = depset(),
        )
    fail(
        "%s: attribute `driver` (%s) must be a single `.dart` script or an executable target." % (
            ctx.label,
            ctx.attr.driver.label,
        ),
    )

def _merged_test_env(ctx, base_env):
    """Merges caller `env` entries with `base_env`, rejecting reserved launcher keys.

    Args:
        ctx: The rule context under analysis.
        base_env: Dict of launcher environment variables set by the rule.

    Returns:
        A merged dict of environment variables for `testing.TestEnvironment`.
    """
    merged = {}
    for key, value in ctx.attr.env.items():
        if key in base_env or key == "VM_SERVICE_URL" or key.startswith("FLUTTER_DRIVE_"):
            fail("%s: `env` key `%s` is reserved by `flutter_drive_test`." % (ctx.label, key))
        merged[key] = ctx.expand_location(value, ctx.attr.data)
    merged.update(base_env)
    return merged

def _flutter_drive_test_impl(ctx):
    """Declares the launcher executable, compiles `.dart` drivers and wires runfiles.

    Args:
        ctx: The rule context under analysis.

    Returns:
        The list of providers for the test target.
    """
    workspace_name = ctx.workspace_name
    device = _drive_device(ctx, workspace_name)
    resolved = _resolve_driver(ctx, workspace_name)
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = executable, target_file = ctx.executable._tool, is_executable = True)
    base_env = dict(device.env)
    base_env.update(resolved.env)
    runfiles = ctx.runfiles(
        files = device.files + resolved.files + ctx.files.data,
        transitive_files = depset(device.transitive, transitive = resolved.transitive),
    )
    extra_runfiles = [ctx.attr._tool[DefaultInfo].default_runfiles] + resolved.runfiles + [
        d[DefaultInfo].default_runfiles
        for d in ctx.attr.data
    ]
    runfiles = runfiles.merge_all(extra_runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment(_merged_test_env(ctx, base_env)),
        testing.ExecutionInfo(_DRIVE_TEST_EXECUTION_REQUIREMENTS),
        OutputGroupInfo(_validation = resolved.validation),
    ] + resolved.providers

def _default_android_emulator(ios):
    """Returns the pinned Android `emulator` label, or `None` when `ios` is `True`.

    Args:
        ios: Whether `app` was classified as an iOS simulator target.

    Returns:
        `Label` of the pinned `emulator` binary, or `None`.
    """
    return None if ios else Label("@flutter_android_headless_runtime//:sdk/emulator/emulator")

def _default_android_adb(ios):
    """Returns the pinned `adb` label, or `None` when `ios` is `True`.

    Args:
        ios: Whether `app` was classified as an iOS simulator target.

    Returns:
        `Label` of the pinned `adb` binary, or `None`.
    """
    return None if ios else Label("@flutter_android_headless_runtime//:sdk/platform-tools/adb")

def _default_android_runtime(ios):
    """Returns the pinned Android runtime files label, or `None` when `ios` is `True`.

    Args:
        ios: Whether `app` was classified as an iOS simulator target.

    Returns:
        `Label` of `@flutter_android_headless_runtime//:all_files`, or `None`.
    """
    return None if ios else Label("@flutter_android_headless_runtime//:all_files")

_flutter_drive_test = rule(
    implementation = _flutter_drive_test_impl,
    attrs = {
        "app": attr.label(
            allow_files = True,
            doc = "Required app target under test: an Android app (the `<name>_apk` of a debug `flutter_android_app` of the pin) or " +
                  "an iOS simulator app (`.ipa` from `ios_sim_debug_app`); fails analysis when invalid.",
        ),
        "bundle_id": attr.string(
            doc = "Bundle identifier of an iOS simulator `app`; defaults to the app's bundle id or `package_name`.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional runtime files staged into the host driver's runfiles; defaults to `[]`.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            aspects = [LAYERING_CHECK_ASPECT],
            doc = "Dart library dependencies (from the pinned pub lock) when `driver` is a `.dart` script.",
        ),
        "driver": attr.label(
            allow_files = True,
            cfg = "exec",
            doc = "Required host driver: a `.dart` script or an executable target (`dart_binary`) reading " +
                  "`VM_SERVICE_URL`; fails analysis when omitted.",
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables passed to the test (`$(rlocationpath ...)` expanded over `data`).",
        ),
        "ios": attr.bool(
            doc = "Internal flag set by the macro when `app` is an iOS simulator target; defaults to `False`.",
        ),
        "package_name": attr.string(
            doc = "Android application ID of `app` (for example `com.example.myapp`); required on Android.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Extra `.dart` helper sources imported by a `.dart` script `driver`; defaults to `[]`.",
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:flutter_drive_runner"),
            executable = True,
            cfg = "exec",
            doc = "Launcher binary (`//flutter/private/tools:flutter_drive_runner`) for emulator or simulator.",
        ),
        "_android_emulator": attr.label(
            default = _default_android_emulator,
            allow_single_file = True,
            doc = "Pinned Android `emulator` binary (`None` on iOS); defaults to the headless Android runtime.",
        ),
        "_android_adb": attr.label(
            default = _default_android_adb,
            allow_single_file = True,
            doc = "Pinned `adb` binary (`None` on iOS); defaults to the headless Android runtime `adb` label.",
        ),
        "_android_runtime_all_files": attr.label(
            default = _default_android_runtime,
            doc = "All files of the pinned headless Android runtime (`None` on iOS); defaults to `:all_files`.",
        ),
    } | LAYERING_CHECK_ATTRS,
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
    test = True,
    doc = "Runs a host Dart driver against a debug app on the Android emulator or the iOS simulator.",
)

_NON_IOS_WORDS = (
    "android apk bad error invalid linux macos neither no non nor not unknown web windows wrong"
).split(" ")
_NON_STUB_PREFIXES = "flutter_ android_ apple_ cc_ dart_ java_ kt_ objc_ proto_ py_ sh_ swift_".split(" ")
_NON_STUB_KINDS = (
    "copy_file expand_template filegroup genrule ios_build_test ios_extension ios_framework " +
    "ios_imessage_application ios_imessage_extension ios_static_framework " +
    "ios_sticker_pack_extension ios_ui_test ios_unit_test write_file"
).split(" ")

def _local_target_name(target):
    """Returns the local target name when `target` belongs to the current package.

    Args:
        target: A label string, `Label` or `select` expression.

    Returns:
        The unqualified target name in `native.package_name()`, or `None`.
    """
    if not target or type(target) not in ("string", "Label"):
        return None
    if type(target) == "string":
        if target.startswith(":"):
            return target[1:] if len(target) > 1 else None
        if not target.startswith("@") and not target.startswith("//") and "/" not in target:
            return target
    here = native.package_relative_label(":_")
    lbl = native.package_relative_label(target)
    return lbl.name if (lbl.repo_name == here.repo_name and lbl.package == here.package) else None

def _resolve_local_rule(target):
    """Follows local `alias` hops to `(local_name, rule_dict)` in this package.

    Args:
        target: A label string, `Label` or `select` expression.

    Returns:
        A `(local_name, rule_dict)` pair; `rule_dict` is `None` when not a local rule.
    """
    current = target
    for _ in range(4):
        local = _local_target_name(current)
        if not local:
            return None, None
        rule_dict = native.existing_rule(local)
        if rule_dict == None or rule_dict.get("kind") != "alias":
            return local, rule_dict
        actual = rule_dict.get("actual")
        if type(actual) not in ("string", "Label"):
            return local, rule_dict
        current = actual
    return None, None

def _has_ios_words(raw):
    """Checks whether `raw` names an iOS simulator or `.ipa` kind without non-iOS tokens.

    Args:
        raw: Rule kind or cross-package target name string to tokenize.

    Returns:
        `True` when `raw` carries an iOS/simulator/ipa token and no disqualifying token.
    """
    parts = [p for p in raw.lower().replace("-", "_").replace(".", "_").split("_") if p]
    if [b for b in _NON_IOS_WORDS if b in parts]:
        return False
    return bool([g for g in ("ipa", "ios", "sim", "simulator") if g in parts])

def _is_ios_stub_rule(kind):
    """Returns `True` when `kind` is a custom Starlark stub rule for an iOS simulator app.

    Args:
        kind: The `kind` string from `native.existing_rule`.

    Returns:
        `True` when the custom rule kind represents an iOS simulator test fixture.
    """
    stripped = kind.lstrip("_")
    if not stripped or stripped in _NON_STUB_KINDS or [p for p in _NON_STUB_PREFIXES if stripped.startswith(p)]:
        return False
    return _has_ios_words(stripped)

def _rule_has_ipa_output(rule_dict):
    """Returns `True` when `rule_dict` declares a `.ipa` output or source attribute.

    Args:
        rule_dict: Rule attribute dict returned by `native.existing_rule`.

    Returns:
        `True` if any non-metadata attribute references a `.ipa` file.
    """
    for key, val in rule_dict.items():
        if key in ("name", "kind", "tags", "visibility"):
            continue
        if key in ("ipa", "is_ipa") and val == True:
            return True
        items = val if type(val) in ("list", "tuple") else [val]
        if [x for x in items if type(x) in ("string", "Label") and str(x).endswith(".ipa")]:
            return True
    return False

def _unwrap_local_app(app):
    """Unwraps local `debug_build` and single-source `filegroup` wrappers on `app`.

    Args:
        app: The `app` value passed to `flutter_drive_test`.

    Returns:
        A `(target, local, rule_dict)` tuple after unwrapping at most two wrapper rules.
    """
    current = app
    for _ in range(3):
        if not current or type(current) not in ("string", "Label"):
            return None, None, None
        if str(current).endswith(".ipa"):
            return current, None, None
        local, rule_dict = _resolve_local_rule(current)
        if rule_dict == None:
            return current, local, None
        kind = rule_dict.get("kind", "")
        if kind == "debug_build" or (kind == "filegroup" and len(rule_dict.get("srcs") or []) == 1):
            wrapped = rule_dict.get("targets") or rule_dict.get("srcs") or []
            if type(wrapped) in ("list", "tuple") and wrapped:
                current = wrapped[0]
                continue
        return current, local, rule_dict
    return None, None, None

def _inspect_ios_app(app, bundle_id):
    """Classifies whether `app` is an iOS simulator app and resolves any `bundle_id`.

    Args:
        app: The `app` value passed to `flutter_drive_test`.
        bundle_id: Explicit `bundle_id` passed by the caller, if any.

    Returns:
        An `(is_ios, resolved_bundle_id)` tuple.
    """
    target, local, rule_dict = _unwrap_local_app(app)
    if target == None:
        return False, bundle_id
    if str(target).endswith(".ipa"):
        return True, bundle_id
    if local == None:
        return bool(bundle_id) or _has_ios_words(native.package_relative_label(target).name), bundle_id
    if rule_dict == None:
        return local.endswith(".ipa"), bundle_id
    kind = rule_dict.get("kind", "")
    if kind == "ios_sim_debug_app":
        _, inner = _resolve_local_rule(rule_dict.get("app"))
        inner_id = inner.get("bundle_id") if inner and type(inner.get("bundle_id")) == "string" else ""
        return True, bundle_id or inner_id
    if kind.lstrip("_") in ("ios_application", "flutter_xtool_ios_bundle"):
        own_id = rule_dict.get("bundle_id")
        return True, bundle_id or (own_id if type(own_id) == "string" else "")
    if _rule_has_ipa_output(rule_dict):
        return True, bundle_id
    return _is_ios_stub_rule(kind), bundle_id

def _with_macos_compat(existing):
    """Ensures `@platforms//os:macos` is present in `target_compatible_with`.

    Args:
        existing: Existing `target_compatible_with` value (`None`, `list` or `select`).

    Returns:
        A list or `select` expression requiring `@platforms//os:macos`.
    """
    macos = "@platforms//os:macos"
    if existing == None:
        return [macos]
    if type(existing) == "list" and [c for c in existing if str(c).endswith(("//os:macos", ":macos"))]:
        return existing
    return existing + [macos]

def flutter_drive_test(
        name,
        app = None,
        driver = None,
        package_name = "",
        deps = [],
        size = None,
        tags = [],
        **kwargs):
    """Runs a host-side Dart driver against an app on the Android emulator or iOS simulator.

    Args:
        name: Unique name for this test target.
        app: The Android app (`<name>_apk` of a debug `flutter_android_app` of the pin's `defs.bzl`) or the
            iOS simulator app (`ios_sim_debug_app`).
        driver: Host Dart driver — a `.dart` script (compiled with `deps`) or a `dart_binary`.
        package_name: iOS bundle id fallback when `bundle_id` is unset. An Android app names its own
            application id; set this only to override it.
        deps: Dart package dependencies from the pinned pub lock when `driver` is a `.dart` file.
        size: Test size; `large` for Android and `enormous` for iOS by default.
        tags: Extra Bazel tags; `manual` is always added (`exclusive` too on iOS).
        **kwargs: Additional test attributes (`srcs`, `data`, `env`, `bundle_id`, `timeout`, `visibility`, ...).
    """
    kwargs.pop("ios", None)
    ios, resolved_bundle_id = _inspect_ios_app(app, kwargs.get("bundle_id", ""))
    user_tags = list(tags or [])
    required_tags = ["manual", "exclusive"] if ios else ["manual"]
    all_tags = user_tags + [t for t in required_tags if t not in user_tags]
    if ios:
        kwargs["target_compatible_with"] = _with_macos_compat(kwargs.get("target_compatible_with"))
        if size == None:
            kwargs.setdefault("timeout", "eternal")
        if resolved_bundle_id and not kwargs.get("bundle_id"):
            kwargs["bundle_id"] = resolved_bundle_id
    _flutter_drive_test(
        name = name,
        app = app,
        driver = driver,
        package_name = package_name,
        deps = deps,
        ios = ios,
        size = size or ("enormous" if ios else "large"),
        tags = all_tags,
        **kwargs
    )
