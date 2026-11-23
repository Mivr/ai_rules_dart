"""Unit tests for a plugin manifest's sibling SwiftPM path dependencies."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple_deps.bzl",
    "select_apple_swiftpm_deps",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_LOCK_LABEL = "//app:pubspec.lock"

# The real firebase_auth 7.0.1 manifest. The sibling-only variant below
# drops the Firebase SDK url dependency and its product, leaving the path
# dependency this suite covers.
_FIREBASE_AUTH_MANIFEST = """// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Copyright 2024, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import PackageDescription

let libraryVersion = "7.0.1"
let firebaseSdkVersion: Version = "13.1.1"

let package = Package(
  name: "firebase_auth",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "firebase-auth", targets: ["firebase_auth"])
  ],
  dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: firebaseSdkVersion),
    .package(name: "firebase_core", path: "../firebase_core"),
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "firebase_auth",
      dependencies: [
        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
        .product(name: "firebase-core", package: "firebase_core"),
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      resources: [
        .process("Resources")
      ],
      cSettings: [
        .define("LIBRARY_VERSION", to: "\\\"\\(libraryVersion)\\\""),
        .define("LIBRARY_NAME", to: "\\\"flutter-fire-auth\\\""),
      ]
    )
  ]
)
"""

_FIREBASE_AUTH_SIBLING_MANIFEST = _FIREBASE_AUTH_MANIFEST.replace(
    '    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: firebaseSdkVersion),\n',
    "",
).replace(
    '        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),\n',
    "",
)

_GOOGLE_MOBILE_ADS_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "google_mobile_ads",
  platforms: [
    .iOS("12.0")
  ],
  products: [
    .library(name: "google-mobile-ads", targets: ["google_mobile_ads"])
  ],
  dependencies: [
    .package(name: "webview_flutter_wkwebview", path: "../webview_flutter_wkwebview"),
  ],
  targets: [
    .target(
      name: "google_mobile_ads",
      dependencies: [
        .product(name: "webview_flutter_wkwebview", package: "webview_flutter_wkwebview"),
      ]
    )
  ]
)
"""

_MANY_PRODUCTS_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sample_plugin",
  products: [
    .library(name: "sample_plugin", targets: ["sample_plugin"])
  ],
  dependencies: [
    .package(name: "firebase_core", path: "../firebase_core"),
  ],
  targets: [
    .target(
      name: "sample_plugin",
      dependencies: [
        .product(name: "Alpha", package: "Firebase_Core"),
        .product(name: "Beta", package: "firebase_core"),
        .product(name: "Alpha", package: "firebase_core"),
        .product(name: "gamma", package: "FIREBASE_CORE"),
      ]
    )
  ]
)
"""

_CONDITIONED_PATH_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sample_plugin",
  products: [
    .library(name: "sample_plugin", targets: ["sample_plugin"])
  ],
  dependencies: [
    .package(name: "firebase_core", path: "../firebase_core"),
  ],
  targets: [
    .target(
      name: "sample_plugin",
      dependencies: [
        .product(name: "firebase_core", package: "firebase_core", condition: .when(platforms: [.macOS])),
      ]
    )
  ]
)
"""

_FRAMEWORK_PATH_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sample_plugin",
  products: [
    .library(name: "sample_plugin", targets: ["sample_plugin"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "sample_plugin",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ]
    )
  ]
)
"""

_REMOTE_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sample_plugin",
  products: [
    .library(name: "sample_plugin", targets: ["sample_plugin"])
  ],
  dependencies: [
    .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
    .package(name: "IdentityPkg", id: "identity-pkg"),
  ],
  targets: [
    .target(
      name: "sample_plugin",
      dependencies: [
        .product(name: "BigInt", package: "BigInt"),
        .product(name: "IdentityProduct", package: "identitypkg"),
      ]
    )
  ]
)
"""

def _path_manifest(package_name, path):
    """A one-target manifest declaring one path dependency."""
    return """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sample_plugin",
  products: [
    .library(name: "sample_plugin", targets: ["sample_plugin"])
  ],
  dependencies: [
    .package(name: "{package}", path: "{path}"),
  ],
  targets: [
    .target(
      name: "sample_plugin",
      dependencies: [
        .product(name: "Something", package: "{package}"),
      ]
    )
  ]
)
""".format(package = package_name, path = path)

def _pins(lock_packages, pinned = [], resolved = "//app:Package.resolved", lock_label = _LOCK_LABEL):
    """The pin struct the plugin manifest reader receives."""
    return struct(
        resolved = resolved,
        pinned = pinned,
        unpinned = {},
        hub = "deps",
        lock_packages = lock_packages,
        lock_label = lock_label,
    )

