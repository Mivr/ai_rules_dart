"""Host-agnostic bundle versioning for the `xtool` backend (private implementation).

Holds `flutter_xtool_bundle_version` — the host-agnostic replacement for
`apple_bundle_version` — with `resolve_xtool_version`, which mirrors a
same-package `apple_bundle_version` into one without resolving Apple
toolchains. `flutter/private/flutter_xtool_bundle.bzl` loads the rule back and
re-exports it, so existing users are unaffected.

Usage: see flutter/private/flutter_xtool_bundle.bzl for public API.
"""

visibility(["//flutter/..."])

FlutterXtoolVersionInfo = provider(
    doc = "Carries host-agnostic bundle version metadata for the xtool backend.",
    fields = {
        "build_version": "Resolved or pattern string for CFBundleVersion.",
        "short_version_string": "Resolved or pattern string for CFBundleShortVersionString.",
        "version_file": "JSON File containing `build_version` and `short_version_string`.",
    },
)

def _collect_version_group_names(s):
    names = []
    length = len(s)
    end_index = 0
    for i in range(length):
        if i < end_index:
            continue
        if s[i] == "{":
            end_index = s.find("}", i + 1)
            if end_index != -1:
                names.append(s[i + 1:end_index])
    return names

def bundle_version_progress_message(label):
    """The progress message for the `FlutterXtoolBundleVersion` action.

    Args:
        label: The label of the `flutter_xtool_bundle_version` target.

    Returns:
        The message naming the target whose bundle version is resolved.
    """
    return "Resolving bundle version for %s" % label

def _flutter_xtool_bundle_version_impl(ctx):
    build_label_pattern = ctx.attr.build_label_pattern
    capture_groups = ctx.attr.capture_groups
    fallback_build_label = ctx.attr.fallback_build_label

    if (build_label_pattern and not capture_groups) or (not build_label_pattern and capture_groups):
        fail(
            "%s: in 'version' target, if either build_label_pattern or capture_groups is provided, then both must be provided." % ctx.label,
        )
    if fallback_build_label and not build_label_pattern:
        fail(
            "%s: in 'version' target, if fallback_build_label is provided, then build_label_pattern and capture_groups must be provided." % ctx.label,
        )

    short_version_string = ctx.attr.short_version_string or ctx.attr.build_version
    patterns = {
        "build_version": ctx.attr.build_version,
        "short_version_string": short_version_string,
    }
    if build_label_pattern:
        patterns["build_label_pattern"] = build_label_pattern

    group_keys = (capture_groups or {}).keys()
    for attr_name, pattern in patterns.items():
        missing = [g for g in _collect_version_group_names(pattern) if g not in group_keys]
        if missing:
            fail(
                "%s: in 'version' target attribute %r, placeholder group(s) [%s] were not defined in capture_groups." % (
                    ctx.label,
                    attr_name,
                    ", ".join(sorted(missing)),
                ),
            )

    bundle_version_file = ctx.actions.declare_file(ctx.label.name + ".bundle_version")
    if build_label_pattern:
        control_file = ctx.actions.declare_file(ctx.label.name + ".versiontool-control")
        control = {
            "build_info_path": ctx.info_file.path,
            "build_label_pattern": build_label_pattern,
            "build_version_pattern": ctx.attr.build_version,
            "capture_groups": capture_groups,
            "short_version_string_pattern": short_version_string,
        }
        if fallback_build_label:
            control["fallback_build_label"] = fallback_build_label
        ctx.actions.write(
            output = control_file,
            content = json.encode(control),
        )
        ctx.actions.run(
            executable = ctx.executable._xtool_pack,
            arguments = [
                "resolve-version",
                "--control",
                control_file.path,
                "--output",
                bundle_version_file.path,
            ],
            env = {"TMPDIR": bundle_version_file.dirname},
            use_default_shell_env = False,
            inputs = [control_file, ctx.info_file],
            outputs = [bundle_version_file],
            mnemonic = "FlutterXtoolBundleVersion",
            toolchain = None,
            progress_message = bundle_version_progress_message(ctx.label),
        )
    else:
        ctx.actions.write(
            output = bundle_version_file,
            content = json.encode({
                "build_version": ctx.attr.build_version,
                "short_version_string": short_version_string,
            }) + "\n",
        )

    return [
        FlutterXtoolVersionInfo(
            version_file = bundle_version_file,
            build_version = ctx.attr.build_version if not build_label_pattern else "",
            short_version_string = short_version_string if not build_label_pattern else "",
        ),
        DefaultInfo(files = depset([bundle_version_file])),
    ]

