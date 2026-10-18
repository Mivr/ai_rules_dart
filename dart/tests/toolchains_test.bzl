"""Unit tests for the platform tables that drive toolchain generation.

`toolchains_repo.bzl` generates `@dart_toolchains//:BUILD.bazel` from three
tables, and nothing else validates them. A bad entry surfaces as a raw Starlark
`KeyError` during repository evaluation, or — worse — as a toolchain that
silently never matches. These assert the invariants the generator depends on.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//dart/private:toolchains_repo.bzl",
    "CROSS_TARGETS",
    "PLATFORMS",
    "TARGET_ONLY_PLATFORMS",
    "TARGET_PLATFORMS",
    "resolve_cross_sdk_artifacts",
)
load(
    "//dart/private:versions.bzl",
    "CROSS_DARTAOTRUNTIME_VERSIONS",
    "CROSS_GEN_SNAPSHOT_VERSIONS",
    "TOOL_VERSIONS",
)
load(":small_suite.bzl", "small_unittest_suite")

# Dart's `--target-arch` vocabulary (`dart compile exe --help`).
_DART_ARCHES = ["arm", "arm64", "ia32", "riscv32", "riscv64", "x64"]

# Dart's `--target-os` vocabulary, restricted to those we generate toolchains
# for. Dart also accepts android/fuchsia/ios, which rules_dart does not target.
_DART_OSES = ["linux", "macos", "windows"]

_HEX_CHARS = {c: True for c in "0123456789abcdef".elems()}

def _is_sha256(digest):
    return len(digest) == 64 and all([c in _HEX_CHARS for c in digest.elems()])

def _target_platforms_is_the_union_test_impl(ctx):
    env = unittest.begin(ctx)

    # PLATFORMS and TARGET_ONLY_PLATFORMS must be disjoint: an entry in both
    # would mean one Dart arch owning two `dart_toolchain_cross_*` names.
    for key in TARGET_ONLY_PLATFORMS.keys():
        asserts.false(
            env,
            key in PLATFORMS,
            "%s is in both PLATFORMS and TARGET_ONLY_PLATFORMS" % key,
        )

    asserts.equals(
        env,
        len(PLATFORMS) + len(TARGET_ONLY_PLATFORMS),
        len(TARGET_PLATFORMS),
        "TARGET_PLATFORMS must be exactly the union of the two tables",
    )
    for key in PLATFORMS.keys() + TARGET_ONLY_PLATFORMS.keys():
        asserts.true(env, key in TARGET_PLATFORMS, "%s missing from TARGET_PLATFORMS" % key)

    return unittest.end(env)

def _cross_targets_resolve_test_impl(ctx):
    env = unittest.begin(ctx)

    for exec_platform, targets in CROSS_TARGETS.items():
        # An exec platform runs the compiler, so it needs its own SDK.
        asserts.true(
            env,
            exec_platform in PLATFORMS,
            "CROSS_TARGETS key %s is not a host platform" % exec_platform,
        )
        for target in targets:
            # This is the exact lookup `_toolchains_repo_impl` performs; a miss
            # is a KeyError during repo evaluation.
            asserts.true(
                env,
                target in TARGET_PLATFORMS,
                "CROSS_TARGETS[%s] names unknown target %s" % (exec_platform, target),
            )

            # A self-pair would emit a cross toolchain whose exec and target
            # constraints both equal the native one's. The native toolchain is
            # written first and would win, leaving the cross entry dead.
            asserts.false(
                env,
                target == exec_platform,
                "CROSS_TARGETS[%s] contains itself" % exec_platform,
            )

        # Duplicate targets would emit two toolchains with the same name.
        asserts.equals(
            env,
            len(targets),
            len({t: None for t in targets}),
            "CROSS_TARGETS[%s] has duplicates" % exec_platform,
        )

    return unittest.end(env)

def _platform_metadata_shape_test_impl(ctx):
    env = unittest.begin(ctx)

    for name, meta in TARGET_PLATFORMS.items():
        oses = [c for c in meta.compatible_with if c.startswith("@platforms//os:")]
        cpus = [c for c in meta.compatible_with if c.startswith("@platforms//cpu:")]
        asserts.equals(env, 1, len(oses), "%s needs exactly one os constraint" % name)
        asserts.equals(env, 1, len(cpus), "%s needs exactly one cpu constraint" % name)
        asserts.equals(
            env,
            len(meta.compatible_with),
            len(oses) + len(cpus),
            "%s has a constraint that is neither os nor cpu" % name,
        )

        # dart_os/dart_arch are passed straight to `--target-os`/`--target-arch`,
        # so a typo becomes a compiler error in a cross build we may not test.
        asserts.true(
            env,
            meta.dart_os in _DART_OSES,
            "%s: dart_os %r is not a Dart target OS" % (name, meta.dart_os),
        )
        asserts.true(
            env,
            meta.dart_arch in _DART_ARCHES,
            "%s: dart_arch %r is not a Dart target arch" % (name, meta.dart_arch),
        )

    return unittest.end(env)

def _checksums_cover_every_host_test_impl(ctx):
    env = unittest.begin(ctx)

    # `_dart_sdk_repo_impl` does TOOL_VERSIONS[version][platform], which hard
    # errors on a miss. Every pinned version therefore needs every host key —
    # and no extras, which would mean a checksum for a platform we never fetch.
    want = sorted(PLATFORMS.keys())
    for version, checksums in TOOL_VERSIONS.items():
        asserts.equals(
            env,
            want,
            sorted(checksums.keys()),
            "TOOL_VERSIONS[%s] does not match the host platform set" % version,
        )

    # Cross-only targets must NOT carry checksums: no SDK is downloaded for them.
    for version, checksums in TOOL_VERSIONS.items():
        for key in TARGET_ONLY_PLATFORMS.keys():
            asserts.false(
                env,
                key in checksums,
                "TOOL_VERSIONS[%s] has a checksum for cross-only %s" % (version, key),
            )

    return unittest.end(env)

def _cross_checksums_cover_every_pair_test_impl(ctx):
    env = unittest.begin(ctx)

    want_versions = sorted(TOOL_VERSIONS.keys())
    asserts.equals(
        env,
        want_versions,
        sorted(CROSS_GEN_SNAPSHOT_VERSIONS.keys()),
        "CROSS_GEN_SNAPSHOT_VERSIONS keys must match TOOL_VERSIONS",
    )
    asserts.equals(
        env,
        want_versions,
        sorted(CROSS_DARTAOTRUNTIME_VERSIONS.keys()),
        "CROSS_DARTAOTRUNTIME_VERSIONS keys must match TOOL_VERSIONS",
    )

    want_pairs = sorted([
        "%s_%s" % (exec_platform, target)
        for exec_platform, targets in CROSS_TARGETS.items()
        for target in targets
    ])
    want_targets = sorted({
        target: None
        for targets in CROSS_TARGETS.values()
        for target in targets
    }.keys())

    for version in want_versions:
        gs_table = CROSS_GEN_SNAPSHOT_VERSIONS[version]
        rt_table = CROSS_DARTAOTRUNTIME_VERSIONS[version]
        asserts.equals(
            env,
            want_pairs,
            sorted(gs_table.keys()),
            "CROSS_GEN_SNAPSHOT_VERSIONS[%s] does not match CROSS_TARGETS pairs" % version,
        )
        asserts.equals(
            env,
            want_targets,
            sorted(rt_table.keys()),
            "CROSS_DARTAOTRUNTIME_VERSIONS[%s] does not match CROSS_TARGETS targets" % version,
        )
        for pair_key, digest in gs_table.items():
            asserts.true(
                env,
                _is_sha256(digest),
                "CROSS_GEN_SNAPSHOT_VERSIONS[%s][%s] is not a valid SHA-256: %r" % (version, pair_key, digest),
            )
        for target_key, digest in rt_table.items():
            asserts.true(
                env,
                _is_sha256(digest),
                "CROSS_DARTAOTRUNTIME_VERSIONS[%s][%s] is not a valid SHA-256: %r" % (version, target_key, digest),
            )
        for exec_platform, targets in CROSS_TARGETS.items():
            for target_platform in targets:
                meta = resolve_cross_sdk_artifacts(version, exec_platform, target_platform)
                asserts.equals(env, gs_table["%s_%s" % (exec_platform, target_platform)], meta.gen_snapshot_sha256)
                asserts.equals(env, rt_table[target_platform], meta.dartaotruntime_sha256)
                asserts.true(env, meta.gen_snapshot_url.endswith("/" + meta.gen_snapshot_filename))
                asserts.true(env, meta.dartaotruntime_url.endswith("/" + meta.dartaotruntime_filename))

    return unittest.end(env)

def _resolve_cross_probe_impl(ctx):
    resolve_cross_sdk_artifacts(
        dart_version = ctx.attr.dart_version,
        exec_platform = ctx.attr.exec_platform,
        target_platform = ctx.attr.target_platform,
        gen_snapshot_versions = {} if ctx.attr.empty_gen_snapshot_versions else CROSS_GEN_SNAPSHOT_VERSIONS,
        dartaotruntime_versions = {} if ctx.attr.empty_dartaotruntime_versions else CROSS_DARTAOTRUNTIME_VERSIONS,
    )
    return [DefaultInfo()]

_resolve_cross_probe = rule(
    implementation = _resolve_cross_probe_impl,
    attrs = {
        "dart_version": attr.string(mandatory = True),
        "exec_platform": attr.string(mandatory = True),
        "target_platform": attr.string(mandatory = True),
        "empty_gen_snapshot_versions": attr.bool(default = False),
        "empty_dartaotruntime_versions": attr.bool(default = False),
    },
)

def _expect_cross_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

sdk_toolchain_unsupported_cross_target_test = analysistest.make(
    _expect_cross_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_error": attr.string(mandatory = True),
    },
)

_EXPECTED_TOOL_FILES = [
    "analysis_server.dart.snapshot",
    "core.dart",
    "dart",
    "dart2js.dart.snapshot",
    "dartvm",
    "gen_kernel_aot.dart.snapshot",
    "kernel-service.dart.snapshot",
    "libraries.json",
    "version",
    "vm_platform_strong.dill",
]

_EXPECTED_COMPILE_FILES = [
    "dart",
    "dartvm",
    "gen_kernel_aot.dart.snapshot",
    "kernel-service.dart.snapshot",
    "libraries.json",
    "version",
    "vm_platform_strong.dill",
]

_EXPECTED_RUNTIME_FILES = [
    "dart",
    "dartvm",
    "kernel-service.dart.snapshot",
    "libraries.json",
    "version",
    "vm_platform_strong.dill",
]

_EXPECTED_ANALYZE_FILES = [
    "analysis_server.dart.snapshot",
    "core.dart",
    "dart",
    "libraries.json",
    "version",
]

def _basenames(files_depset):
    return sorted([f.basename for f in files_depset.to_list()])

def _assert_sdk_subsets(env, sdk_info):
    asserts.equals(env, "3.11.0", sdk_info.version)
    asserts.true(
        env,
        sdk_info.dart.short_path.endswith("dart-sdk/bin/dart"),
        "unexpected dart path: %s" % sdk_info.dart.short_path,
    )
    asserts.equals(env, _EXPECTED_TOOL_FILES, _basenames(sdk_info.tool_files))
    asserts.equals(env, _EXPECTED_COMPILE_FILES, _basenames(sdk_info.compile_files))
    asserts.equals(env, _EXPECTED_RUNTIME_FILES, _basenames(sdk_info.runtime_files))
    asserts.equals(env, _EXPECTED_ANALYZE_FILES, _basenames(sdk_info.analyze_files))

def _sdk_toolchain_macro_native_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    sdk_info = target[platform_common.ToolchainInfo].dart_sdk_info
    _assert_sdk_subsets(env, sdk_info)
    asserts.equals(env, "", sdk_info.target_os)
    asserts.equals(env, "", sdk_info.target_arch)
    asserts.equals(env, None, sdk_info.cross_gen_snapshot)
    asserts.equals(env, None, sdk_info.cross_dartaotruntime)
    return analysistest.end(env)

def _sdk_toolchain_macro_cross_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    sdk_info = target[platform_common.ToolchainInfo].dart_sdk_info
    _assert_sdk_subsets(env, sdk_info)
    asserts.equals(env, "linux", sdk_info.target_os)
    asserts.equals(env, "arm64", sdk_info.target_arch)
    return analysistest.end(env)

def _sdk_toolchain_macro_alias_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, _EXPECTED_TOOL_FILES, _basenames(target[DefaultInfo].files))
    return analysistest.end(env)

def _sdk_toolchain_macro_dict_cross_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    sdk_info = target[platform_common.ToolchainInfo].dart_sdk_info
    asserts.equals(env, "linux", sdk_info.target_os)
    asserts.equals(env, "riscv64", sdk_info.target_arch)
    asserts.equals(env, ["dart", "extra.txt", "version"], _basenames(sdk_info.tool_files))
    asserts.equals(env, ["dart", "version"], _basenames(sdk_info.compile_files))
    return analysistest.end(env)

sdk_toolchain_macro_native_test = analysistest.make(_sdk_toolchain_macro_native_test_impl)
sdk_toolchain_macro_cross_test = analysistest.make(_sdk_toolchain_macro_cross_test_impl)
sdk_toolchain_macro_alias_test = analysistest.make(_sdk_toolchain_macro_alias_test_impl)
sdk_toolchain_macro_dict_cross_test = analysistest.make(_sdk_toolchain_macro_dict_cross_test_impl)

_t0_test = unittest.make(_target_platforms_is_the_union_test_impl)
_t1_test = unittest.make(_cross_targets_resolve_test_impl)
_t2_test = unittest.make(_platform_metadata_shape_test_impl)
_t3_test = unittest.make(_checksums_cover_every_host_test_impl)
_t4_test = unittest.make(_cross_checksums_cover_every_pair_test_impl)

def toolchains_test_suite(name):
    """Registers the toolchain platform and checksum table unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _resolve_cross_probe(
        name = name + "_unsupported_pair_fixture",
        dart_version = "3.13.5",
        exec_platform = "linux-x64",
        target_platform = "macos-arm64",
        tags = ["manual"],
    )
    sdk_toolchain_unsupported_cross_target_test(
        name = name + "_unsupported_pair_test",
        size = "small",
        expected_error = "Unsupported cross-compilation pair (linux-x64 -> macos-arm64)",
        target_under_test = ":" + name + "_unsupported_pair_fixture",
    )
    _resolve_cross_probe(
        name = name + "_unpinned_gen_snapshot_fixture",
        dart_version = "0.0.0-unpinned",
        exec_platform = "linux-x64",
        target_platform = "linux-arm64",
        tags = ["manual"],
    )
    sdk_toolchain_unsupported_cross_target_test(
        name = name + "_unpinned_gen_snapshot_test",
        size = "small",
        expected_error = "Missing sha256 checksum for cross-compilation artifact gen_snapshot_linux_x64_linux_arm64",
        target_under_test = ":" + name + "_unpinned_gen_snapshot_fixture",
    )
    _resolve_cross_probe(
        name = name + "_unpinned_dartaotruntime_fixture",
        dart_version = "3.13.5",
        empty_dartaotruntime_versions = True,
        exec_platform = "linux-x64",
        target_platform = "linux-arm64",
        tags = ["manual"],
    )
    sdk_toolchain_unsupported_cross_target_test(
        name = name + "_unpinned_dartaotruntime_test",
        size = "small",
        expected_error = "Missing sha256 checksum for cross-compilation artifact dartaotruntime_linux_arm64",
        target_under_test = ":" + name + "_unpinned_dartaotruntime_fixture",
    )
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
    )
