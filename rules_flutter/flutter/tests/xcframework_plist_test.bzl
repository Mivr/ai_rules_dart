"""Unit tests for the xcframework-level `Info.plist` renderer."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_ios_xcframework_plist.bzl", "IOS_DEVICE", "IOS_SIMULATOR", "xcframework_info_plist")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _entry(identifier, path):
    return (
        "            <key>LibraryIdentifier</key>\n" +
        "            <string>%s</string>\n" % identifier +
        "            <key>LibraryPath</key>\n" +
        "            <string>%s</string>\n" % path
    )

def _library_path_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["App", "FlutterPluginRegistrant", "some_plugin"]:
        text = xcframework_info_plist(name) + "\n"
        path = "%s.framework" % name
        asserts.true(env, _entry(IOS_DEVICE, path) in text, "device LibraryPath for %s" % name)
        asserts.true(env, _entry(IOS_SIMULATOR, path) in text, "simulator LibraryPath for %s" % name)
        asserts.equals(env, 2, text.count("<key>LibraryPath</key>"))
    return unittest.end(env)

_library_path_test = unittest.make(_library_path_test_impl)

def xcframework_plist_test_suite(name):
    """Declares the xcframework plist renderer tests.

    Args:
        name: The suite name.
    """
    small_unittest_suite(name, _library_path_test)
