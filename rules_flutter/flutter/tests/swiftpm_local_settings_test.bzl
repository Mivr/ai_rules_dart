"""Build-level fixture for SwiftPM target-local header search paths.

SwiftPM applies `cSettings: [.headerSearchPath(p)]` to the declaring target
only. The fixture builds a small C library from the same settings struct the
translator consumes, with `p` reached through `implementation_deps`. Its
public consumer builds; the private consumer includes a header under `p` and
must fail to build:

    bazel build //flutter/tests:swiftpm_local_settings_private_consumer

`entries.private_includes` is the translated location of the search path, so
this fixture fails to load when the translator puts `p` back in a propagating
`includes` entry.
"""

load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")
load("//flutter/private:swiftpm_settings.bzl", "swiftpm_target_setting_entries")

visibility(["//flutter/tests/..."])

_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "LocalSettings",
    products: [.library(name: "LocalSettings", targets: ["LocalSettings"])],
    targets: [.target(name: "LocalSettings", cSettings: [.headerSearchPath("detail"), .define("LOCAL_SETTINGS_DEFINE")])],
)
"""

_PACKAGE_DIR = "swiftpm_local_settings_fixture/LocalSettings"
_FIXTURE = "swiftpm_local_settings_fixture"

def swiftpm_local_settings_fixture(name):
    """Creates the target-local header search path build fixture.

    Args:
        name: The base Bazel target name.
    """
    parsed = parse_swiftpm_package("local_settings", _MANIFEST)
    entries = swiftpm_target_setting_entries(parsed.model.targets[0], _PACKAGE_DIR, "clang")
    private_paths = [entry.text for entry in entries.private_includes if entry.platforms == None]
    cc_library(
        name = name + "_private_headers",
        hdrs = [_PACKAGE_DIR + "/detail/config.h"],
        includes = private_paths,
        tags = ["manual"],
    )
    cc_library(
        name = name,
        srcs = [
            _PACKAGE_DIR + "/LocalSettings.c",
            _PACKAGE_DIR + "/detail/config.h",
        ],
        hdrs = [_PACKAGE_DIR + "/include/LocalSettings.h"],
        conlyopts = [entry.text for entry in entries.c_only if entry.platforms == None],
        includes = [_PACKAGE_DIR + "/include"],
        implementation_deps = [":" + name + "_private_headers"],
        tags = ["manual"],
    )
    cc_library(
        name = name + "_public_consumer",
        srcs = [_FIXTURE + "/public_consumer.c"],
        deps = [":" + name],
        tags = ["manual"],
    )
    cc_library(
        name = name + "_private_consumer",
        srcs = [_FIXTURE + "/private_consumer.c"],
        deps = [":" + name],
        tags = ["manual"],
    )
