"""Prebuilt tools: a release's AOT snapshots of rules_flutter's own tools.

The rules_flutter side of `@rules_dart//dart/private:prebuilt_tools.bzl`,
which says how a release builds, checks and ships them. A Flutter release's
set, per host platform, is the module compiler of the Dart SDK the release
bundles, rules_dart's AOT snapshot tools (`SNAPSHOT_TOOLS`: the compile
wrapper, the layering check and the kernel linker) built by that SDK, the
asset tool (`flutter_assets_tool.bzl`) and the Android bundle tool. The
released module's `//flutter/private:prebuilt_tools.json` is keyed by the
Flutter version:

    {"tools": {"<flutter version>": {"<platform>": {"url": ..., "sha256": ...}}}}

with rules_dart's platform keys (`macos-arm64`, not `darwin-arm64`). The
table in the repository is empty, and `--repo_env=RULES_DART_TOOLS=source`
turns it off as it does rules_dart's.

An engine repository of a listed version and host takes the archive's module
compiler and asset tool instead of building them (the asset tool still reads
the framework's shaders and service worker from the release's sources), and
its Dart toolchain carries the archive's snapshot tools, so a Flutter
workspace builds none of them whatever Dart its Flutter bundles. The
Android bundle tool, a self-contained `exe`, is
`@rules_flutter_tools//:android_bundle`, an alias that selects the archive of
the exec platform.
"""

load("@rules_dart//dart:prebuilt_tools.bzl", "SNAPSHOT_TOOLS", "prebuilt_tools_table")
load("@rules_dart//dart:providers.bzl", "DartCompileInfo")
load("//flutter/private:download.bzl", "pinned_download_and_extract")
load("//flutter/private:toolchains_repo.bzl", "HOST_PLATFORMS")

visibility(["//flutter/..."])

# The `dart_binary` tools of the set, by target name under
# `//flutter/private/tools`, with the form they compile to.
FLUTTER_PREBUILT_TOOLS = {
    "android_bundle": "exe",
}

_TABLE = Label("//flutter/private:prebuilt_tools.json")
_HUB = "rules_flutter_tools"
_FLUTTER_TOOLCHAIN = Label("//flutter:toolchain_type")

def table_platform(host_platform):
    """rules_dart's key (`macos-arm64`) of a Flutter host platform (`darwin-arm64`).

    Args:
      host_platform: A key of `HOST_PLATFORMS`.

    Returns:
      The table's platform key.
    """
    meta = HOST_PLATFORMS[host_platform]
    return "%s-%s" % (meta.os, meta.arch)

def _host_platform(table_key):
    for host, meta in HOST_PLATFORMS.items():
        if "%s-%s" % (meta.os, meta.arch) == table_key:
            return host
    return None

def _archive_repo_name(version, host_platform):
    return "%s_%s_%s" % (_HUB, version.replace(".", "_"), host_platform)

def _stage(ctx, src, outputs):
    out = ctx.actions.declare_file("%s/files/%s" % (ctx.label.name, src.basename))
    ctx.actions.symlink(output = out, target_file = src)
    outputs.append(out)
    return "files/" + src.basename

