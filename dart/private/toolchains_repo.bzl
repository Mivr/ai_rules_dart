"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
Former will be always fetched,
and the latter will only be fetched when user actually needs to build <LANG> code.
"
The "complex computation" in our case is simply downloading large artifacts.
This guidance tells us how to avoid that: we put the toolchain targets in the alias repository
with only the toolchain attribute pointing into the platform-specific repositories.
"""

load(
    "//dart/private:versions.bzl",
    "CROSS_DARTAOTRUNTIME_VERSIONS",
    "CROSS_GEN_SNAPSHOT_VERSIONS",
)

# HOST platforms: those we download an SDK for and can run a build on. Each key
# is both the download-URL slug and the `versions.bzl` checksum key:
# https://storage.googleapis.com/dart-archive/channels/stable/release/{version}/sdk/dartsdk-{platform}-release.zip
# Every entry costs one SHA-256 per pinned version, so add one only for a
# platform Bazel itself ships a release for. Cross-compilation destinations go
# in `TARGET_ONLY_PLATFORMS` instead.
PLATFORMS = {
    "macos-arm64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        dart_os = "macos",
        dart_arch = "arm64",
    ),
    "macos-x64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "macos",
        dart_arch = "x64",
    ),
    "linux-x64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "linux",
        dart_arch = "x64",
    ),
    "linux-arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        dart_os = "linux",
        dart_arch = "arm64",
    ),
    "windows-x64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "windows",
        dart_arch = "x64",
    ),
}

# Cross-compilation destinations with no SDK download and no host support.
# Cross-compilation reuses the HOST SDK's frontend with pinned per-pair
# `gen_snapshot_<host>_<target>` and `dartaotruntime_<target>` artifacts from
# `versions.bzl`, so no `dartsdk-<key>-release.zip` is fetched. Keys are still
# real SDK slugs, so promoting one to a full `PLATFORMS` entry later is a move
# plus its host SDK checksums.
#
# Neither is a host: Bazel publishes no riscv64 or armv7 release, so neither CPU
# can ever be an exec platform.
TARGET_ONLY_PLATFORMS = {
    "linux-riscv64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:riscv64",
        ],
        dart_os = "linux",
        dart_arch = "riscv64",
    ),
    # Dart's `linux-arm` is armv7 hardfloat. NOTE: `@platforms//cpu:arm` is an
    # ALIAS for `aarch32` — a different constraint value — and constraint
    # matching has no subtyping, so a user platform declaring `:arm` will NOT
    # resolve this toolchain. It must declare `:armv7`.
    "linux-arm": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:armv7",
        ],
        dart_os = "linux",
        dart_arch = "arm",
    ),
}

# Every platform usable as a cross-compilation TARGET: hosts plus target-only.
TARGET_PLATFORMS = dict(PLATFORMS)

TARGET_PLATFORMS.update(TARGET_ONLY_PLATFORMS)

# Known-working cross-compilation pairs: exec platform -> list of target platforms.
# Dart's AOT compiler can cross-compile exe and aot-snapshot to these targets.
# Keys must be `PLATFORMS` (an exec platform needs an SDK); values must be
# `TARGET_PLATFORMS`.
CROSS_TARGETS = {
    "macos-arm64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
    "macos-x64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
    "linux-x64": ["linux-arm64", "linux-riscv64", "linux-arm"],
    "linux-arm64": ["linux-x64", "linux-riscv64", "linux-arm"],
    "windows-x64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
}

def resolve_cross_sdk_artifacts(
        dart_version,
        exec_platform,
        target_platform,
        gen_snapshot_versions = CROSS_GEN_SNAPSHOT_VERSIONS,
        dartaotruntime_versions = CROSS_DARTAOTRUNTIME_VERSIONS,
        cross_targets = CROSS_TARGETS):
    """Validates a `(exec_platform, target_platform)` pair and returns its pinned cross-SDK metadata.

    Fails with a descriptive error when `(exec_platform, target_platform)` is not
    a supported cross-compilation pair in `cross_targets` or when either the
    `gen_snapshot` or `dartaotruntime` SHA-256 checksum is missing for
    `dart_version`.

    Args:
      dart_version: The Dart SDK version string (e.g. `"3.13.5"`).
      exec_platform: The host/exec platform key in `PLATFORMS` (e.g. `"linux-x64"`).
      target_platform: The target platform key in `TARGET_PLATFORMS` (e.g. `"linux-arm64"`).
      gen_snapshot_versions: Pin table mapping `version -> "<exec>_<target>" -> sha256`.
      dartaotruntime_versions: Pin table mapping `version -> "<target>" -> sha256`.
      cross_targets: Allowed `exec_platform -> [target_platform, ...]` mapping.

    Returns:
      `struct` with `exec_platform`, `target_platform`, `target_os`, `target_arch`,
      `gen_snapshot_filename`, `gen_snapshot_url`, `gen_snapshot_sha256`,
      `dartaotruntime_filename`, `dartaotruntime_url`, `dartaotruntime_sha256`.
    """
    if exec_platform not in PLATFORMS or exec_platform not in cross_targets:
        fail("Unsupported cross-compilation host platform %r (supported hosts: %s)" % (
            exec_platform,
            sorted(cross_targets.keys()),
        ))
    allowed_targets = cross_targets[exec_platform]
    if target_platform not in TARGET_PLATFORMS or target_platform not in allowed_targets:
        fail("Unsupported cross-compilation pair (%s -> %s); supported targets for %s: %s" % (
            exec_platform,
            target_platform,
            exec_platform,
            allowed_targets,
        ))

    host = PLATFORMS[exec_platform]
    target = TARGET_PLATFORMS[target_platform]
    exe_ext = ".exe" if host.dart_os == "windows" else ""
    gen_snapshot_filename = "gen_snapshot_%s_%s_%s_%s%s" % (
        host.dart_os,
        host.dart_arch,
        target.dart_os,
        target.dart_arch,
        exe_ext,
    )
    dartaotruntime_filename = "dartaotruntime_%s_%s" % (
        target.dart_os,
        target.dart_arch,
    )

    pair_key = "%s_%s" % (exec_platform, target_platform)
    version_gs = gen_snapshot_versions.get(dart_version, {})
    gen_snapshot_sha256 = version_gs.get(pair_key, "")
    if not gen_snapshot_sha256:
        fail("Missing sha256 checksum for cross-compilation artifact %s (Dart SDK %s, pair %s -> %s)" % (
            gen_snapshot_filename,
            dart_version,
            exec_platform,
            target_platform,
        ))

    version_rt = dartaotruntime_versions.get(dart_version, {})
    dartaotruntime_sha256 = version_rt.get(target_platform, "")
    if not dartaotruntime_sha256:
        fail("Missing sha256 checksum for cross-compilation artifact %s (Dart SDK %s, target %s)" % (
            dartaotruntime_filename,
            dart_version,
            target_platform,
        ))

    base_url = "https://storage.googleapis.com/dart-archive/channels/stable/release/%s/sdk" % dart_version
    return struct(
        exec_platform = exec_platform,
        target_platform = target_platform,
        target_os = target.dart_os,
        target_arch = target.dart_arch,
        gen_snapshot_filename = gen_snapshot_filename,
        gen_snapshot_url = "%s/%s" % (base_url, gen_snapshot_filename),
        gen_snapshot_sha256 = gen_snapshot_sha256,
        dartaotruntime_filename = dartaotruntime_filename,
        dartaotruntime_url = "%s/%s" % (base_url, dartaotruntime_filename),
        dartaotruntime_sha256 = dartaotruntime_sha256,
    )

def _toolchains_repo_impl(repository_ctx):
    build_content = """# Generated by toolchains_repo.bzl
