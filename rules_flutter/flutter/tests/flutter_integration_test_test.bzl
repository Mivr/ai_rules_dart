"""Unit tests for `flutter_integration_test`, `chrome_headless_shell_repo`, `linux_headless_runtime_repo`, and `android_headless_runtime_repo`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:android_headless_runtime_repo.bzl",
    "ANDROID_EMULATOR_BUILD_ID",
    "ANDROID_EMULATOR_SHA256",
    "ANDROID_HEADLESS_RUNTIME_DEB_PACKAGES",
    "ANDROID_PLATFORM_TOOLS_SHA256",
    "ANDROID_PLATFORM_TOOLS_VERSION",
    "ANDROID_SYSTEM_IMAGE_SHA256",
    "android_emulator_url",
    "android_platform_tools_url",
    "android_system_image_url",
    "validate_android_headless_runtime_downloads",
)
load(
    "//flutter/private:chrome_headless_shell_repo.bzl",
    "CHROME_HEADLESS_SHELL_SHA256",
    "CHROME_HEADLESS_SHELL_VERSION",
    "CHROME_RUNTIME_DEB_PACKAGES",
    "chrome_headless_shell_url",
    "validate_chrome_headless_shell_downloads",
)
load(
    "//flutter/private:flutter_integration_test_android.bzl",
    "ANDROID_TEST_EXECUTION_REQUIREMENTS",
)
load(
    "//flutter/private:flutter_integration_test_bootstrap.bzl",
    "make_android_integration_bootstrap_content",
    "make_linux_integration_bootstrap_content",
    "make_web_integration_bootstrap_content",
)
load(
    "//flutter/private:linux_headless_runtime_repo.bzl",
    "LINUX_HEADLESS_RUNTIME_DEB_PACKAGES",
    "validate_linux_headless_runtime_downloads",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_TEST_IMPORT = "../../integration_test/app_test.dart"

def _chrome_headless_shell_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "155.0.8059.84", CHROME_HEADLESS_SHELL_VERSION)
    asserts.equals(
        env,
        "a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c",
        CHROME_HEADLESS_SHELL_SHA256,
    )
    asserts.true(env, CHROME_HEADLESS_SHELL_VERSION in chrome_headless_shell_url(CHROME_HEADLESS_SHELL_VERSION))
    asserts.true(env, len(CHROME_RUNTIME_DEB_PACKAGES) >= 40)
    validated = validate_chrome_headless_shell_downloads(
        CHROME_HEADLESS_SHELL_VERSION,
        CHROME_HEADLESS_SHELL_SHA256,
    )
    asserts.equals(env, CHROME_HEADLESS_SHELL_SHA256, validated.browser_sha256)
    asserts.equals(env, len(CHROME_RUNTIME_DEB_PACKAGES), len(validated.runtime_debs))
    for entry in validated.runtime_debs:
        asserts.equals(env, 64, len(entry.sha256))
    return unittest.end(env)

def _linux_headless_runtime_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, len(LINUX_HEADLESS_RUNTIME_DEB_PACKAGES) >= 100)
    validated = validate_linux_headless_runtime_downloads()
    asserts.equals(env, len(LINUX_HEADLESS_RUNTIME_DEB_PACKAGES), len(validated.runtime_debs))
    urls = [entry.url for entry in validated.runtime_debs]
    asserts.true(env, any(["/xvfb_" in u for u in urls]))
    asserts.true(env, any(["/x11-xkb-utils_" in u for u in urls]))
    asserts.true(env, any(["/libgtk-3-0_" in u for u in urls]))
    asserts.true(env, any(["/libgl1-mesa-dri_" in u for u in urls]))
    asserts.true(env, any(["/libegl-mesa0_" in u for u in urls]))
    for entry in validated.runtime_debs:
        asserts.equals(env, 64, len(entry.sha256))
    return unittest.end(env)

def _android_headless_runtime_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, "emulator-linux_x64" in android_emulator_url(ANDROID_EMULATOR_BUILD_ID))
    asserts.true(env, "platform-tools" in android_platform_tools_url(ANDROID_PLATFORM_TOOLS_VERSION))
    asserts.true(env, "aosp_atd/x86_64" in android_system_image_url())
    asserts.equals(env, 64, len(ANDROID_EMULATOR_SHA256))
    asserts.equals(env, 64, len(ANDROID_PLATFORM_TOOLS_SHA256))
    asserts.equals(env, 64, len(ANDROID_SYSTEM_IMAGE_SHA256))
    asserts.true(env, len(ANDROID_HEADLESS_RUNTIME_DEB_PACKAGES) >= 14)
    validated = validate_android_headless_runtime_downloads()
    asserts.equals(env, ANDROID_EMULATOR_SHA256, validated.emulator_sha256)
    asserts.equals(env, ANDROID_PLATFORM_TOOLS_SHA256, validated.platform_tools_sha256)
    asserts.equals(env, ANDROID_SYSTEM_IMAGE_SHA256, validated.system_image_sha256)
    asserts.equals(env, len(ANDROID_HEADLESS_RUNTIME_DEB_PACKAGES), len(validated.runtime_debs))
    for entry in validated.runtime_debs:
        asserts.equals(env, 64, len(entry.sha256))
    custom = validate_android_headless_runtime_downloads(
        system_image = struct(
            tag = "aosp_atd",
            abi = "x86_64",
            api_level = "35",
            revision = "r02",
            sha256 = ANDROID_SYSTEM_IMAGE_SHA256,
        ),
    )
    asserts.true(env, "x86_64-35_r02.zip" in custom.system_image_url)
    asserts.equals(env, validated.emulator_url, custom.emulator_url)
    asserts.equals(env, validated.platform_tools_url, custom.platform_tools_url)
    asserts.equals(env, validated.system_image_sha256, custom.system_image_sha256)
    return unittest.end(env)

def _bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_web_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in substitutions["{binding_import}"])
    asserts.equals(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.equals(env, "", substitutions["{binding_decl}"])
    asserts.false(env, "{harness_url_prologue}" in substitutions)
    return unittest.end(env)

def _bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_web_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.false(env, "package:integration_test/integration_test.dart" in substitutions["{binding_import}"])
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in substitutions["{binding_decl}"])
    asserts.equals(env, "_IntegrationTestBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.false(env, "{harness_url_prologue}" in substitutions)
    return unittest.end(env)

def _linux_bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in substitutions["{binding_import}"])
    asserts.equals(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.equals(env, "", substitutions["{binding_decl}"])
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in substitutions["{harness_url_prologue}"])
    return unittest.end(env)

def _linux_bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.false(env, "package:integration_test/integration_test.dart" in substitutions["{binding_import}"])
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in substitutions["{binding_decl}"])
    asserts.equals(env, "_IntegrationTestBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in substitutions["{harness_url_prologue}"])
    return unittest.end(env)

def _android_bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_android_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in substitutions["{binding_import}"])
    asserts.equals(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.equals(env, "", substitutions["{binding_decl}"])
    asserts.false(env, "{harness_url_prologue}" in substitutions)
    return unittest.end(env)

def _android_bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    substitutions = make_android_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.equals(env, _TEST_IMPORT, substitutions["{test_import}"])
    asserts.false(env, "package:integration_test/integration_test.dart" in substitutions["{binding_import}"])
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in substitutions["{binding_decl}"])
    asserts.equals(env, "_IntegrationTestBinding.ensureInitialized();", substitutions["{binding_init}"])
    asserts.false(env, "{harness_url_prologue}" in substitutions)
    return unittest.end(env)

def _android_default_keeps_no_sandbox_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {"no-sandbox": ""}, ANDROID_TEST_EXECUTION_REQUIREMENTS)
    return unittest.end(env)

_t0_test = unittest.make(_chrome_headless_shell_pins_test_impl)
_t1_test = unittest.make(_bootstrap_with_integration_test_pkg_test_impl)
_t2_test = unittest.make(_bootstrap_without_integration_test_pkg_test_impl)
_t3_test = unittest.make(_linux_headless_runtime_pins_test_impl)
_t4_test = unittest.make(_linux_bootstrap_with_integration_test_pkg_test_impl)
_t5_test = unittest.make(_linux_bootstrap_without_integration_test_pkg_test_impl)
_t6_test = unittest.make(_android_headless_runtime_pins_test_impl)
_t7_test = unittest.make(_android_bootstrap_with_integration_test_pkg_test_impl)
_t8_test = unittest.make(_android_bootstrap_without_integration_test_pkg_test_impl)
_t9_test = unittest.make(_android_default_keeps_no_sandbox_test_impl)

def flutter_integration_test_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
    )