def _flutter_prebuilt_tool_set_impl(ctx):
    info = ctx.toolchains[_FLUTTER_TOOLCHAIN].flutter_sdk_info
    tool = info.assets_tool
    if tool == None or tool.snapshot == None:
        fail("%s: the Flutter %s toolchain has no asset tool to prebuild" % (ctx.label, info.version))
    if info.dart_module_compiler == None:
        fail("%s: the Dart SDK of Flutter %s has no module compiler to prebuild" % (ctx.label, info.version))
    outputs = []
    manifest = {
        "flutter_version": info.version,
        "dart_version": info.dart_sdk_version,
        "assets_tool": _stage(ctx, tool.snapshot, outputs),
        "module_compiler": _stage(ctx, info.dart_module_compiler, outputs),
        "tools": {},
    }
    for target in ctx.attr.tools:
        name = target.label.name
        compiled = target[DartCompileInfo]
        if FLUTTER_PREBUILT_TOOLS.get(name) != compiled.compile_mode:
            fail("%s: %s compiles to %s, the table says %s" % (ctx.label, target.label, compiled.compile_mode, FLUTTER_PREBUILT_TOOLS.get(name)))
        manifest["tools"][name] = {
            "compile_mode": compiled.compile_mode,
            "sdk_version": compiled.sdk_version,
            "file": _stage(ctx, target[DefaultInfo].files_to_run.executable, outputs),
        }
    for name, target in ctx.attr.dart_tools.items():
        compiled = target[DartCompileInfo]
        if name not in SNAPSHOT_TOOLS or compiled.compile_mode != "aot-snapshot":
            fail("%s: %s is not one of rules_dart's AOT snapshot tools %s" % (ctx.label, name, SNAPSHOT_TOOLS))
        if compiled.sdk_version != info.dart_sdk_version:
            fail("%s: %s was built by Dart %s, Flutter %s bundles Dart %s" % (ctx.label, name, compiled.sdk_version, info.version, info.dart_sdk_version))
        manifest["tools"][name] = {
            "compile_mode": compiled.compile_mode,
            "sdk_version": compiled.sdk_version,
            "file": _stage(ctx, target[DefaultInfo].files_to_run.executable, outputs),
        }
    missing = [n for n in FLUTTER_PREBUILT_TOOLS.keys() + SNAPSHOT_TOOLS if n not in manifest["tools"]]
    if missing:
        fail("%s: the set lacks %s" % (ctx.label, ", ".join(missing)))
    tools_json = ctx.actions.declare_file(ctx.label.name + "/tools.json")
    ctx.actions.write(tools_json, json.encode_indent(manifest) + "\n")
    return [DefaultInfo(files = depset([tools_json] + outputs))]

flutter_prebuilt_tool_set = rule(
    implementation = _flutter_prebuilt_tool_set_impl,
    doc = "What a release of rules_flutter prebuilds for one Flutter version on one platform: the bundled Dart SDK's module compiler, rules_dart's snapshot tools built by that SDK, the asset tool and `FLUTTER_PREBUILT_TOOLS`, in the exec configuration a consumer builds them in, with the archive's `tools.json`.",
    attrs = {
        "tools": attr.label_list(
            doc = "The source targets of `FLUTTER_PREBUILT_TOOLS`.",
            cfg = "exec",
            providers = [DartCompileInfo],
        ),
        "dart_tools": attr.string_keyed_label_dict(
            doc = "rules_dart's `SNAPSHOT_TOOLS` by name, to their source targets: a Flutter workspace's exec Dart toolchain is the bundled SDK, which builds them.",
            cfg = "exec",
            providers = [DartCompileInfo],
        ),
    },
    toolchains = [_FLUTTER_TOOLCHAIN],
)

def _archive_repo_impl(rctx):
    pinned_download_and_extract(rctx, url = rctx.attr.url, sha256 = rctx.attr.sha256)
    manifest = json.decode(rctx.read("tools.json"))
    if manifest.get("flutter_version") != rctx.attr.flutter_version:
        fail("%s: the archive %s holds tools of Flutter %s, the table lists it under %s" % (
            rctx.attr.name,
            rctx.attr.url,
            manifest.get("flutter_version"),
            rctx.attr.flutter_version,
        ))
    lines = [
        "# Generated by rules_flutter's prebuilt_tools.bzl.",
        "load(%r, \"prebuilt_dart_tool\")" % str(Label("@rules_dart//dart:prebuilt_tools.bzl")),
        "",
        "alias(name = \"module_compiler\", actual = %r, visibility = [\"//visibility:public\"])" % (":" + manifest["module_compiler"]),
        "alias(name = \"assets_tool\", actual = %r, visibility = [\"//visibility:public\"])" % (":" + manifest["assets_tool"]),
    ]
    modes = dict(FLUTTER_PREBUILT_TOOLS)
    modes.update({name: "aot-snapshot" for name in SNAPSHOT_TOOLS})
    for name, mode in sorted(modes.items()):
        tool = manifest["tools"].get(name)
        if tool == None or tool["compile_mode"] != mode:
            fail("%s: the archive %s has no %s %s" % (rctx.attr.name, rctx.attr.url, mode, name))
        lines.append("""
prebuilt_dart_tool(
    name = {name},
    src = {src},
    compile_mode = {mode},
    sdk_version = {version},
    visibility = ["//visibility:public"],
)""".format(name = repr(name), src = repr(tool["file"]), mode = repr(mode), version = repr(tool["sdk_version"])))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return rctx.repo_metadata(reproducible = True)