#
# These can be registered via register_toolchains() or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the dart_register_toolchains macro
# so you don't normally need to interact with these targets.

"""

    # Native toolchains: exec and target constraints match the same platform.
    for [platform, meta] in PLATFORMS.items():
        build_content += """
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{platform}//:dart_toolchain",
    toolchain_type = "@rules_dart//dart:toolchain_type",
)
""".format(
            platform = platform,
            user_repository_name = repository_ctx.attr.user_repository_name,
            compatible_with = meta.compatible_with,
        )

    # Exec-tools toolchains: the codegen rules run a generator on the exec/host
    # machine and emit platform-agnostic Dart source, so SDK selection must not
    # depend on the build's target platform. One per host platform with
    # exec_compatible_with pinned and target_compatible_with omitted, so each
    # matches any target platform (iOS, Android, …). Reuses the native
    # dart_toolchain (the host SDK).
    for [platform, meta] in PLATFORMS.items():
        build_content += """
toolchain(
    name = "{platform}_exec_tools_toolchain",
    exec_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{platform}//:dart_toolchain",
    toolchain_type = "@rules_dart//dart:exec_tools_toolchain_type",
)
""".format(
            platform = platform,
            user_repository_name = repository_ctx.attr.user_repository_name,
            compatible_with = meta.compatible_with,
        )

    # Cross-compilation toolchains: exec constraints = host, target constraints = cross target.
    for [exec_platform, targets] in CROSS_TARGETS.items():
        exec_meta = PLATFORMS[exec_platform]
        for target_platform in targets:
            target_meta = TARGET_PLATFORMS[target_platform]
            cross_name = exec_platform + "_cross_" + target_platform
            build_content += """