def _select(manifest, platform = "ios", package_name = "sample_plugin", pins = None, manifest_dir = ""):
    """Run the resolver on one manifest and platform."""
    if pins == None:
        pins = _pins([])
    if not manifest_dir:
        manifest_dir = platform + "/" + package_name
    return select_apple_swiftpm_deps(
        package_name,
        manifest,
        manifest_dir,
        [manifest_dir + "/Sources/" + package_name],
        platform,
        pins,
    )

_FIREBASE_LOCK = ["firebase_auth", "firebase_core", "flutter"]

def _firebase_auth_sibling_path_ios_test_impl(ctx):
    """firebase_auth's `../firebase_core` links firebase_core's iOS library."""
    env = unittest.begin(ctx)
    selected = _select(
        _FIREBASE_AUTH_SIBLING_MANIFEST,
        package_name = "firebase_auth",
        pins = _pins(_FIREBASE_LOCK),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__firebase_core//:firebase_core_apple_ios"], selected.labels)
    return unittest.end(env)

def _firebase_auth_sibling_path_macos_test_impl(ctx):
    """A darwin manifest links firebase_core's macOS library."""
    env = unittest.begin(ctx)
    selected = _select(
        _FIREBASE_AUTH_SIBLING_MANIFEST,
        platform = "macos",
        package_name = "firebase_auth",
        pins = _pins(_FIREBASE_LOCK),
        manifest_dir = "darwin/firebase_auth",
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__firebase_core//:firebase_core_apple_macos"], selected.labels)
    return unittest.end(env)

def _google_mobile_ads_sibling_path_test_impl(ctx):
    """google_mobile_ads' `../webview_flutter_wkwebview` links its iOS library."""
    env = unittest.begin(ctx)
    selected = _select(
        _GOOGLE_MOBILE_ADS_MANIFEST,
        package_name = "google_mobile_ads",
        pins = _pins(["google_mobile_ads", "webview_flutter_wkwebview", "flutter"]),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__webview_flutter_wkwebview//:webview_flutter_wkwebview_apple_ios"], selected.labels)
    return unittest.end(env)

def _every_product_of_a_path_declaration_dedupes_test_impl(ctx):
    """Every product of one path declaration maps to one label, deduplicated."""
    env = unittest.begin(ctx)
    selected = _select(
        _MANY_PRODUCTS_MANIFEST,
        pins = _pins(["sample_plugin", "firebase_core", "flutter"]),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__firebase_core//:firebase_core_apple_ios"], selected.labels)
    return unittest.end(env)

def _path_to_an_unlocked_package_refuses_test_impl(ctx):
    """A path package missing from the lock gets message 7."""
    env = unittest.begin(ctx)
    selected = _select(
        _path_manifest("NotLocked", "../NotLocked"),
        pins = _pins(["sample_plugin", "other"]),
    )
    asserts.true(env, not selected.ok)
    asserts.equals(
        env,
        'Flutter plugin "sample_plugin": its ios/sample_plugin/Package.swift depends on local package "NotLocked" (path "../NotLocked"), which is not an Apple plugin in the hub\'s pubspec.lock (//app:pubspec.lock).',
        selected.error,
    )
    return unittest.end(env)

def _escaping_and_absolute_paths_refuse_test_impl(ctx):
    """`../../x`, `.` and an absolute path all get message 7."""
    env = unittest.begin(ctx)
    cases = [
        ("x", "../../x"),
        ("x", "."),
        ("x", "/tmp/x"),
        ("x", "../x/y"),
        ("x", ".."),
    ]
    for package_name, path in cases:
        selected = _select(
            _path_manifest(package_name, path),
            pins = _pins(["sample_plugin", "x"]),
        )
        asserts.true(env, not selected.ok)
        asserts.true(env, 'depends on local package "x"' in selected.error)
        asserts.true(env, '(path "' + path + '")' in selected.error)
        asserts.true(env, "//app:pubspec.lock" in selected.error)
    return unittest.end(env)

def _path_to_the_plugin_itself_refuses_test_impl(ctx):
    """A path naming the depending plugin gets message 7."""
    env = unittest.begin(ctx)
    selected = _select(
        _path_manifest("sample_plugin", "../sample_plugin"),
        pins = _pins(["sample_plugin", "firebase_core"]),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, 'depends on local package "sample_plugin"' in selected.error)
    asserts.true(env, '(path "../sample_plugin")' in selected.error)
    return unittest.end(env)

def _locked_package_without_apple_sources_still_labels_test_impl(ctx):
    """A locked path package gets its label even without a resolved file."""
    env = unittest.begin(ctx)
    selected = _select(
        _path_manifest("plain_dart_pkg", "../plain_dart_pkg"),
        pins = _pins(["sample_plugin", "plain_dart_pkg"], resolved = ""),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__plain_dart_pkg//:plain_dart_pkg_apple_ios"], selected.labels)
    return unittest.end(env)

def _conditioned_path_product_is_dropped_test_impl(ctx):
    """A path product whose condition excludes the platform is dropped."""
    env = unittest.begin(ctx)
    ios = _select(
        _CONDITIONED_PATH_MANIFEST,
        pins = _pins(["sample_plugin", "firebase_core"]),
    )
    asserts.true(env, ios.ok)
    asserts.equals(env, [], ios.labels)
    macos = _select(
        _CONDITIONED_PATH_MANIFEST,
        platform = "macos",
        pins = _pins(["sample_plugin", "firebase_core"]),
    )
    asserts.true(env, macos.ok)
    asserts.equals(env, ["@deps__firebase_core//:firebase_core_apple_macos"], macos.labels)
    return unittest.end(env)

def _flutterframework_path_product_is_skipped_test_impl(ctx):
    """The template's FlutterFramework path package is still skipped."""
    env = unittest.begin(ctx)
    selected = _select(
        _FRAMEWORK_PATH_MANIFEST,
        pins = _pins(["sample_plugin", "flutterframework"]),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)
    return unittest.end(env)

def _url_and_id_products_still_resolve_test_impl(ctx):
    """Remote url and id dependencies keep their existing labels."""
    env = unittest.begin(ctx)
    selected = _select(
        _REMOTE_MANIFEST,
        pins = _pins(["sample_plugin"], pinned = ["bigint", "identity-pkg"]),
    )
    asserts.true(env, selected.ok)
    asserts.equals(
        env,
        [
            "@deps__swiftpm-bigint//:BigInt",
            "@deps__swiftpm-identity-pkg//:IdentityProduct",
        ],
        selected.labels,
    )
    return unittest.end(env)

def _unpinned_url_product_still_refuses_test_impl(ctx):
    """An unpinned url dependency keeps its existing refusal."""
    env = unittest.begin(ctx)
    selected = _select(
        _REMOTE_MANIFEST,
        pins = _pins(["sample_plugin"], pinned = []),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "sample_plugin" in selected.error)
    asserts.true(env, "BigInt" in selected.error)
    asserts.true(env, "Package.resolved" in selected.error)
    return unittest.end(env)

_firebase_auth_sibling_path_ios_test = unittest.make(_firebase_auth_sibling_path_ios_test_impl)
_firebase_auth_sibling_path_macos_test = unittest.make(_firebase_auth_sibling_path_macos_test_impl)
_google_mobile_ads_sibling_path_test = unittest.make(_google_mobile_ads_sibling_path_test_impl)
_every_product_of_a_path_declaration_dedupes_test = unittest.make(_every_product_of_a_path_declaration_dedupes_test_impl)
_path_to_an_unlocked_package_refuses_test = unittest.make(_path_to_an_unlocked_package_refuses_test_impl)
_escaping_and_absolute_paths_refuse_test = unittest.make(_escaping_and_absolute_paths_refuse_test_impl)
_path_to_the_plugin_itself_refuses_test = unittest.make(_path_to_the_plugin_itself_refuses_test_impl)
_locked_package_without_apple_sources_still_labels_test = unittest.make(_locked_package_without_apple_sources_still_labels_test_impl)
_conditioned_path_product_is_dropped_test = unittest.make(_conditioned_path_product_is_dropped_test_impl)
_flutterframework_path_product_is_skipped_test = unittest.make(_flutterframework_path_product_is_skipped_test_impl)
_url_and_id_products_still_resolve_test = unittest.make(_url_and_id_products_still_resolve_test_impl)
_unpinned_url_product_still_refuses_test = unittest.make(_unpinned_url_product_still_refuses_test_impl)

def flutter_pub_apple_deps_test_suite(name):
    """Registers the sibling plugin path dependency unit tests."""
    small_unittest_suite(
        name + "_unit",
        _firebase_auth_sibling_path_ios_test,
        _firebase_auth_sibling_path_macos_test,
        _google_mobile_ads_sibling_path_test,
        _every_product_of_a_path_declaration_dedupes_test,
        _path_to_an_unlocked_package_refuses_test,
        _escaping_and_absolute_paths_refuse_test,
        _path_to_the_plugin_itself_refuses_test,
        _locked_package_without_apple_sources_still_labels_test,
        _conditioned_path_product_is_dropped_test,
        _flutterframework_path_product_is_skipped_test,
        _url_and_id_products_still_resolve_test,
        _unpinned_url_product_still_refuses_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
