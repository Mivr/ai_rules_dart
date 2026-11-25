"""Prebuilt tools: a release's AOT snapshots of rules_dart's own tools.

A first build used to compile rules_dart's tools from source before it
compiled any of the user's code: the module compiler of the SDK (its kernel,
then its AOT snapshot, about 15 s on the critical path), the compile wrapper,
the layering check, the kernel linker, the test runner, the build_runner
launcher, and, while fetching, the pub archive scanner. A release builds them
once per Dart SDK version and host platform, on that platform, and ships each
set as one archive beside the module's source archive, and the scanner as one
more (see `RELEASING.md`). The released module carries the table
`//dart/private:prebuilt_tools.json`:

    {"tools": {"<dart version>": {"<platform>": {"url": ..., "sha256": ...}}},
     "pub_scanner": {"<platform>": {"url": ..., "sha256": ...}}}

with `<platform>` a key of `PLATFORMS` (`linux-x64`, `macos-arm64`, ...).
The table in the repository is empty, and a source archive of the module has
none, so a build of the repository itself, and of any workspace that uses it
through a path or git override or a source archive, builds every tool from
source. A platform missing from a released table builds from source too:
a platform may be absent, never wrong.

The extension turns the table into repositories, all fetched lazily:

- `rules_dart_tools_<version>_<platform>` holds one archive: the snapshots and
  executables of the set, and a `tools.json` that says what each file is. Its
  version must be the version the table lists it under. The SDK repository
  of that version and platform names it (`declare_dart_sdk_toolchains(
  prebuilt_tools = ...)`): its toolchain then carries the archive's module
  compiler and AOT snapshot tools (`SNAPSHOT_TOOLS`) in `DartSdkInfo`, so they
  always match the SDK that runs them. rules_flutter's archives carry the
  same tools built by the Dart SDK each Flutter release bundles, for its
  engine repositories' toolchains.
- `rules_dart_tools`, the hub, which the rules name instead of the source
  targets. Each AOT snapshot tool is a `dart_prebuilt_or_source` that takes
  the exec Dart toolchain's prebuilt one, and the source target when that
  toolchain carries none. A self-contained `exe` tool is an alias that selects
  the default version's archive on the exec platform alone.
- `dart_pub_scanner` (see `//dart/pub:pub_scanner.bzl`) downloads the
  scanner's archive for the fetch host: the snapshot the source build makes
  and the `dartaotruntime` of the SDK that made it, so no SDK is downloaded
  to scan pub archives.

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

# The AOT snapshot tools: a Dart toolchain carries its SDK's prebuilt ones.
SNAPSHOT_TOOLS = sorted([name for name, mode in PREBUILT_TOOLS.items() if mode == "aot-snapshot"])

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
    toolchain = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN]
    sdk = getattr(toolchain, "dart_sdk_info", None) if toolchain != None else None
    prebuilt = (getattr(sdk, "prebuilt_tools", None) or {}).get(ctx.attr.tool) if sdk != None else None
    if prebuilt != None:
        built_by = prebuilt[DartCompileInfo].sdk_version
        if built_by != sdk.version:
            fail("%s: the Dart SDK %s toolchain carries a prebuilt %s built by Dart %s" % (ctx.label, sdk.version, ctx.attr.tool, built_by))
        chosen = prebuilt
    return _forward(ctx, chosen)

dart_prebuilt_or_source = rule(
    implementation = _dart_prebuilt_or_source_impl,
    doc = "An AOT snapshot tool: the prebuilt snapshot the exec Dart toolchain carries for its own SDK (`DartSdkInfo.prebuilt_tools`), the source target when it carries none. Both are analyzed; only the chosen one is built.",
    attrs = {
        "tool": attr.string(doc = "The tool's name in `PREBUILT_TOOLS`.", mandatory = True, values = SNAPSHOT_TOOLS),
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

    # The scanner's own archive, which `release tools` packs apart: the
    # snapshot the scanner repository compiled with the default SDK, and the
    # `dartaotruntime` of that SDK, which is this exec SDK in a release.
    if ctx.file.pub_scanner != None:
        runtime = getattr(sdk, "kernel_module_files", None)
        runtime = runtime.dartaotruntime if runtime != None else None
        if runtime == None:
            fail("%s: the Dart SDK %s has no dartaotruntime to run the pub scanner with" % (ctx.label, sdk.version))
        for src in [ctx.file.pub_scanner, runtime]:
            out = ctx.actions.declare_file("%s/pub_scanner/%s" % (ctx.label.name, src.basename))
            ctx.actions.symlink(output = out, target_file = src)
            outputs.append(out)
    return [DefaultInfo(files = depset([tools_json] + outputs))]

dart_prebuilt_tool_set = rule(
    implementation = _dart_prebuilt_tool_set_impl,
    doc = "What a release prebuilds for one Dart SDK version on one platform: every tool of `PREBUILT_TOOLS` and the SDK's module compiler, in the exec configuration a consumer builds them in, with the `tools.json` the archive repository reads, and the pub archive scanner under `pub_scanner/`. `release tools` packs it.",
    attrs = {
        "tools": attr.label_list(
            doc = "The source targets of `PREBUILT_TOOLS`.",
            cfg = "exec",
            providers = [DartCompileInfo],
        ),
        "pub_scanner": attr.label(
            doc = "The source-built pub archive scanner snapshot (`@dart_pub_scanner//:snapshot`, the scanner under the name it has on every host).",
            allow_single_file = True,
        ),
    },
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)

# ---------------------------------------------------------------------------
# Repositories.

def download_prebuilt_archive(rctx, url, sha256):
    """Fetches and extracts one archive a release's table lists.

    The one download of every prebuilt archive: a tool set's
    (`dart_tools_archive_repo`) and the pub scanner's (`dart_pub_scanner`).
    The checksum is the table's, and the fetch fails before any byte is
    downloaded unless it is a pinned SHA-256 (`//dart/private:download.bzl`).

    Args:
      rctx: The repository context.
      url: Where the release published the archive.
      sha256: The archive's checksum, from the table.
    """
    pinned_download_and_extract(rctx, url = url, sha256 = sha256)

def _archive_repo_impl(rctx):
    download_prebuilt_archive(rctx, rctx.attr.url, rctx.attr.sha256)
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
        if mode == "aot-snapshot":
            lines.append("""
