"""Prebuilt tools: a release's AOT snapshots of rules_dart's own tools.

A first build used to compile rules_dart's tools from source before it
compiled any of the user's code: the module compiler of the SDK (its kernel,
then its AOT snapshot, about 15 s on the critical path), the compile wrapper,
the layering check, the kernel linker, the test runner and the build_runner
launcher. A release builds them once per Dart SDK version and host platform,
on that platform, and ships each set as one archive beside the module's
source archive (see `RELEASING.md`). The released module carries the table
`//dart/private:prebuilt_tools.json`:

    {"tools": {"<dart version>": {"<platform>": {"url": ..., "sha256": ...}}}}

with `<platform>` a key of `PLATFORMS` (`linux-x64`, `macos-arm64`, ...).
The table in the repository is empty, so a build of the repository itself,
and of any workspace that uses it through a path override, builds every tool
from source. A platform missing from a released table builds from source too:
a platform may be absent, never wrong.

The extension turns the table into repositories, all fetched lazily:

- `rules_dart_tools_<version>_<platform>` holds one archive: the snapshots and
  executables of the set, and a `tools.json` that says what each file is. Its
  version must be the version the table lists it under.
- `rules_dart_tools`, the hub, which the rules name instead of the source
  targets. Each AOT snapshot tool is a `dart_prebuilt_or_source` that takes
  the prebuilt one when the exec platform has an archive and the Dart SDK that
  runs the tool is the version the snapshots were built by, and the source
  target otherwise. A self-contained `exe` tool is an alias that selects on
  the exec platform alone. `module_compiler_<version>_<platform>` aliases the
  module compiler file of an archive; an SDK repository whose version and
  platform have one uses it instead of building its own.

`--repo_env=RULES_DART_TOOLS=source` turns every prebuilt tool off, in both
modules: the table is then read as empty.
"""

load("//dart:providers.bzl", "DartCompileInfo")
load("//dart/private:download.bzl", "pinned_download_and_extract")
load("//dart/private:toolchains_repo.bzl", "PLATFORMS")

visibility("public")

# The tools a release prebuilds, by the name of their target under
# `//dart/private/tools`, with the form the target compiles to. An
# `aot-snapshot` runs under the `dartaotruntime` of the SDK that built it, so
# its prebuilt form is used only with that SDK version; an `exe` carries its
# own runtime.
PREBUILT_TOOLS = {
    "compile_wrapper": "aot-snapshot",
    "import_check": "aot-snapshot",
    "kernel_launcher": "exe",
    "kernel_link": "aot-snapshot",
    "test_runner": "exe",
}

# The environment variable that turns the prebuilt tools off.
PREBUILT_TOOLS_ENV = "RULES_DART_TOOLS"

_TABLE = Label("//dart/private:prebuilt_tools.json")
_HUB = "rules_dart_tools"
_EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

def _slug(version):
    return version.replace(".", "_")

def _archive_repo_name(version, platform):
    return "%s_%s_%s" % (_HUB, _slug(version), platform)

# ---------------------------------------------------------------------------
# Rules the generated repositories declare.

def _prebuilt_dart_tool_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/" + ctx.file.src.basename)
    ctx.actions.symlink(output = out, target_file = ctx.file.src, is_executable = True)
    return [
        DefaultInfo(executable = out, files = depset([out])),
        DartCompileInfo(executable = out, compile_mode = ctx.attr.compile_mode, sdk_version = ctx.attr.sdk_version),
    ]

prebuilt_dart_tool = rule(
    implementation = _prebuilt_dart_tool_impl,
    doc = "One tool of a release's prebuilt set: the file the release built, with the `DartCompileInfo` its source target has.",
    attrs = {
        "src": attr.label(doc = "The snapshot or executable.", mandatory = True, allow_single_file = True),
        "compile_mode": attr.string(doc = "`aot-snapshot` or `exe`.", mandatory = True, values = ["aot-snapshot", "exe"]),
        "sdk_version": attr.string(doc = "The Dart SDK version that built it.", mandatory = True),
    },
    executable = True,
)

def _forward(ctx, chosen):
    """Re-exports a tool target under this target's name."""
    exe = chosen[DefaultInfo].files_to_run.executable
    out = ctx.actions.declare_file(ctx.label.name + "/" + exe.basename)
    ctx.actions.symlink(output = out, target_file = exe, is_executable = True)
    providers = [DefaultInfo(
        executable = out,
        files = depset([out]),
        runfiles = chosen[DefaultInfo].default_runfiles,
    )]
    if DartCompileInfo in chosen:
        info = chosen[DartCompileInfo]
        providers.append(DartCompileInfo(executable = out, compile_mode = info.compile_mode, sdk_version = info.sdk_version))
    return providers

def _dart_prebuilt_or_source_impl(ctx):
    chosen = ctx.attr.source
    if ctx.attr.prebuilt != None:
        toolchain = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN]
        sdk = getattr(toolchain, "dart_sdk_info", None) if toolchain != None else None
        if sdk != None and sdk.version == ctx.attr.prebuilt_version:
            chosen = ctx.attr.prebuilt
    return _forward(ctx, chosen)

