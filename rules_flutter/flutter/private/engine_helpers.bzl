"""Shared engine helpers for Flutter repository rules.

Centralizes engine filegroup templates, binary name detection, platform
mapping, and macOS double-zip extraction used by repositories.bzl,
flutter_desktop_engine_repo.bzl, flutter_cross_repo.bzl, and
flutter_desktop_cross_repo.bzl.
"""

visibility(["//flutter/..."])

# -- Engine filegroup templates ------------------------------------------------
# Each template defines a filegroup named "engine_library" for a given OS.

MACOS_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(["engine/FlutterMacOS.framework/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

LINUX_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(
        ["engine/libflutter_linux_gtk.so", "engine/flutter_linux/*.h"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

WINDOWS_ENGINE_FILEGROUP = """
filegroup(
    name = "engine_library",
    srcs = glob(
        [
            "engine/flutter_windows.dll",
            "engine/flutter_windows.dll.lib",
            "engine/flutter_windows.h",
            "engine/flutter_export.h",
            "engine/flutter_messenger.h",
            "engine/flutter_plugin_registrar.h",
            "engine/flutter_texture_registrar.h",
            "cpp-client-wrapper/cpp_client_wrapper/include/flutter/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.h",
            "cpp-client-wrapper/cpp_client_wrapper/*.cc",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

def engine_filegroup_for_os(target_os):
    """Return the engine filegroup template string for the given OS.

    Args:
        target_os: One of "macos", "linux", or "windows".

    Returns:
        A BUILD file snippet defining the engine_library filegroup.
    """
    if target_os == "macos":
        return MACOS_ENGINE_FILEGROUP
    elif target_os == "linux":
        return LINUX_ENGINE_FILEGROUP
    elif target_os == "windows":
        return WINDOWS_ENGINE_FILEGROUP
    else:
        fail("Unsupported target OS for engine filegroup: {}".format(target_os))

# -- Binary name helpers -------------------------------------------------------

def dart_binary_name(platform):
    """Return the dart binary filename for the given host platform.

    Args:
        platform: Host platform string (e.g. "darwin-arm64", "windows-x64").

    Returns:
        "dart.exe" on Windows, "dart" otherwise.
    """
    if platform.startswith("windows"):
        return "dart.exe"
    return "dart"

def dartaotruntime_binary_name(platform):
    """Return the dartaotruntime binary filename for the given host platform.

    Args:
        platform: Host platform string (e.g. "darwin-arm64", "windows-x64").

    Returns:
        "dartaotruntime.exe" on Windows, "dartaotruntime" otherwise.
    """
    if platform.startswith("windows"):
        return "dartaotruntime.exe"
    return "dartaotruntime"

# -- Platform mapping ----------------------------------------------------------

# Maps Flutter artifact URL platform prefix to canonical OS name.
PLATFORM_PREFIX_TO_OS = {
    "darwin": "macos",
    "linux": "linux",
    "windows": "windows",
}

def platform_to_os(platform):
    """Extract the OS name from a platform string like "darwin-arm64".

    Args:
        platform: Platform string with format "{os_prefix}-{arch}".

    Returns:
        Canonical OS name: "macos", "linux", or "windows".
    """
    prefix = platform.split("-")[0]
    return PLATFORM_PREFIX_TO_OS.get(prefix, prefix)

def platform_to_arch(platform):
    """Extract the architecture from a platform string like "darwin-arm64".

    Args:
        platform: Platform string with format "{os_prefix}-{arch}".

    Returns:
        Architecture string (e.g. "arm64", "x64"), or empty if no dash.
    """
    if "-" in platform:
        return platform.split("-")[1]
    return ""

def gen_snapshot_host_platform(host_platform):
    """Map a host platform to the gen_snapshot artifact host platform.

    Flutter only publishes x64 gen_snapshot binaries for cross-compilation.
    On arm64 hosts (macOS Apple Silicon, Linux aarch64), the x64 binary
    runs via Rosetta 2 (macOS) or qemu (Linux).

    Args:
        host_platform: Host platform string (e.g. "darwin-arm64", "linux-x64").

    Returns:
        The platform string to use when downloading gen_snapshot
        (e.g. "darwin-x64" for "darwin-arm64").
    """
    _FALLBACK = {
        "darwin-arm64": "darwin-x64",
        "linux-arm64": "linux-x64",
    }
    return _FALLBACK.get(host_platform, host_platform)

def engine_arch_for_os(os_name, arch):
    """Return the engine architecture, applying platform-specific overrides.

    macOS ARM64 uses x64 engine artifacts (no arm64 build on CDN).

    Args:
        os_name: Canonical OS name ("macos", "linux", "windows").
        arch: Architecture string (e.g. "arm64", "x64").

    Returns:
        The effective engine architecture string.
    """
    if os_name == "macos":
        return "x64"
    return arch

# -- macOS double-zip extraction -----------------------------------------------

def extract_macos_inner_framework(repository_ctx, base_dir = "engine"):
    """Extract the inner FlutterMacOS.framework.zip from a macOS engine download.

    macOS engine artifacts are double-zipped: the outer zip contains
    FlutterMacOS.framework.zip which must be extracted to get the actual
    .framework directory.

    Args:
        repository_ctx: The repository_rule context.
        base_dir: Directory where the outer zip was extracted (default "engine").
    """
    repository_ctx.extract(
        archive = base_dir + "/FlutterMacOS.framework.zip",
        output = base_dir + "/FlutterMacOS.framework",
    )
    repository_ctx.delete(base_dir + "/FlutterMacOS.framework.zip")

# -- Linux multiarch triple mapping -------------------------------------------

def linux_multiarch_triple(arch):
    """Return the Debian multiarch triple for a Linux architecture.

    Args:
        arch: Architecture string ("x64" or "arm64").

    Returns:
        The multiarch triple (e.g. "x86_64-linux-gnu").
    """
    _TRIPLES = {
        "x64": "x86_64-linux-gnu",
        "arm64": "aarch64-linux-gnu",
    }
    triple = _TRIPLES.get(arch)
    if not triple:
        fail("No multiarch triple for architecture: {}".format(arch))
    return triple

def find_engine_header_dir(engine_files, header_suffix):
    """Find the parent directory of an engine header.

    Args:
        engine_files: List of Files from the engine_library filegroup.
        header_suffix: Path suffix to match (e.g. "flutter_linux/flutter_linux.h").

    Returns:
        The parent directory above the suffix match, or None if not found.
    """
    for f in engine_files:
        if f.path.endswith(header_suffix):
            idx = f.path.rfind(header_suffix)
            return f.path[:idx].rstrip("/")
    return None

# -- Windows C++ client wrapper --------------------------------------------------

# Every file the `flutter_<platform>` host repo aliases out of a downloaded
# Windows desktop engine repo (see `_lazy_repo_file_aliases` in
# flutter/repositories.bzl). The single definition lives here, next to the
# rule that fetches the archive; repositories.bzl loads it.
WINDOWS_CPP_CLIENT_WRAPPER_FILES = [
    "cpp-client-wrapper/LICENSE.client_wrapper_archive.md",
    "cpp-client-wrapper/cpp_client_wrapper/README",
    "cpp-client-wrapper/cpp_client_wrapper/binary_messenger_impl.h",
    "cpp-client-wrapper/cpp_client_wrapper/byte_buffer_streams.h",
    "cpp-client-wrapper/cpp_client_wrapper/core_implementations.cc",
    "cpp-client-wrapper/cpp_client_wrapper/engine_method_result.cc",
    "cpp-client-wrapper/cpp_client_wrapper/flutter_engine.cc",
    "cpp-client-wrapper/cpp_client_wrapper/flutter_view_controller.cc",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/basic_message_channel.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/binary_messenger.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/byte_streams.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/dart_project.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/encodable_value.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/engine_method_result.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/event_channel.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/event_sink.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/event_stream_handler.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/event_stream_handler_functions.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/flutter_engine.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/flutter_view.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/flutter_view_controller.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/message_codec.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/method_call.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/method_channel.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/method_codec.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/method_result.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/method_result_functions.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/plugin_registrar.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/plugin_registrar_windows.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/plugin_registry.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/standard_codec_serializer.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/standard_message_codec.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/standard_method_codec.h",
    "cpp-client-wrapper/cpp_client_wrapper/include/flutter/texture_registrar.h",
    "cpp-client-wrapper/cpp_client_wrapper/plugin_registrar.cc",
    "cpp-client-wrapper/cpp_client_wrapper/standard_codec.cc",
    "cpp-client-wrapper/cpp_client_wrapper/texture_registrar_impl.h",
]

def cpp_client_wrapper_artifact_path(target_arch):
    """Return the engine-relative path of the C++ client wrapper archive.

    Args:
        target_arch: Target architecture ("x64" or "arm64").

    Returns:
        Artifact path like "windows-x64/flutter-cpp-client-wrapper.zip".
    """
    return "windows-{arch}/flutter-cpp-client-wrapper.zip".format(arch = target_arch)

def cpp_client_wrapper_sha_error(target_os, target_arch, sha256):
    """Check the wrapper checksum against its target, returning an error or None.

    Windows targets in download mode always fetch the wrapper archive, so an
    empty checksum is a misconfiguration; any other target never fetches it,
    so a checksum there is one too. The rule passes a non-None return to `fail`.

    Args:
        target_os: Target OS ("macos", "linux", or "windows").
        target_arch: Target architecture ("x64" or "arm64").
        sha256: The `cpp_client_wrapper_sha256` attribute value.

    Returns:
        An error message naming the wrapper archive and the attribute (an
        empty Windows checksum) or the attribute and the target OS (a checksum
        nothing verifies), or None when the combination is valid.
    """
    if target_os == "windows":
        if not sha256:
            return "flutter_desktop_engine_repo: {archive} has no checksum: Windows targets fetch the C++ client wrapper in download mode, so pass its SHA-256 via cpp_client_wrapper_sha256".format(archive = cpp_client_wrapper_artifact_path(target_arch))
        return None
    if sha256:
        return "flutter_desktop_engine_repo: cpp_client_wrapper_sha256 is set for target_os {os}, which never fetches the C++ client wrapper (Windows targets only): remove cpp_client_wrapper_sha256".format(os = target_os)
    return None

def cpp_client_wrapper_missing_error(target_arch, present):
    """Check the extracted wrapper layout, returning an error or None.

    Args:
        target_arch: Target architecture ("x64" or "arm64").
        present: Paths present in the fetched repo, a subset of
            `WINDOWS_CPP_CLIENT_WRAPPER_FILES`.

    Returns:
        An error message naming the first missing file and the wrapper
        archive, or None when every aliased file is present.
    """
    for path in WINDOWS_CPP_CLIENT_WRAPPER_FILES:
        if path not in present:
            return "flutter_desktop_engine_repo: {archive} is missing expected file {missing}: the wrapper archive layout changed, update WINDOWS_CPP_CLIENT_WRAPPER_FILES in flutter/private/engine_helpers.bzl".format(archive = cpp_client_wrapper_artifact_path(target_arch), missing = path)
    return None
