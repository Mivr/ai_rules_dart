"""Pinned Android SDK and NDK repositories for the floor workspace.

`e2e/min_versions` has to build its Android leg on a bare host and in the
gate, where neither `ANDROID_HOME` nor `ANDROID_NDK_HOME` is exported. These
repository rules download the Google packages the referee pins, verify every
sha256, and generate rules_android's own SDK and NDK repository layout. The
workspace therefore builds the Android leg against one known toolchain
instead of whatever a host happens to have installed.

Only Linux builds the Android leg. On every other host the NDK repository is
empty, so the Apple legs never fetch a 600 MB archive; the SDK repository is
still generated because `register_toolchains` names its targets at module
load.
"""

visibility("private")

_BASE = "https://dl.google.com/android/repository/"

# The API level and build-tools release the floor workspace installs. They
# match the SDK packages the gate's referee pins.
_API_LEVEL = 35
_BUILD_TOOLS = "35.0.0"

# The Linux NDK release and its clang resource directory. r27d ships clang 18.
_NDK_URL = _BASE + "android-ndk-r27d-linux.zip"
_NDK_SHA256 = "601246087a682d1944e1e16dd85bc6e49560fe8b6d61255be2829178c8ed15d9"
_NDK_STRIP_PREFIX = "android-ndk-r27d"
_NDK_CLANG = "toolchains/llvm/prebuilt/linux-x86_64"
_NDK_CLANG_RESOURCE = "lib/clang/18"

_SDK_PACKAGES = [
    struct(
        url = _BASE + "platform-35_r02.zip",
        sha256 = "0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0",
        output = "platforms/android-35",
        strip_prefix = "android-35",
    ),
    struct(
        url = _BASE + "build-tools_r35_linux.zip",
        sha256 = "bd3a4966912eb8b30ed0d00b0cda6b6543b949d5ffe00bea54c04c81e1561d88",
        output = "build-tools/35.0.0",
        strip_prefix = "android-15",
    ),
    struct(
        url = _BASE + "platform-tools_r37.0.1-linux.zip",
        sha256 = "d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1",
        output = "platform-tools",
        strip_prefix = "platform-tools",
    ),
]

def _android_sdk_impl(rctx):
    """Materialize the pinned SDK and its rules_android BUILD file."""
    for package in _SDK_PACKAGES:
        rctx.download_and_extract(
            url = package.url,
            sha256 = package.sha256,
            output = package.output,
            stripPrefix = package.strip_prefix,
        )

    # Copied, not symlinked: a link into the main repo would hold a host path
    # and keep the repository out of the repo contents cache.
    rctx.file("helper.bzl", rctx.read(rctx.attr._helper))
    rctx.template(
        "BUILD.bazel",
        rctx.attr._template,
        substitutions = {
            "__repository_name__": rctx.name,
            "__build_tools_version__": _BUILD_TOOLS,
            "__build_tools_directory__": _BUILD_TOOLS,
            "__api_levels__": '"%d"' % _API_LEVEL,
            "__default_api_level__": str(_API_LEVEL),
            "__system_image_dirs__": "",
        },
        executable = False,
    )
    return rctx.repo_metadata(reproducible = True)

android_sdk = repository_rule(
    implementation = _android_sdk_impl,
    attrs = {
        "_helper": attr.label(
            allow_single_file = True,
            default = Label("@rules_android//rules/android_sdk_repository:helper.bzl"),
            doc = "rules_android's helpers loaded by the generated SDK BUILD file.",
        ),
        "_template": attr.label(
            allow_single_file = True,
            default = Label("@rules_android//rules/android_sdk_repository:template.bzl"),
            doc = "rules_android's Android SDK BUILD template.",
        ),
    },
    doc = "Downloads the pinned Android SDK packages and generates the SDK repository.",
)

def _android_ndk_impl(rctx):
    """Materialize the pinned Linux NDK, or an empty repository elsewhere."""
    if not rctx.os.name.startswith("linux"):
        rctx.file("BUILD.bazel", 'package(default_visibility = ["//visibility:public"])\n')
        return rctx.repo_metadata(reproducible = True)
    rctx.download_and_extract(
        url = _NDK_URL,
        sha256 = _NDK_SHA256,
        stripPrefix = _NDK_STRIP_PREFIX,
    )
    sysroot = _NDK_CLANG + "/sysroot"

    # rules_android_ndk keeps the legacy `ndk/sources` spelling (its root BUILD
    # globs both) so an NDK-managed Gradle project keeps working; the archive
    # already has the real `sources` tree at the repository root.
    rctx.symlink("sources", "ndk/sources")
    rctx.template(
        "BUILD.bazel",
        rctx.attr._root_template,
        substitutions = {
            "{clang_directory}": _NDK_CLANG,
            "{exec_compatible_with}": repr([
                "@platforms//os:linux",
                "@platforms//cpu:x86_64",
            ]),
        },
        executable = False,
    )
    rctx.template(
        "target_systems.bzl",
        rctx.attr._target_systems_template,
        substitutions = {},
        executable = False,
    )
    rctx.template(
        _NDK_CLANG + "/BUILD.bazel",
        rctx.attr._clang_template,
        substitutions = {
            "{api_level}": str(_API_LEVEL),
            "{clang_resource_directory}": _NDK_CLANG_RESOURCE,
            "{executable_extension}": "",
            "{repository_name}": rctx.attr._rules_repo.workspace_name,
            "{sysroot_directory}": sysroot,
        },
        executable = False,
    )
    rctx.template(
        sysroot + "/BUILD.bazel",
        rctx.attr._sysroot_template,
        substitutions = {"{api_level}": str(_API_LEVEL)},
        executable = False,
    )
    return rctx.repo_metadata(reproducible = True)

android_ndk = repository_rule(
    implementation = _android_ndk_impl,
    attrs = {
        "_clang_template": attr.label(
            allow_single_file = True,
            default = Label("@rules_android_ndk//:BUILD.ndk_clang.tpl"),
            doc = "rules_android_ndk's NDK clang package template.",
        ),
        "_root_template": attr.label(
            allow_single_file = True,
            default = Label("@rules_android_ndk//:BUILD.ndk_root.tpl"),
            doc = "rules_android_ndk's NDK root package template.",
        ),
        "_rules_repo": attr.label(
            allow_single_file = True,
            default = Label("@rules_android_ndk//:BUILD"),
            doc = "rules_android_ndk itself, whose name the clang template loads.",
        ),
        "_sysroot_template": attr.label(
            allow_single_file = True,
            default = Label("@rules_android_ndk//:BUILD.ndk_sysroot.tpl"),
            doc = "rules_android_ndk's NDK sysroot package template.",
        ),
        "_target_systems_template": attr.label(
            allow_single_file = True,
            default = Label("@rules_android_ndk//:target_systems.bzl.tpl"),
            doc = "rules_android_ndk's target-system table template.",
        ),
    },
    doc = "Downloads the pinned Linux NDK and generates its rules_android_ndk repository.",
)