dart_prebuilt_or_source(
    name = {name},
    tool = {name},
    source = {source},
    visibility = ["//visibility:public"],
)""".format(name = repr(name), source = repr(source)))
            continue
        actual = repr(source)
        if platforms:
            arms = {":exec_" + p: "@%s//:%s" % (_archive_repo_name(version, p), name) for p in platforms}
            arms["//conditions:default"] = source
            actual = "select(%r)" % arms
        lines.append("""
alias(
    name = {name},
    actual = {actual},
    visibility = ["//visibility:public"],
)""".format(name = repr(name), actual = actual))
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return rctx.repo_metadata(reproducible = True)

dart_tools_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    doc = "The hub the rules name their tools through (`@rules_dart_tools//:<tool>`).",
    attrs = {
        "dart_version": attr.string(doc = "The Dart SDK version whose archives the `exe` tools come from; empty for none."),
        "platforms": attr.string_list(doc = "The platforms with an archive of that version."),
        "sources": attr.string_dict(mandatory = True, doc = "Tool name to the canonical label of its source target."),
    },
)

# ---------------------------------------------------------------------------
# What the module extensions and the SDK repositories call.

def _read_table(module_ctx, table):
    switch = module_ctx.getenv(PREBUILT_TOOLS_ENV, "")
    if switch not in ("", "prebuilt", "source"):
        fail("--repo_env=%s=%s: the value is `prebuilt` (the default) or `source`" % (PREBUILT_TOOLS_ENV, switch))
    if switch == "source":
        return {}

    # A source archive of the module (`git archive`, a forge's tarball) has no
    # table: `.gitattributes` keeps the checkout's empty one out, so that
    # `release_prep.sh` can add the release's. No table is an empty one,
    # which builds every tool from source. The sibling `BUILD.bazel` always
    # exists, and `path()` of a missing file fails, so the table's path comes
    # from it; `watch` re-runs the extension when the table appears.
    path = module_ctx.path(table.same_package_label("BUILD.bazel")).dirname.get_child(table.name)
    module_ctx.watch(path)
    if not path.exists:
        return {}
    return json.decode(module_ctx.read(path))

def prebuilt_tools_table(module_ctx, table = _TABLE):
    """Reads a prebuilt-tools table, as the switch leaves it.

    Args:
      module_ctx: A module extension context.
      table: The table's label: rules_dart's by default; rules_flutter
        passes its own, which the same switch turns off.

    Returns:
      `{version: {platform: {"url", "sha256"}}}`: empty in the repository
      and a source archive of it, when `RULES_DART_TOOLS=source`, and for platforms rules_dart has no
      SDK repository for.
    """
    return {
        version: {p: entry for p, entry in by_platform.items() if p in PLATFORMS}
        for version, by_platform in _read_table(module_ctx, table).get("tools", {}).items()
    }

def prebuilt_pub_scanner(module_ctx):
    """The scanner archives of rules_dart's table, for `pub_scanner_repo(prebuilt = ...)`.

    Args:
      module_ctx: The `dart` module extension context.

    Returns:
      `{platform: [url, sha256]}`: empty in the repository, a source archive
      of it, and when `RULES_DART_TOOLS=source`.
    """
    return {
        p: [entry["url"], entry["sha256"]]
        for p, entry in _read_table(module_ctx, _TABLE).get("pub_scanner", {}).items()
        if p in PLATFORMS
    }

def prebuilt_tools_repo(table, version, platform):
    """The archive repository of one SDK repository, for its `prebuilt_tools_repo`.

    Args:
      table: What `prebuilt_tools_table` returned.
      version: The SDK repository's Dart version.
      platform: The SDK repository's host platform key.

    Returns:
      The repository's name, which the SDK repository, made by the same
      extension, sees under that name; `""` when the table has no archive.
    """
    if platform not in table.get(version, {}):
        return ""
    return _archive_repo_name(version, platform)

def prebuilt_tool_labels(repo):
    """What `declare_dart_sdk_toolchains(prebuilt_tools = repo)` takes from an archive.

    Args:
      repo: The archive repository's label (`@<name>`): rules_dart's, or
        rules_flutter's, whose archives carry the same targets.

    Returns:
      `struct(module_compiler, tools)`: the module compiler's label and
      `{name: label}` of `SNAPSHOT_TOOLS`.
    """
    return struct(
        module_compiler = repo + "//:module_compiler",
        tools = {name: "%s//:%s" % (repo, name) for name in SNAPSHOT_TOOLS},
    )

def prebuilt_tools_repositories(table, generic_version):
    """Declares the archive repositories and the hub.

    Args:
      table: What `prebuilt_tools_table` returned.
      generic_version: The Dart SDK version of the default toolchain: the
        hub's `exe` tools come from that version's archives.
    """
    for version, by_platform in table.items():
        for platform, entry in by_platform.items():
            dart_tools_archive_repo(
                name = _archive_repo_name(version, platform),
                url = entry["url"],
                sha256 = entry["sha256"],
                dart_version = version,
            )
    dart_tools_hub_repo(
        name = _HUB,
        dart_version = generic_version if generic_version in table else "",
        platforms = sorted(table.get(generic_version, {}).keys()),
        sources = {name: str(Label("//dart/private/tools:" + name)) for name in PREBUILT_TOOLS},
    )
