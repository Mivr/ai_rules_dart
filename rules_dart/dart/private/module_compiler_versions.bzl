"""The pinned source closure of the module compiler, per Dart SDK version.

The module compiler (`//dart/private/tools:module_compiler.dart`) is built on
the Dart SDK's own front end, at the tag of the SDK that runs it: the kernel
format and the front end's API move with every release, and the tool reads
both from the tag instead of following them by hand. The SDK does not ship
those sources, so each supported SDK version pins them here:

- `sha256`: the checksum of the SDK tag's source archive,
  `https://github.com/dart-lang/sdk/archive/refs/tags/<version>.tar.gz`.
  GitHub publishes no checksum for a tag archive; this is the digest of the
  archive as first fetched, so a changed archive fails the fetch.
- `revision`: the SDK's commit, as its `revision` file states it. The SDK's
  own tools are built with `-Dsdk_hash=<first 10 characters>`, and a kernel
  carries that hash; the module compiler is built the same way, so its
  kernels are the ones the SDK's own compiler writes.
- `language_versions`: the language version each SDK package's pubspec
  states, for the package config the tool is built with.

An SDK version without a row cannot compile kernel modules. Adding one is:
fetch the tag archive, record its checksum and the three fields above, and
run `//dart/tests:module_compiler_*` against it.
"""

visibility(["//dart/..."])

# The SDK packages the tool imports. Only their `lib/` directories are kept.
MODULE_COMPILER_SDK_PACKAGES = [
    "_fe_analyzer_shared",
    "build_integration",
    "front_end",
    "kernel",
    "vm",
]

MODULE_COMPILER_SOURCES = {
    "3.14.1": struct(
        sha256 = "eb16c29569bc8ebe9e88add7387cbc2d7dcfb0e0edec855b8b758575c0a7c4cc",
        revision = "c8a0db5978a68d4037f7e5294ffc79867935c8c2",
        language_versions = {
            "_fe_analyzer_shared": "3.11",
            "build_integration": "3.13",
            "front_end": "3.13",
            "kernel": "3.13",
            "vm": "3.12",
        },
    ),
    "3.14.0": struct(
        sha256 = "f9cdd43f4c05d7f8cbd1caea31e3505d1f81c489d008c063c7bc028364844f65",
        revision = "fa8c1270c374c1346931583a17c3b7f278d3822d",
        language_versions = {
            "_fe_analyzer_shared": "3.11",
            "build_integration": "3.13",
            "front_end": "3.13",
            "kernel": "3.13",
            "vm": "3.12",
        },
    ),
}

# The hosted packages those SDK packages import. The SDK takes them from its
# own `DEPS`, so they are not in the tag archive; these are the versions pub
# resolves, with pub.dev's published archive checksums. One set serves every
# SDK version until one stops compiling against it.
MODULE_COMPILER_HOSTED_PACKAGES = {
    "collection": struct(
        version = "1.19.1",
        sha256 = "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76",
        language_version = "3.4",
    ),
    "meta": struct(
        version = "1.19.0",
        sha256 = "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9",
        language_version = "3.5",
    ),
    "package_config": struct(
        version = "3.0.0",
        sha256 = "ffcf4cf3d6c0b74ac43708d9f56625506e8a68aa935abe9d267a7330f320eb5d",
        language_version = "3.11",
    ),
    "path": struct(
        version = "1.9.1",
        sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5",
        language_version = "3.4",
    ),
    "source_span": struct(
        version = "1.10.2",
        sha256 = "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab",
        language_version = "3.1",
    ),
    "string_scanner": struct(
        version = "1.4.1",
        sha256 = "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43",
        language_version = "3.1",
    ),
    "term_glyph": struct(
        version = "1.2.2",
        sha256 = "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e",
        language_version = "3.1",
    ),
    "yaml": struct(
        version = "3.1.4",
        sha256 = "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea",
        language_version = "3.4",
    ),
}

def module_compiler_repo_name(version):
    """The name of the repository holding one SDK version's source closure.

    Args:
      version: A Dart SDK version string.

    Returns:
      The apparent repository name, e.g. `dart_module_compiler_3_13_5`.
    """
    return "dart_module_compiler_" + version.replace(".", "_").replace("-", "_")

def module_compiler_sources_label(version):
    """The sources target of an SDK version, or None when it is not pinned.

    The label goes through the `dart_module_compiler` hub, the one repository
    this module imports, so the closure of a version is fetched only when a
    toolchain of that version is used.

    Args:
      version: A Dart SDK version string.

    Returns:
      A `Label`, or None.
    """
    if version not in MODULE_COMPILER_SOURCES:
        return None
    return Label("@dart_module_compiler//:" + version)