toolchain(
    name = "{cross_name}_toolchain",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = {target_compatible_with},
    toolchain = "@{user_repository_name}_{exec_platform}//:dart_toolchain_cross_{target_platform}",
    toolchain_type = "@rules_dart//dart:toolchain_type",
)
""".format(
                cross_name = cross_name,
                exec_compatible_with = exec_meta.compatible_with,
                target_compatible_with = target_meta.compatible_with,
                user_repository_name = repository_ctx.attr.user_repository_name,
                exec_platform = exec_platform,
                target_platform = target_platform,
            )

    repository_ctx.file("BUILD.bazel", build_content)

    for version in repository_ctx.attr.versions:
        ver_slug = version.replace(".", "_")
        sdk_build = """# Generated by toolchains_repo.bzl
package(default_visibility = ["//visibility:public"])
"""
        for [platform, meta] in PLATFORMS.items():
            sdk_build += """
config_setting(
    name = "{platform}",
    constraint_values = {compatible_with},
)
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{ver_slug}_{platform}//:dart_toolchain",
    toolchain_type = "@rules_dart//dart:toolchain_type",
)
toolchain(
    name = "{platform}_exec_tools_toolchain",
    exec_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{ver_slug}_{platform}//:dart_toolchain",
    toolchain_type = "@rules_dart//dart:exec_tools_toolchain_type",
)
""".format(
                platform = platform,
                user_repository_name = repository_ctx.attr.user_repository_name,
                ver_slug = ver_slug,
                compatible_with = meta.compatible_with,
            )
        for [exec_platform, targets] in CROSS_TARGETS.items():
            exec_meta = PLATFORMS[exec_platform]
            for target_platform in targets:
                target_meta = TARGET_PLATFORMS[target_platform]
                cross_name = exec_platform + "_cross_" + target_platform
                sdk_build += """
toolchain(
    name = "{cross_name}_toolchain",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = {target_compatible_with},
    toolchain = "@{user_repository_name}_{ver_slug}_{exec_platform}//:dart_toolchain_cross_{target_platform}",
    toolchain_type = "@rules_dart//dart:toolchain_type",
)
""".format(
                    cross_name = cross_name,
                    exec_compatible_with = exec_meta.compatible_with,
                    target_compatible_with = target_meta.compatible_with,
                    user_repository_name = repository_ctx.attr.user_repository_name,
                    ver_slug = ver_slug,
                    exec_platform = exec_platform,
                    target_platform = target_platform,
                )
        for target_name in ["dart", "compile_files", "runtime_files", "analyze_files", "sdk_root"]:
            select_dict = {
                ":" + platform: "@{user_repository_name}_{ver_slug}_{platform}//:{actual}".format(
                    user_repository_name = repository_ctx.attr.user_repository_name,
                    ver_slug = ver_slug,
                    platform = platform,
                    actual = ("bin/dart.exe" if platform.startswith("windows") else "bin/dart") if target_name == "dart" else target_name,
                )
                for platform in PLATFORMS.keys()
            }
            sdk_build += """
alias(
    name = "{target_name}",
    actual = select({select_dict}),
)
""".format(
                target_name = target_name,
                select_dict = select_dict,
            )
        repository_ctx.file("sdk/" + version + "/BUILD.bazel", sdk_build)

toolchains_repo = repository_rule(
    _toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected.""",
    attrs = {
        "user_repository_name": attr.string(doc = "what the user chose for the base name"),
        "versions": attr.string_list(doc = "pinned SDK versions from versions.bzl", default = []),
    },
)