flutter_xtool_bundle_version = rule(
    implementation = _flutter_xtool_bundle_version_impl,
    attrs = {
        "build_label_pattern": attr.string(
            default = "",
            doc = "Stamped build-label pattern with `{placeholder}` groups resolved via `capture_groups`. When empty, `build_version` is used literally.",
        ),
        "build_version": attr.string(
            mandatory = True,
            doc = "Explicit `CFBundleVersion` (`FLUTTER_BUILD_NUMBER`); may carry `{placeholder}` groups when `build_label_pattern` is set.",
        ),
        "capture_groups": attr.string_dict(
            default = {},
            doc = "Maps `build_label_pattern` placeholder names to regex capture-group names in the stamped build label.",
        ),
        "fallback_build_label": attr.string(
            default = "",
            doc = "Build label parsed when the stamped label is unavailable; requires `build_label_pattern` and `capture_groups`.",
        ),
        "short_version_string": attr.string(
            default = "",
            doc = "Optional explicit `CFBundleShortVersionString` (`FLUTTER_BUILD_NAME`); defaults to `build_version`.",
        ),
        "_xtool_pack": attr.label(
            default = Label("//flutter/private/tools:xtool_pack"),
            executable = True,
            cfg = "exec",
            doc = "The `xtool_pack` host tool resolving stamped versions.",
        ),
    },
    provides = [FlutterXtoolVersionInfo, DefaultInfo],
    doc = "Host-agnostic replacement for `apple_bundle_version` on the `xtool` backend.",
)

def _xtool_version_name(version, pkg):
    """The same-package target name behind a `version` label, or None when cross-package."""
    ver_name = None
    if version.startswith(":"):
        ver_name = version[1:]
    elif "/" not in version and ":" not in version:
        ver_name = version
    elif version.startswith("//" + pkg + ":"):
        ver_name = version.split(":", 1)[1]
    return ver_name

def _mirror_xtool_bundle_version(name, existing, internal_tags):
    """Mirror an `apple_bundle_version` rule's attributes into a host-agnostic helper target.

    Returns the `(version_label, build_version, short_version)` triple.
    """
    bv = existing.get("build_version") or ""
    sv = existing.get("short_version_string") or ""
    blp = existing.get("build_label_pattern") or ""
    cg = existing.get("capture_groups") or {}
    fbl = existing.get("fallback_build_label") or ""
    helper_name = "__%s_xtool_version" % name
    flutter_xtool_bundle_version(
        name = helper_name,
        build_version = bv,
        short_version_string = sv,
        build_label_pattern = blp,
        capture_groups = cg,
        fallback_build_label = fbl,
        tags = internal_tags,
        visibility = ["//visibility:private"],
    )
    return ":" + helper_name, (bv if not blp else ""), ((sv or bv) if not blp else "")

def _resolve_xtool_same_package(name, macro_name, ver_name, version, pkg, internal_tags):
    """Resolve a same-package `version` label without triggering Apple toolchains."""
    existing = native.existing_rule(ver_name)
    if existing != None:
        kind = existing.get("kind", "")
        if kind == "apple_bundle_version" or "build_version" in existing or "short_version_string" in existing:
            label, bv, sv = _mirror_xtool_bundle_version(name, existing, internal_tags)
            return label, bv, sv, ""
        if kind in ("flutter_xtool_bundle_version", "write_file", "_write_file", "genrule", "filegroup"):
            return version, "", "", ""
        return None, "", "", "%s(name = %r): 'version' target %r (rule kind %r) is not supported on the xtool backend; pass an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON version file." % (
            macro_name,
            name,
            version,
            kind,
        )

    if native.glob([ver_name], allow_empty = True):
        return version, "", "", ""
    return None, "", "", "%s(name = %r): 'version' target %r does not exist in package '//%s'; pass an 'apple_bundle_version' target or a JSON version file." % (
        macro_name,
        name,
        version,
        pkg,
    )

def resolve_xtool_version(name, macro_name, version, internal_tags):
    """Resolves a `version` attribute for `backend = 'xtool'` without triggering Apple toolchains.

    Inspects same-package `apple_bundle_version` targets via `native.existing_rule`
    and mirrors their attributes into a host-agnostic `flutter_xtool_bundle_version`
    target so Bazel never resolves `@rules_apple` macOS toolchains on Linux.

    Args:
        name: Application target name.
        macro_name: Calling macro name (`"flutter_ios_app"` or `"flutter_macos_app"`).
        version: The `version` argument passed to the macro.
        internal_tags: Tags to apply to any synthesized helper target.

    Returns:
        A 4-tuple `(version_label, build_version, short_version, invalid_version_error)`.
    """
    if version == None:
        return None, "", "", ""
    if type(version) != "string":
        return None, "", "", "%s(name = %r): 'version' (%r) is not supported on the xtool backend; expected an 'apple_bundle_version' target or JSON version file label." % (
            macro_name,
            name,
            version,
        )

    pkg = native.package_name()
    ver_name = _xtool_version_name(version, pkg)

    if ver_name != None:
        return _resolve_xtool_same_package(name, macro_name, ver_name, version, pkg, internal_tags)

    return None, "", "", "%s(name = %r): cross-package 'version' target %r is not supported on the xtool backend because 'apple_bundle_version' requires a macOS toolchain unless declared in the same package; declare 'apple_bundle_version' in '//%s' or pass `build_version` / `short_version`." % (
        macro_name,
        name,
        version,
        pkg,
    )
