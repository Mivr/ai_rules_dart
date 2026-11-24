"""Repository rule for downloading a desktop Flutter engine library.

Downloads the engine shared library for a specific desktop target platform
(e.g. libflutter_linux_gtk.so for Linux x64). This is a separate lazy repo
so it's only fetched when a cross-platform desktop build is actually used.

One repo per unique target platform, shared across hosts.
"""

load("//flutter/private:repo_metadata.bzl", "download_mode_metadata")
load(":artifact_urls.bzl", "desktop_engine_artifact_path", "engine_artifact_url", "require_sha256")
load(":download.bzl", "pinned_download_and_extract")
load(
    ":engine_helpers.bzl",
    "WINDOWS_CPP_CLIENT_WRAPPER_FILES",
    "cpp_client_wrapper_artifact_path",
    "cpp_client_wrapper_missing_error",
    "cpp_client_wrapper_sha_error",
    "engine_filegroup_for_os",
    "extract_macos_inner_framework",
)
load(":local_sdk.bzl", "engine_cache_dir", "link_local_dir", "macos_framework_cache_path", "resolve_local_sdk_root")

visibility(["//flutter/..."])

def _link_local_desktop_engine(repository_ctx, target_os, target_arch, artifact_path):
    """Links the desktop engine (and the Windows wrapper) out of a local SDK."""
    sdk_root = resolve_local_sdk_root(repository_ctx, getattr(repository_ctx.attr, "local_path", ""))
    sdk_dir_rel = "bin/cache/artifacts/engine/" + engine_cache_dir(artifact_path)
    if target_os == "macos":
        # A real install holds the extracted framework inside the
        # xcframework; only a downloaded double-zip needs unpacking. The
        # linked inner framework has the same Versions/A shape the
        # download mode produces, so consumers cannot tell the difference.
        framework_rel = "bin/cache/artifacts/engine/" + macos_framework_cache_path(
            engine_cache_dir(artifact_path),
        )
        link_local_dir(
            repository_ctx,
            sdk_root,
            framework_rel,
            "engine/FlutterMacOS.framework",
            "the {} desktop engine".format(artifact_path),
        )
    else:
        link_local_dir(
            repository_ctx,
            sdk_root,
            sdk_dir_rel,
            "engine",
            "the {} desktop engine".format(artifact_path),
        )
    if target_os == "windows":
        # The wrapper is published per host platform directory, without a
        # mode suffix (flutter_tool's `windows-sdk` binary-dir table).
        link_local_dir(
            repository_ctx,
            sdk_root,
            "bin/cache/artifacts/engine/windows-{}/cpp_client_wrapper".format(target_arch),
            "cpp-client-wrapper/cpp_client_wrapper",
            "the Windows C++ client wrapper",
        )

def _flutter_desktop_engine_repo_impl(repository_ctx):
    engine_revision = repository_ctx.attr.engine_revision
    target_os = repository_ctx.attr.target_os
    target_arch = repository_ctx.attr.target_arch
    mode = repository_ctx.attr.mode

    artifact_path = desktop_engine_artifact_path(target_os, target_arch, mode)
    if not artifact_path:
        fail("No desktop engine artifact for {}-{}-{}".format(target_os, target_arch, mode))

    if getattr(repository_ctx.attr, "local_path", ""):
        _link_local_desktop_engine(repository_ctx, target_os, target_arch, artifact_path)
        repository_ctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
            engine_filegroup = engine_filegroup_for_os(target_os),
        ))
        return download_mode_metadata(repository_ctx)

    url = engine_artifact_url(
        engine_revision,
        artifact_path,
        getattr(repository_ctx.attr, "engine_base_url", ""),
    )
    pinned_download_and_extract(
        repository_ctx,
        url = url,
        sha256 = require_sha256(repository_ctx.attr.sha256, url),
        output = "engine",
    )

    wrapper_error = cpp_client_wrapper_sha_error(
        target_os,
        target_arch,
        repository_ctx.attr.cpp_client_wrapper_sha256,
    )
    if wrapper_error != None:
        fail(wrapper_error)

    if target_os == "macos":
        extract_macos_inner_framework(repository_ctx)
    elif target_os == "windows":
        wrapper_path = cpp_client_wrapper_artifact_path(target_arch)
        wrapper_url = engine_artifact_url(
            engine_revision,
            wrapper_path,
            getattr(repository_ctx.attr, "engine_base_url", ""),
        )
        pinned_download_and_extract(
            repository_ctx,
            url = wrapper_url,
            sha256 = require_sha256(repository_ctx.attr.cpp_client_wrapper_sha256, wrapper_url),
            output = "cpp-client-wrapper",
        )
        present = [f for f in WINDOWS_CPP_CLIENT_WRAPPER_FILES if repository_ctx.path(f).exists]
        missing_error = cpp_client_wrapper_missing_error(target_arch, present)
        if missing_error != None:
            fail(missing_error)

    repository_ctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        engine_filegroup = engine_filegroup_for_os(target_os),
    ))
    return download_mode_metadata(repository_ctx)

_BUILD_TEMPLATE = """# Generated by flutter_desktop_engine_repo.bzl
exports_files(glob(["**"]), visibility = ["//visibility:public"])
{engine_filegroup}
"""

flutter_desktop_engine_repo = repository_rule(
    _flutter_desktop_engine_repo_impl,
    doc = "Downloads a desktop Flutter engine library for native and cross-platform builds.",
    attrs = {
        "engine_revision": attr.string(
            doc = "The engine commit hash the artifact is published under. " +
                  "Empty means a local SDK (with `local_path`).",
            default = "",
        ),
        "engine_base_url": attr.string(
            doc = "Optional replacement origin for the engine revision " +
                  "directory (an enterprise build). Empty means the default GCS base.",
            default = "",
        ),
        "local_path": attr.string(
            doc = "Optional path to a pre-extracted Flutter SDK " +
                  "(bin/cache layout) to source every artifact from instead " +
                  "of the network. Mutually exclusive with downloading.",
            default = "",
        ),
        "target_os": attr.string(mandatory = True, doc = "Target OS: macos, linux, or windows."),
        "target_arch": attr.string(mandatory = True, doc = "Target architecture: x64 or arm64."),
        "mode": attr.string(default = "release", doc = "Build mode: debug, profile, or release."),
        "sha256": attr.string(
            doc = "Expected SHA-256 of the engine archive. Unused with `local_path`.",
            default = "",
        ),
        "cpp_client_wrapper_sha256": attr.string(
            doc = "Expected SHA-256 of flutter-cpp-client-wrapper.zip. " +
                  "Required for Windows targets in download mode (the fetch " +
                  "fails without it); must be empty for other target OSes, " +
                  "and unused with `local_path`.",
            default = "",
        ),
    },
)