dart_prebuilt_or_source = rule(
    implementation = _dart_prebuilt_or_source_impl,
    doc = "An AOT snapshot tool: the release's prebuilt snapshot when the Dart SDK that runs it is the version that built it, the source target otherwise. Both are analyzed; only the chosen one is built.",
    attrs = {
        "prebuilt": attr.label(
            doc = "The prebuilt tool for the exec platform (a `select`), or None where there is none.",
            executable = True,
            cfg = "target",
        ),
        "prebuilt_version": attr.string(doc = "The Dart SDK version the prebuilt snapshot was built by."),
        "source": attr.label(
            doc = "The tool's source target.",
            mandatory = True,
            executable = True,
            cfg = "target",
        ),
    },
    toolchains = [config_common.toolchain_type(_EXEC_TOOLS_TOOLCHAIN, mandatory = False)],
    executable = True,
)

def _stage(ctx, src, outputs):
    """Places one file of the set under `files/`, keeping its basename (a snapshot records it)."""
    out = ctx.actions.declare_file("%s/files/%s" % (ctx.label.name, src.basename))
    ctx.actions.symlink(output = out, target_file = src)
    outputs.append(out)
    return "files/" + src.basename

def _dart_prebuilt_tool_set_impl(ctx):
    toolchain = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN]
    sdk = toolchain.dart_sdk_info
    if sdk.module_compiler == None:
        fail("%s: the Dart SDK %s has no module compiler to prebuild" % (ctx.label, sdk.version))
    outputs = []
    manifest = {"dart_version": sdk.version, "tools": {}}
    manifest["module_compiler"] = _stage(ctx, sdk.module_compiler, outputs)
    for tool in ctx.attr.tools:
        name = tool.label.name
        if name not in PREBUILT_TOOLS:
            fail("%s: %s is not one of the prebuilt tools %s" % (ctx.label, tool.label, sorted(PREBUILT_TOOLS)))
        info = tool[DartCompileInfo]
        if info.compile_mode != PREBUILT_TOOLS[name]:
            fail("%s: %s compiles to %s, the table says %s" % (ctx.label, tool.label, info.compile_mode, PREBUILT_TOOLS[name]))
        if info.sdk_version != sdk.version:
            fail("%s: %s was built by Dart %s, the exec SDK is %s" % (ctx.label, tool.label, info.sdk_version, sdk.version))
        manifest["tools"][name] = {"compile_mode": info.compile_mode, "file": _stage(ctx, tool[DefaultInfo].files_to_run.executable, outputs)}
    missing = [n for n in PREBUILT_TOOLS if n not in manifest["tools"]]
    if missing:
        fail("%s: the set lacks %s" % (ctx.label, ", ".join(missing)))
    tools_json = ctx.actions.declare_file(ctx.label.name + "/tools.json")
    ctx.actions.write(tools_json, json.encode_indent(manifest) + "\n")
    return [DefaultInfo(files = depset([tools_json] + outputs))]

dart_prebuilt_tool_set = rule(
    implementation = _dart_prebuilt_tool_set_impl,
    doc = "What a release prebuilds for one Dart SDK version on one platform: every tool of `PREBUILT_TOOLS` and the SDK's module compiler, in the exec configuration a consumer builds them in, with the `tools.json` the archive repository reads. `release tools` packs it.",
    attrs = {
        "tools": attr.label_list(
            doc = "The source targets of `PREBUILT_TOOLS`.",
            cfg = "exec",
            providers = [DartCompileInfo],
        ),
    },
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)

# ---------------------------------------------------------------------------
# Repositories.

def _archive_repo_impl(rctx):
    pinned_download_and_extract(rctx, url = rctx.attr.url, sha256 = rctx.attr.sha256)
    manifest = json.decode(rctx.read("tools.json"))
    version = rctx.attr.dart_version
    if manifest.get("dart_version") != version:
        fail("%s: the archive %s holds tools of Dart %s, the table lists it under %s" % (
            rctx.attr.name,
            rctx.attr.url,
            manifest.get("dart_version"),
            version,
        ))
    lines = [
        "# Generated by rules_dart's prebuilt_tools.bzl.",
        "load(%r, \"prebuilt_dart_tool\")" % str(Label("//dart/private:prebuilt_tools.bzl")),
        "",
        "alias(name = \"module_compiler\", actual = %r, visibility = [\"//visibility:public\"])" % (":" + manifest["module_compiler"]),
    ]
    for name, mode in sorted(PREBUILT_TOOLS.items()):
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
)""".format(name = repr(name), src = repr(tool["file"]), mode = repr(mode), version = repr(version)))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return rctx.repo_metadata(reproducible = True)

dart_tools_archive_repo = repository_rule(
    implementation = _archive_repo_impl,
    doc = "One archive of a release's prebuilt tools: one Dart SDK version, one platform.",
    attrs = {
        "url": attr.string(mandatory = True, doc = "Where the release published the archive."),
        "sha256": attr.string(mandatory = True, doc = "The archive's checksum, from the table."),
        "dart_version": attr.string(mandatory = True, doc = "The Dart SDK version the table lists the archive under."),
    },
)

def _hub_repo_impl(rctx):
    platforms = rctx.attr.platforms
    version = rctx.attr.dart_version
    lines = [
        "# Generated by rules_dart's prebuilt_tools.bzl: which tools the rules run.",
        "load(%r, \"dart_prebuilt_or_source\")" % str(Label("//dart/private:prebuilt_tools.bzl")),
    ]
    for platform in platforms:
        lines.append("""