flutter_tools_archive_repo = repository_rule(
    implementation = _archive_repo_impl,
    doc = "One archive of a release's prebuilt Flutter tools: one Flutter version, one platform.",
    attrs = {
        "url": attr.string(mandatory = True, doc = "Where the release published the archive."),
        "sha256": attr.string(mandatory = True, doc = "The archive's checksum, from the table."),
        "flutter_version": attr.string(mandatory = True, doc = "The Flutter version the table lists the archive under."),
    },
)

def _hub_repo_impl(rctx):
    lines = ["# Generated by rules_flutter's prebuilt_tools.bzl: which tools the rules run."]
    for host in rctx.attr.platforms:
        lines.append("""
config_setting(
    name = "exec_{host}",
    constraint_values = {constraints},
)""".format(host = host, constraints = repr([str(Label(c)) for c in HOST_PLATFORMS[host].compatible_with])))
    for name in sorted(FLUTTER_PREBUILT_TOOLS):
        arms = {
            ":exec_" + host: "@%s//:%s" % (_archive_repo_name(rctx.attr.flutter_version, host), name)
            for host in rctx.attr.platforms
        }
        arms["//conditions:default"] = rctx.attr.sources[name]
        lines.append("""
alias(
    name = {name},
    actual = select({arms}),
    visibility = ["//visibility:public"],
)""".format(name = repr(name), arms = repr(arms)))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return rctx.repo_metadata(reproducible = True)

flutter_tools_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    doc = "The hub the rules name their tools through (`@rules_flutter_tools//:<tool>`).",
    attrs = {
        "flutter_version": attr.string(doc = "The Flutter version whose prebuilt tools the hub offers."),
        "platforms": attr.string_list(doc = "The host platforms (`HOST_PLATFORMS` keys) with an archive of that version."),
        "sources": attr.string_dict(mandatory = True, doc = "Tool name to the canonical label of its source target."),
    },
)

def flutter_prebuilt_tools(module_ctx, default_version):
    """Reads the table and declares the archive repositories and the hub.

    Args:
      module_ctx: The `flutter` module extension context.
      default_version: The Flutter version of the default toolchain; the hub
        offers that version's prebuilt tools.

    Returns:
      `{flutter version: {host platform: archive repository name}}`, for the
      engine repositories (`flutter_register_toolchains(prebuilt_tools = ...)`).
    """
    table = prebuilt_tools_table(module_ctx, _TABLE)
    repos = {}
    for version, by_platform in table.items():
        for key, entry in by_platform.items():
            host = _host_platform(key)
            if host == None:
                continue
            repo = _archive_repo_name(version, host)
            flutter_tools_archive_repo(
                name = repo,
                url = entry["url"],
                sha256 = entry["sha256"],
                flutter_version = version,
            )
            repos.setdefault(version, {})[host] = repo
    flutter_tools_hub_repo(
        name = _HUB,
        flutter_version = default_version,
        platforms = sorted(repos.get(default_version, {}).keys()),
        sources = {name: str(Label("//flutter/private/tools:" + name)) for name in FLUTTER_PREBUILT_TOOLS},
    )
    return repos
