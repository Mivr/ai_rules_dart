"""Unit tests for the `flutter.pub(ios_plugin_defines = ...)` helpers.

The helpers are pure: the extension side takes the lock's package names and
the spoke side takes detected source directories, so these tests drive them
with fake input. They pin the exact messages for a stale key, a malformed
entry, a package with nothing to compile and a package an overlay replaces.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_plugin_defines.bzl",
    "ios_plugin_defines_lock_error",
    "plugin_defines_apple_error",
    "plugin_defines_overlay_error",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_PLUGIN = "permission_handler_apple"

def _lock_error_test_impl(ctx):
    """Keys must be locked packages; entries must be names or NAME=VALUE."""
    env = unittest.begin(ctx)

    asserts.equals(env, "", ios_plugin_defines_lock_error({}, []))
    asserts.equals(
        env,
        "",
        ios_plugin_defines_lock_error({_PLUGIN: ["PERMISSION_CAMERA"]}, [_PLUGIN]),
    )
    asserts.equals(
        env,
        'flutter.pub(ios_plugin_defines = ...): key "ghost" is not a ' +
        "package in the lock. Name a locked package, or remove the entry.",
        ios_plugin_defines_lock_error({"ghost": ["PERMISSION_CAMERA"]}, [_PLUGIN]),
    )

    expected_sdk = (
        'flutter.pub(ios_plugin_defines = ...): key "integration_test" is a Flutter SDK ' +
        "package; Flutter SDK packages are not configurable through ios_plugin_defines. " +
        "Remove the entry."
    )
    sdk_lock = [_PLUGIN, "integration_test"]
    asserts.equals(
        env,
        expected_sdk,
        ios_plugin_defines_lock_error({"integration_test": ["FOO=1"]}, sdk_lock, ["integration_test"]),
    )
    asserts.equals(
        env,
        expected_sdk,
        ios_plugin_defines_lock_error({"integration_test": [""]}, sdk_lock, {"integration_test": True}),
    )
    asserts.equals(
        env,
        'flutter.pub(ios_plugin_defines = ...): key "ghost" is not a package in the lock. ' +
        "Name a locked package, or remove the entry.",
        ios_plugin_defines_lock_error({"ghost": ["A"], "integration_test": ["A"]}, sdk_lock, ["integration_test"]),
    )
    asserts.equals(
        env,
        expected_sdk,
        ios_plugin_defines_lock_error({"zebra": ["A"], "integration_test": ["A"]}, sdk_lock, ["integration_test"]),
    )

    expected_entry_error = (
        'flutter.pub(ios_plugin_defines = ...): "' + _PLUGIN + '" lists ' +
        '"%s", which is not a preprocessor name or NAME=VALUE. Use a name ' +
        "such as PERMISSION_CAMERA, optionally followed by =VALUE."
    )
    for entry in ["", "=1", "A B", "1ABC"]:
        asserts.equals(
            env,
            expected_entry_error % entry,
            ios_plugin_defines_lock_error({_PLUGIN: [entry]}, [_PLUGIN]),
        )
    asserts.equals(
        env,
        "",
        ios_plugin_defines_lock_error({_PLUGIN: ["A=B=C"]}, [_PLUGIN]),
    )

    return unittest.end(env)

_lock_error_test = unittest.make(_lock_error_test_impl)

def _apple_error_test_impl(ctx):
    """A list with no Apple sources fails; either platform's sources pass."""
    env = unittest.begin(ctx)

    expected = (
        'flutter.pub(ios_plugin_defines = ...): "' + _PLUGIN + '" has no ' +
        "iOS or macOS Apple sources, so its defines reach nothing. Remove " +
        "the entry."
    )
    asserts.equals(env, expected, plugin_defines_apple_error(_PLUGIN, ["A"], [], []))
    asserts.equals(env, "", plugin_defines_apple_error(_PLUGIN, [], [], []))
    asserts.equals(env, "", plugin_defines_apple_error(_PLUGIN, ["A"], ["macos/Classes"], []))
    asserts.equals(env, "", plugin_defines_apple_error(_PLUGIN, ["A"], [], ["ios/Classes"]))

    return unittest.end(env)

_apple_error_test = unittest.make(_apple_error_test_impl)

def _overlay_error_test_impl(ctx):
    """A list under an overlay fails; an empty list or no overlay passes."""
    env = unittest.begin(ctx)

    expected = (
        'flutter.pub(ios_plugin_defines = ...): "' + _PLUGIN + '" uses an ' +
        "overlay BUILD, so the generated Apple targets do not receive its " +
        "defines. Remove the entry or pass the flags in the overlay."
    )
    asserts.equals(env, expected, plugin_defines_overlay_error(_PLUGIN, ["A"], True))
    asserts.equals(env, "", plugin_defines_overlay_error(_PLUGIN, [], True))
    asserts.equals(env, "", plugin_defines_overlay_error(_PLUGIN, ["A"], False))

    return unittest.end(env)

_overlay_error_test = unittest.make(_overlay_error_test_impl)

def flutter_pub_plugin_defines_test_suite(name):
    """Defines the plugin-defines helper unit tests.

    Args:
        name: Name of the test suite.
    """
    small_unittest_suite(
        name,
        _lock_error_test,
        _apple_error_test,
        _overlay_error_test,
    )
