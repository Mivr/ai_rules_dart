"""Repository rule and C++/Swift cross-toolchain definitions for xtool Darwin SDKs on Linux.

Downloads a checksummed `xtool` `darwin.artifactbundle` archive (`url` +
`sha256`, hermetic) or symlinks an explicitly configured local bundle (`path`,
non-hermetic), containing `iPhoneOS.sdk`, `iPhoneSimulator.sdk`, and
`MacOSX.sdk`, and emits Bazel `cc_toolchain`, Swift wrapper targets, and
`toolchain` definitions for:
  - `ios_arm64` (`arm64-apple-ios14.0`)
  - `ios_sim_arm64` (`arm64-apple-ios14.0-simulator`)
  - `ios_x64` (`x86_64-apple-ios14.0-simulator`)
  - `macos_arm64` (`arm64-apple-macosx11.0`)
  - `macos_x64` (`x86_64-apple-macosx11.0`)

No host environment variables, `HOME`, `PATH`, `which`, or well-known host
directories are probed. When neither `url` nor `path` is configured, the
repository rule still instantiates with `SDK_AVAILABLE = False` so that
`bazel test //...` works, but any target that requires the SDK fails at
analysis with instructions on how to configure `flutter.darwin_sdk`.

IMPORTANT (Apple SDK licensing): `rules_flutter` never bundles or downloads an
Apple SDK by default (`url` and `path` both default to `""`). Users must obtain
and supply their own `darwin.artifactbundle` (`iPhoneOS.sdk`,
`iPhoneSimulator.sdk`, `MacOSX.sdk`) in compliance with the Apple Xcode and
Apple SDKs Agreement.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
)
load("@rules_cc//cc:defs.bzl", "CcToolchainConfigInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load(":artifact_urls.bzl", "require_sha256")
load(":download.bzl", "pinned_download_and_extract")
load(":xtool_sdk_render.bzl", _XTOOL_DARWIN_TARGETS = "XTOOL_DARWIN_TARGETS", _generate_xtool_darwin_sdk_build = "generate_xtool_darwin_sdk_build", _render_xtool_wrapper_scripts = "render_xtool_wrapper_scripts")

visibility(["//flutter/..."])

# Re-exported for the repository tests, which load them from this file.
XTOOL_DARWIN_TARGETS = _XTOOL_DARWIN_TARGETS
generate_xtool_darwin_sdk_build = _generate_xtool_darwin_sdk_build
render_xtool_wrapper_scripts = _render_xtool_wrapper_scripts

_UNCONFIGURED_SDK_ERROR = (
    "The xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured. " +
    "rules_flutter does not download an Apple SDK by default; you must supply your own " +
    "darwin.artifactbundle under Apple's Xcode and Apple SDKs Agreement.\n" +
    "Configure it in your root MODULE.bazel with a checksummed archive:\n" +
    "    flutter = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n" +
    "    flutter.darwin_sdk(\n" +
    "        url = \"https://.../darwin.artifactbundle.tar.gz\",\n" +
    "        sha256 = \"<sha256>\",\n" +
    "    )\n" +
    "or, for a local non-hermetic SDK:\n" +
    "    flutter.darwin_sdk(path = \"<path-to-darwin.artifactbundle>\")"
)

UNCONFIGURED_SDK_ERROR = _UNCONFIGURED_SDK_ERROR

_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.objc_compile,
    ACTION_NAMES.objcpp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
]

_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
    ACTION_NAMES.objc_executable,
]

def _xtool_darwin_cc_toolchain_config_impl(ctx):
    if not ctx.attr.sdk_available or not ctx.attr.sdk_path:
        fail(_UNCONFIGURED_SDK_ERROR)

    ws_root = ctx.label.workspace_root
    sysroot_path = (
        "%s/%s" % (ws_root, ctx.attr.sdk_path) if (ws_root and not ctx.attr.sdk_path.startswith("/")) else ctx.attr.sdk_path
    )
    llvm_bin_path = "%s/llvm/bin" % ws_root if ws_root else "llvm/bin"
    llvm_clang_lib_path = "%s/llvm/lib/clang" % ws_root if ws_root else "llvm/lib/clang"

    compile_flags = [
        "-target",
        ctx.attr.triple,
        "-isysroot",
        sysroot_path,
        "-no-canonical-prefixes",
    ]
    link_flags = [
        "-target",
        ctx.attr.triple,
        "--ld-path=%s/ld64.lld" % llvm_bin_path,
        "-isysroot",
        sysroot_path,
        "-no-canonical-prefixes",
    ]

    default_flags_feature = feature(
        name = "xtool_darwin_default_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = compile_flags)],
            ),
            flag_set(
                actions = _LINK_ACTIONS,
                flag_groups = [flag_group(flags = link_flags)],
            ),
        ],
    )

    tool_paths = [
        tool_path(name = "gcc", path = "bin/clang_%s" % ctx.attr.target_key),
        tool_path(name = "ld", path = "bin/ld64.lld_%s" % ctx.attr.target_key),
        tool_path(name = "ar", path = "bin/llvm-ar"),
        tool_path(name = "cpp", path = "bin/clang-cpp_%s" % ctx.attr.target_key),
        tool_path(name = "gcov", path = "bin/llvm-cov"),
        tool_path(name = "nm", path = "bin/llvm-nm"),
        tool_path(name = "objdump", path = "bin/llvm-objdump"),
        tool_path(name = "strip", path = "bin/llvm-strip"),
    ]

    builtin_include_dirs = [
        sysroot_path,
        llvm_clang_lib_path,
    ]
    if ctx.attr.sdk_path not in builtin_include_dirs:
        builtin_include_dirs.append(ctx.attr.sdk_path)
    if "llvm/lib/clang" not in builtin_include_dirs:
        builtin_include_dirs.append("llvm/lib/clang")

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        features = [default_flags_feature],
        cxx_builtin_include_directories = builtin_include_dirs,
        toolchain_identifier = "xtool_darwin_%s" % ctx.attr.target_key,
        host_system_name = "x86_64-unknown-linux-gnu",
        target_system_name = ctx.attr.triple,
        target_cpu = ctx.attr.target_cpu,
        target_libc = "macosx",
        compiler = "clang",
        abi_version = "darwin",
        abi_libc_version = "darwin",
        tool_paths = tool_paths,
    )

xtool_darwin_cc_toolchain_config = rule(
    implementation = _xtool_darwin_cc_toolchain_config_impl,
    attrs = {
        "sdk_available": attr.bool(
            default = True,
            doc = "Whether the Darwin SDK is configured; the config fails at analysis when False.",
        ),
        "target_key": attr.string(
            mandatory = True,
            doc = "Key selecting this target's toolchain, used in tool paths and the toolchain identifier.",
        ),
        "triple": attr.string(
            mandatory = True,
            doc = "LLVM target triple passed as `-target` (e.g. `aarch64-apple-ios`).",
        ),
        "target_cpu": attr.string(
            mandatory = True,
            doc = "Target CPU for the toolchain.",
        ),
        "sdk_path": attr.string(
            default = "",
            doc = "SDK sysroot path used as `-isysroot`.",
        ),
    },
    provides = [CcToolchainConfigInfo],
    doc = "C++ toolchain config for one xtool Darwin target (device, simulator or macOS).",
)

def _xtool_darwin_sdk_target_impl(ctx):
    if not ctx.attr.sdk_available:
        fail(_UNCONFIGURED_SDK_ERROR)
    return [DefaultInfo(files = depset(ctx.files.srcs))]

xtool_darwin_sdk_target = rule(
    implementation = _xtool_darwin_sdk_target_impl,
    attrs = {
        "sdk_available": attr.bool(
            mandatory = True,
            doc = "Whether the SDK is configured; the target fails at analysis when False.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "SDK files exposed when configured.",
        ),
    },
    doc = "Exposes files from @flutter_xtool_darwin_sdk or fails at analysis when the SDK is not configured.",
)

FlutterXtoolSdkInfo = provider(
    doc = "Metadata and status for the configured xtool Darwin SDK (`darwin.artifactbundle`).",
    fields = {
        "sdk_available": "bool: Whether a darwin.artifactbundle was explicitly configured.",
        "sdk_paths": "dict: Mapping from SDK name (iPhoneOS, iPhoneSimulator, MacOSX) to path.",
        "swift_bin_dir": "string: Relative path to the Swift/Clang toolchain bin directory.",
        "sdk_files": "depset: Files in the SDK repository.",
    },
)

def _xtool_darwin_sdk_status_impl(ctx):
    sdk_files = depset(ctx.files.sdk_files)
    return [
        DefaultInfo(files = sdk_files),
        FlutterXtoolSdkInfo(
            sdk_available = ctx.attr.sdk_available,
            sdk_paths = ctx.attr.sdk_paths,
            swift_bin_dir = ctx.attr.swift_bin_dir,
            sdk_files = sdk_files,
        ),
    ]

xtool_darwin_sdk_status = rule(
    implementation = _xtool_darwin_sdk_status_impl,
    attrs = {
        "sdk_available": attr.bool(
            mandatory = True,
            doc = "Whether a `darwin.artifactbundle` was explicitly configured.",
        ),
        "sdk_paths": attr.string_dict(
            default = {},
            doc = "Mapping from SDK name (iPhoneOS, iPhoneSimulator, MacOSX) to path.",
        ),
        "swift_bin_dir": attr.string(
            default = "",
            doc = "Relative path to the Swift/Clang toolchain bin directory.",
        ),
        "sdk_files": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Files in the SDK repository.",
        ),
    },
    provides = [FlutterXtoolSdkInfo],
    doc = "Exposes `FlutterXtoolSdkInfo` metadata for the configured xtool Darwin SDK.",
)

def validate_darwin_sdk_config(
        *,
        url = "",
        sha256 = "",
        path = "",
        swift_toolchain_path = "",
        require_configured = False,
        context = "flutter.darwin_sdk"):
    """Validates xtool Darwin SDK configuration attributes.

    Args:
        url: Archive download URL (hermetic when paired with `sha256`).
        sha256: Expected SHA-256 hex digest for `url`.
        path: Local filesystem path to `darwin.artifactbundle` (non-hermetic).
        swift_toolchain_path: Optional local path to the Linux Swift toolchain.
        require_configured: When True (e.g. an explicit `flutter.darwin_sdk()`
            tag), requires either `url` or `path` to be non-empty.
        context: Prefix used in failure messages.

    Returns:
        struct(url, sha256, path, swift_toolchain_path, configured)
    """
    if url and path:
        fail("%s: specify either 'url' (with 'sha256') or 'path', not both." % context)
    if sha256 and not url:
        fail("%s: 'sha256' requires 'url' to be set." % context)
    if url:
        if not sha256:
            fail("%s: 'sha256' is required when 'url' is set (%s)." % (context, url))
        require_sha256(sha256, url)
    if require_configured and not url and not path:
        fail("%s: must specify either 'url' (with 'sha256') or 'path'." % context)
    return struct(
        url = url,
        sha256 = sha256,
        path = path,
        swift_toolchain_path = swift_toolchain_path,
        configured = bool(url or path),
    )

def resolve_darwin_sdk_from_modules(modules):
    """Extracts and validates `flutter.darwin_sdk` tags across Bzlmod modules.

    Only the root module (`mod.is_root`) may set `flutter.darwin_sdk`, and at
    most once.

    Args:
        modules: Iterable of Bzlmod module objects (`module_ctx.modules`).

    Returns:
        struct(url, sha256, path, swift_toolchain_path, configured)
    """
    found = None
    declarations = []
    for mod in modules:
        tags = getattr(mod.tags, "darwin_sdk", [])
        if not tags:
            continue
        if not mod.is_root:
            mod_name = getattr(mod, "name", "") or "<non-root>"
            fail(
                "Only the root module may set the flutter.darwin_sdk tag " +
                "(found in non-root module '%s')." % mod_name,
            )
        mod_name = getattr(mod, "name", "") or "<root>"
        for sdk_tag in tags:
            locator = getattr(sdk_tag, "path", "") or getattr(sdk_tag, "url", "")
            declarations.append(mod_name if not locator else "%s (%s)" % (mod_name, locator))
        if len(tags) > 1 or found != None:
            fail(
                "flutter.darwin_sdk may be specified at most once in the root module " +
                "(duplicate `darwin_sdk` tag). Declared by: %s." % ", ".join(declarations),
            )
        sdk_tag = tags[0]
        found = validate_darwin_sdk_config(
            url = getattr(sdk_tag, "url", ""),
            sha256 = getattr(sdk_tag, "sha256", ""),
            path = getattr(sdk_tag, "path", ""),
            swift_toolchain_path = getattr(sdk_tag, "swift_toolchain_path", ""),
            require_configured = True,
            context = "flutter.darwin_sdk",
        )

    if found != None:
        return found
    return struct(
        url = "",
        sha256 = "",
        path = "",
        swift_toolchain_path = "",
        configured = False,
    )

def resolve_darwin_artifactbundle_sdk_paths(info_json_text, bundle_root):
    """Parses `darwin.artifactbundle/info.json` and returns a dict of SDK paths.

    Maps `"iPhoneOS"`, `"iPhoneSimulator"`, and `"MacOSX"` to their resolved
    directory paths under `bundle_root`.

    Args:
      info_json_text: Raw JSON string from `darwin.artifactbundle/info.json`.
      bundle_root: Root directory path of the extracted or symlinked bundle.

    Returns:
      Dict mapping `"iPhoneOS"`, `"iPhoneSimulator"`, and `"MacOSX"` to SDK paths.
    """
    prefix = bundle_root.rstrip("/")
    resolved = {
        "iPhoneOS": "%s/iPhoneOS.sdk" % prefix,
        "iPhoneSimulator": "%s/iPhoneSimulator.sdk" % prefix,
        "MacOSX": "%s/MacOSX.sdk" % prefix,
    }
    if not info_json_text:
        return resolved

    parsed = json.decode(info_json_text)
    if type(parsed) != "dict":
        return resolved
    artifacts = parsed.get("artifacts", {})
    if type(artifacts) != "dict":
        return resolved

    mapping = {
        "iphoneos": "iPhoneOS",
        "iphonesimulator": "iPhoneSimulator",
        "macosx": "MacOSX",
    }
    for key, val in artifacts.items():
        if type(val) != "dict":
            continue
        variants = val.get("variants", [])
        if type(variants) != "list":
            continue
        key_lower = key.lower()
        for variant in variants:
            if type(variant) != "dict":
                continue
            rel_path = variant.get("path", "")
            if not rel_path:
                continue
            path_lower = rel_path.lower()
            for prefix_key, sdk_name in mapping.items():
                if key_lower.startswith(prefix_key) or prefix_key in path_lower:
                    resolved[sdk_name] = "%s/%s" % (prefix, rel_path)
    return resolved

def _write_wrapper_scripts(repository_ctx, sdk_available, sdk_paths, swift_bin_dir):
    scripts = render_xtool_wrapper_scripts(
        sdk_available = sdk_available,
        sdk_paths = sdk_paths,
        swift_bin_dir = swift_bin_dir,
    )
    for rel_path, body in scripts.items():
        repository_ctx.file(rel_path, body, executable = True)

def _resolve_bundle_sdk_paths(repository_ctx):
    direct_info = repository_ctx.path("sdk/info.json")
    nested_info = repository_ctx.path("sdk/darwin.artifactbundle/info.json")
    if direct_info.exists:
        return resolve_darwin_artifactbundle_sdk_paths(repository_ctx.read(direct_info), "sdk")
    if nested_info.exists:
        return resolve_darwin_artifactbundle_sdk_paths(
            repository_ctx.read(nested_info),
            "sdk/darwin.artifactbundle",
        )
    if repository_ctx.path("sdk/darwin.artifactbundle").exists:
        return resolve_darwin_artifactbundle_sdk_paths("", "sdk/darwin.artifactbundle")
    return resolve_darwin_artifactbundle_sdk_paths("", "sdk")

def _host_llvm_exec_pair(repository_ctx):
    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch.lower()
    exec_os = "macos" if ("mac" in os_name or "darwin" in os_name) else "linux"
    exec_cpu = "aarch64" if arch in ("aarch64", "arm64") else "x86_64"
    return exec_os, exec_cpu

def _symlink_hermetic_llvm(repository_ctx, tool_repos):
    """Symlinks the hermetic LLVM prebuilt toolchain for the exec host.

    `tool_repos` holds the apparent names of llvm's per-host
    prebuilt-toolchain repos, in the fixed order shared with the flutter
    extension (index `2 * is_macos + is_x86_64`). The `Label(...)` is built
    here, inside the repo rule, so it resolves in rules_flutter's own repo
    mapping — whose MODULE.bazel imports exactly these names from llvm's
    toolchain extension — and not in any consumer mapping. Only the selected
    entry is resolved (fetched); the rest are never touched. Same host
    mapping as `resource_dir_arg` in `@llvm//toolchain:selects.bzl`.
    """
    exec_os, exec_cpu = _host_llvm_exec_pair(repository_ctx)
    index = (2 if exec_os == "macos" else 0) + (1 if exec_cpu == "x86_64" else 0)
    llvm_build_path = repository_ctx.path(Label("@" + tool_repos[index] + "//:BUILD.bazel"))
    llvm_root = llvm_build_path.dirname
    repository_ctx.symlink(llvm_root.get_child("bin"), "llvm/bin")
    repository_ctx.symlink(llvm_root.get_child("lib"), "llvm/lib")

def _xtool_darwin_sdk_repo_impl(repository_ctx):
    cfg = validate_darwin_sdk_config(
        url = repository_ctx.attr.url,
        sha256 = repository_ctx.attr.sha256,
        path = repository_ctx.attr.path,
        swift_toolchain_path = repository_ctx.attr.swift_toolchain_path,
        require_configured = False,
        context = "xtool_darwin_sdk_repo",
    )

    # The hermetic LLVM toolchain archive is only resolved when the flutter
    # extension passes llvm's per-host tool repo names: a configured Darwin
    # SDK, or rules_flutter's own module (whose hermetic-LLVM script tests
    # assert the linkage with no SDK). Resolving the label fetches the
    # matching toolchain archive, which plain consumers must never pay for:
    # they get an empty list and keep empty `llvm/` globs (all `allow_empty`)
    # so `bazel test //...` still works; anything that executes the wrappers
    # fails with the configuration error. A configured-but-missing bundle
    # path fails first, before any LLVM download starts.
    bundle_path = None
    if cfg.path:
        bundle_path = repository_ctx.path(cfg.path)
        if not bundle_path.exists:
            fail(
                "xtool_darwin_sdk_repo: configured darwin.artifactbundle path '%s' does not exist." % cfg.path,
            )
    if repository_ctx.attr.llvm_tool_repos:
        _symlink_hermetic_llvm(repository_ctx, repository_ctx.attr.llvm_tool_repos)

    sdk_available = False
    sdk_paths = {}
    swift_bin_dir = ""

    if cfg.url:
        pinned_download_and_extract(
            repository_ctx,
            url = cfg.url,
            sha256 = require_sha256(cfg.sha256, cfg.url),
            output = "sdk",
        )
        sdk_available = True
        sdk_paths = _resolve_bundle_sdk_paths(repository_ctx)
    elif cfg.path:
        repository_ctx.symlink(bundle_path, "sdk")
        sdk_available = True
        sdk_paths = _resolve_bundle_sdk_paths(repository_ctx)

    if cfg.swift_toolchain_path:
        tc_path = repository_ctx.path(cfg.swift_toolchain_path)
        if not tc_path.exists:
            fail(
                "xtool_darwin_sdk_repo: configured swift_toolchain_path '%s' does not exist." % cfg.swift_toolchain_path,
            )
        usr_bin = tc_path.get_child("usr").get_child("bin")
        bin_dir = tc_path.get_child("bin")
        bin_target = usr_bin if usr_bin.exists else (bin_dir if bin_dir.exists else tc_path)
        repository_ctx.symlink(bin_target, "swift_bin")
        swift_bin_dir = "swift_bin"

    _write_wrapper_scripts(repository_ctx, sdk_available, sdk_paths, swift_bin_dir)
    repository_ctx.file(
        "BUILD.bazel",
        generate_xtool_darwin_sdk_build(
            sdk_available = sdk_available,
            sdk_paths = sdk_paths,
            swift_bin_dir = swift_bin_dir,
        ),
    )

xtool_darwin_sdk_repo = repository_rule(
    implementation = _xtool_darwin_sdk_repo_impl,
    attrs = {
        "path": attr.string(
            doc = "Optional local filesystem path to `darwin.artifactbundle` (local, non-hermetic).",
            default = "",
        ),
        "url": attr.string(
            doc = "Optional URL to download `darwin.artifactbundle` archive (hermetic; requires `sha256`).",
            default = "",
        ),
        "sha256": attr.string(
            doc = "Required SHA-256 checksum when `url` is specified.",
            default = "",
        ),
        "swift_toolchain_path": attr.string(
            doc = "Optional local path to the Linux Swift toolchain root directory (non-hermetic).",
            default = "",
        ),
        "llvm_tool_repos": attr.string_list(
            doc = "Apparent names of llvm's per-host prebuilt-toolchain repos, " +
                  "in the fixed order shared with the flutter extension. Only the entry " +
                  "matching the exec host is resolved; an empty list symlinks nothing " +
                  "and fetches no LLVM.",
            default = [],
        ),
    },
    doc = "Configures the xtool Darwin SDK (iPhoneOS.sdk, iPhoneSimulator.sdk, MacOSX.sdk) and Linux -> Darwin C++/Swift cross-toolchains.",
)
