"""Analysis tests for `dart_code_asset` attribute validation.

Every invalid `link_mode` / attribute combination is a user-facing contract.
An untested `fail()` is a message nobody has ever read, so each one gets a
case here asserting both that it fires and what it says.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_code_asset")
load("//dart:providers.bzl", "DartCodeAssetInfo")
load("//dart/private:dart_code_asset.bzl", "check_registered_cc_toolchain")

_ASSET_ID = "package:fixture/src/ffi/fixture.g.dart"
_SHARED_LIB = "//dart/tests/cc_fixture:empty_shared"
_PREBUILT = "//dart/tests/cc_fixture:prebuilt_fixture"

def _cc_toolchain_check_unit_test_impl(ctx):
    env = unittest.begin(ctx)

    probed_err = check_registered_cc_toolchain(
        "//dart/ext/sqlite3:code_asset",
        "//dart/ext/sqlite3:libsqlite3",
        "@@rules_cc++cc_configure_extension+local_config_cc//:cc-compiler-k8",
    )
    asserts.true(
        env,
        probed_err != None and "hermetic_cc_toolchain" in probed_err and "local_config_cc" in probed_err,
        "probed host local_config_cc toolchain must fail with actionable hermetic_cc_toolchain guidance: %s" % probed_err,
    )

    missing_err = check_registered_cc_toolchain(
        "//dart/ext/sqlite3:code_asset",
        "//dart/ext/sqlite3:libsqlite3",
        None,
    )
    asserts.true(
        env,
        missing_err != None and "hermetic_cc_toolchain" in missing_err,
        "missing C/C++ toolchain must fail with actionable hermetic_cc_toolchain guidance: %s" % missing_err,
    )

    asserts.equals(
        env,
        None,
        check_registered_cc_toolchain(
            "//dart/ext/sqlite3:code_asset",
            "//dart/ext/sqlite3:libsqlite3",
            "@@hermetic_cc_toolchain++toolchains+zig_sdk//toolchain:linux_amd64_gnu.2.28_cc",
        ),
    )
    asserts.equals(
        env,
        None,
        check_registered_cc_toolchain(
            "//dart/ext/sqlite3:code_asset",
            "//dart/ext/sqlite3:libsqlite3",
            "@@apple_support++apple_cc_configure_extension+local_config_apple_cc//:cc-compiler-darwin_arm64",
        ),
    )
    asserts.equals(
        env,
        None,
        check_registered_cc_toolchain(
            "//dart/ext/sqlite3:code_asset",
            "//dart/ext/sqlite3:libsqlite3",
            "@@rules_cc++cc_configure_extension+local_config_cc//:cc-compiler-x64_windows",
            is_windows = True,
        ),
    )
    return unittest.end(env)

_cc_toolchain_check_unit_test = unittest.make(_cc_toolchain_check_unit_test_impl)

def _expect(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

_static_rejected_test = _expect("dart-lang/sdk/issues/49418")
_bundle_needs_library_test = _expect("requires `shared_library =")
_bundle_rejects_system_uri_test = _expect("`system_uri` is only valid with")
_system_needs_uri_test = _expect("requires `system_uri =")
_system_rejects_library_test = _expect("`shared_library` is only valid with")
_process_rejects_library_test = _expect("`shared_library` is only valid with")
_executable_rejects_system_uri_test = _expect("`system_uri` is only valid with")
_prebuilt_and_shared_library_test = _expect("`prebuilt` and `shared_library`")
_prebuilt_needs_bundle_test = _expect("`prebuilt` is only valid with")

def _prebuilt_bundle_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartCodeAssetInfo]
    expected = ctx.file.expected_dynamic_library
    asserts.equals(env, expected, info.dynamic_library, "dynamic_library is the prebuilt file")
    asserts.equals(
        env,
        [expected],
        target[DefaultInfo].files.to_list(),
        "DefaultInfo.files carries the prebuilt file for runfiles staging",
    )
    asserts.equals(env, ctx.attr.expected_asset_id, info.asset_id)
    asserts.equals(env, "dynamic_loading_bundle", info.link_mode)
    return analysistest.end(env)

_prebuilt_bundle_test = analysistest.make(
    _prebuilt_bundle_test_impl,
    attrs = {
        "expected_asset_id": attr.string(),
        "expected_dynamic_library": attr.label(allow_single_file = [".so", ".dylib", ".dll"]),
    },
)

def code_asset_test_suite(name):
    """Declares the `dart_code_asset` validation fixtures and their tests.

    Args:
      name: Name of the generated `test_suite`.
    """

    # `static` is in the attr's `values` (so the rule can produce a useful
    # message) but is rejected by the implementation.
    dart_code_asset(
        name = "ca_static",
        asset_id = _ASSET_ID,
        link_mode = "static",
        shared_library = _SHARED_LIB,
        tags = ["manual"],
    )
    _static_rejected_test(
        name = "static_rejected_test",
        size = "small",
        target_under_test = ":ca_static",
    )

    dart_code_asset(
        name = "ca_bundle_no_library",
        asset_id = _ASSET_ID,
        tags = ["manual"],
    )
    _bundle_needs_library_test(
        name = "bundle_needs_library_test",
        size = "small",
        target_under_test = ":ca_bundle_no_library",
    )

    # The prebuilt path: a checked-in file backs the bundle, with no
    # `cc_shared_library`, no C/C++ toolchain resolution and no
    # `CcSharedLibraryInfo` read.
    dart_code_asset(
        name = "ca_prebuilt_bundle",
        asset_id = _ASSET_ID,
        prebuilt = _PREBUILT,
        tags = ["manual"],
    )
    _prebuilt_bundle_test(
        name = "prebuilt_bundle_test",
        size = "small",
        expected_asset_id = _ASSET_ID,
        expected_dynamic_library = _PREBUILT,
        target_under_test = ":ca_prebuilt_bundle",
    )

    dart_code_asset(
        name = "ca_prebuilt_and_shared",
        asset_id = _ASSET_ID,
        prebuilt = _PREBUILT,
        shared_library = _SHARED_LIB,
        tags = ["manual"],
    )
    _prebuilt_and_shared_library_test(
        name = "prebuilt_and_shared_library_test",
        size = "small",
        target_under_test = ":ca_prebuilt_and_shared",
    )

    # The exclusivity error is about the attribute pair, not the link mode:
    # a system-link-mode target naming both must report it too.
    dart_code_asset(
        name = "ca_prebuilt_and_shared_system",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        prebuilt = _PREBUILT,
        shared_library = _SHARED_LIB,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _prebuilt_and_shared_library_test(
        name = "prebuilt_and_shared_library_system_test",
        size = "small",
        target_under_test = ":ca_prebuilt_and_shared_system",
    )

    dart_code_asset(
        name = "ca_prebuilt_system",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        prebuilt = _PREBUILT,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _prebuilt_needs_bundle_test(
        name = "prebuilt_needs_bundle_test",
        size = "small",
        target_under_test = ":ca_prebuilt_system",
    )

    dart_code_asset(
        name = "ca_bundle_with_system_uri",
        asset_id = _ASSET_ID,
        shared_library = _SHARED_LIB,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _bundle_rejects_system_uri_test(
        name = "bundle_rejects_system_uri_test",
        size = "small",
        target_under_test = ":ca_bundle_with_system_uri",
    )

    dart_code_asset(
        name = "ca_system_no_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        tags = ["manual"],
    )
    _system_needs_uri_test(
        name = "system_needs_uri_test",
        size = "small",
        target_under_test = ":ca_system_no_uri",
    )

    dart_code_asset(
        name = "ca_system_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        shared_library = _SHARED_LIB,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_library_test(
        name = "system_rejects_library_test",
        size = "small",
        target_under_test = ":ca_system_with_library",
    )

    dart_code_asset(
        name = "ca_process_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_process",
        shared_library = _SHARED_LIB,
        tags = ["manual"],
    )
    _process_rejects_library_test(
        name = "process_rejects_library_test",
        size = "small",
        target_under_test = ":ca_process_with_library",
    )

    dart_code_asset(
        name = "ca_executable_with_system_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_executable",
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _executable_rejects_system_uri_test(
        name = "executable_rejects_system_uri_test",
        size = "small",
        target_under_test = ":ca_executable_with_system_uri",
    )

    _cc_toolchain_check_unit_test(
        name = "cc_toolchain_check_unit_test",
        size = "small",
    )

    native.test_suite(
        name = name,
        tests = [
            ":static_rejected_test",
            ":bundle_needs_library_test",
            ":prebuilt_bundle_test",
            ":prebuilt_and_shared_library_test",
            ":prebuilt_and_shared_library_system_test",
            ":prebuilt_needs_bundle_test",
            ":bundle_rejects_system_uri_test",
            ":system_needs_uri_test",
            ":system_rejects_library_test",
            ":process_rejects_library_test",
            ":executable_rejects_system_uri_test",
            ":cc_toolchain_check_unit_test",
        ],
    )