config_setting(
    name = "exec_{platform}",
    constraint_values = {constraints},
)""".format(platform = platform, constraints = repr([str(Label(c)) for c in PLATFORMS[platform].compatible_with])))
    for name, mode in sorted(PREBUILT_TOOLS.items()):
        source = rctx.attr.sources[name]
        if not platforms:
            lines.append("""
alias(
    name = {name},
    actual = {source},
    visibility = ["//visibility:public"],
)""".format(name = repr(name), source = repr(source)))
            continue
        arms = {":exec_" + p: "@%s//:%s" % (_archive_repo_name(version, p), name) for p in platforms}
        if mode == "exe":
            arms["//conditions:default"] = source
            lines.append("""
alias(
    name = {name},
    actual = select({arms}),
    visibility = ["//visibility:public"],
)""".format(name = repr(name), arms = repr(arms)))
        else:
            arms["//conditions:default"] = None
            lines.append("""
dart_prebuilt_or_source(
    name = {name},
    prebuilt = select({arms}),
    prebuilt_version = {version},
    source = {source},
    visibility = ["//visibility:public"],
)""".format(name = repr(name), arms = repr(arms), version = repr(version), source = repr(source)))
    for key, repo in sorted(rctx.attr.module_compilers.items()):
        lines.append("""
alias(
    name = "module_compiler_{key}",
    actual = "@{repo}//:module_compiler",
    visibility = ["//visibility:public"],
)""".format(key = key, repo = repo))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return rctx.repo_metadata(reproducible = True)

dart_tools_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    doc = "The hub the rules name their tools through (`@rules_dart_tools//:<tool>`).",
    attrs = {
        "dart_version": attr.string(doc = "The Dart SDK version whose prebuilt tools the hub offers; empty for none."),
        "platforms": attr.string_list(doc = "The platforms with an archive of that version."),
        "sources": attr.string_dict(mandatory = True, doc = "Tool name to the canonical label of its source target."),
        "module_compilers": attr.string_dict(doc = "`<version>_<platform>` to the archive repository holding that module compiler."),
    },
)

# ---------------------------------------------------------------------------
# What the module extensions call.

def prebuilt_tools_table(module_ctx):
    """Reads rules_dart's prebuilt-tools table, as the switch leaves it.

    Args:
      module_ctx: A module extension context.

    Returns:
      `{version: {platform: {"url", "sha256"}}}`: empty in the repository,
      when `RULES_DART_TOOLS=source`, and for platforms rules_dart has no
      SDK repository for.
    """
    switch = module_ctx.getenv(PREBUILT_TOOLS_ENV, "")
    if switch not in ("", "prebuilt", "source"):
        fail("--repo_env=%s=%s: the value is `prebuilt` (the default) or `source`" % (PREBUILT_TOOLS_ENV, switch))
    table = json.decode(module_ctx.read(_TABLE)).get("tools", {})
    if switch == "source":
        return {}
    return {
        version: {p: entry for p, entry in by_platform.items() if p in PLATFORMS}
        for version, by_platform in table.items()
    }

def prebuilt_module_compiler(table, version, platform):
    """The hub label of a prebuilt module compiler, for an SDK repository's BUILD file.

    Args:
      table: What `prebuilt_tools_table` returned.
      version: The SDK repository's Dart version.
      platform: The SDK repository's host platform key.

    Returns:
      A canonical label string, or `""` when the table has no such archive.
    """
    if platform not in table.get(version, {}):
        return ""
    return str(Label("@%s//:module_compiler_%s_%s" % (_HUB, version, platform)))

def prebuilt_tools_repositories(table, generic_version):
    """Declares the archive repositories and the hub.

    Args:
      table: What `prebuilt_tools_table` returned.
      generic_version: The Dart SDK version of the default toolchain: the
        hub offers that version's prebuilt tools.
    """
    module_compilers = {}
    for version, by_platform in table.items():
        for platform, entry in by_platform.items():
            repo = _archive_repo_name(version, platform)
            dart_tools_archive_repo(
                name = repo,
                url = entry["url"],
                sha256 = entry["sha256"],
                dart_version = version,
            )
            module_compilers["%s_%s" % (version, platform)] = repo
    dart_tools_hub_repo(
        name = _HUB,
        dart_version = generic_version if generic_version in table else "",
        platforms = sorted(table.get(generic_version, {}).keys()),
        sources = {name: str(Label("//dart/private/tools:" + name)) for name in PREBUILT_TOOLS},
        module_compilers = module_compilers,
    )
