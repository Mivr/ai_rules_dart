# BUILD file for the `package:webcrypto` pub archive, overlaid by the
# `http_archive` in rules_dart's MODULE.bazel. It compiles what the package's
# hook/build.dart compiles through src/CMakeLists.txt: the package's own C
# glue over the BoringSSL revision vendored in third_party/boringssl. The Dart
# bindings are generated against those exact headers, so no other BoringSSL
# would do.
#
# The vendored tree holds exactly the files sources.cmake lists, so globs
# select the same sources. Assembly is guarded per OS and architecture inside
# each file, so non-Windows builds take it all; Windows builds take none and
# define OPENSSL_NO_ASM, because Bazel's C++ rules cannot drive NASM. Both
# choices follow BoringSSL's own Bazel build.

load("@rules_cc//cc:cc_library.bzl", "cc_library")

_BORINGSSL = "third_party/boringssl/"

_COPTS = ["-DOPENSSL_SMALL"] + select({
    "@platforms//os:windows": [
        "-DOPENSSL_NO_ASM",
        "-DWIN32_LEAN_AND_MEAN",
        "-DNOMINMAX",
        "-D_HAS_EXCEPTIONS=0",
        "-D_CRT_SECURE_NO_WARNINGS",
        "-utf-8",
    ],
    # Only webcrypto_lookup_symbol and webcrypto_get_CBB_size are called from
    # Dart (they carry explicit default visibility); BoringSSL stays internal.
    "//conditions:default": ["-fvisibility=hidden"],
}) + select({
    # glibc hides pthread rwlocks without this; it must not be set on Apple.
    "@platforms//os:linux": ["-D_XOPEN_SOURCE=700"],
    "//conditions:default": [],
})

cc_library(
    name = "boringssl_crypto",
    srcs = glob([
        _BORINGSSL + "**/*.cc",
        _BORINGSSL + "**/*.h",
        _BORINGSSL + "**/*.inc",
    ]) + select({
        "@platforms//os:windows": [],
        "//conditions:default": glob([_BORINGSSL + "**/*.S"]),
    }),
    copts = _COPTS,
    cxxopts = select({
        "@platforms//os:windows": ["/std:c++17"],
        "//conditions:default": ["-std=c++17"],
    }),
    includes = [_BORINGSSL + "src/include"],
    linkopts = select({
        "@platforms//os:windows": [
            "-defaultlib:advapi32.lib",
            "-defaultlib:ws2_32.lib",
        ],
        "//conditions:default": ["-pthread"],
    }),
)

cc_library(
    name = "webcrypto",
    srcs = [
        "src/symbols.generated.c",
        "src/symbols.h",
        "src/webcrypto.c",
        "src/webcrypto.h",
    ],
    copts = _COPTS,
    visibility = ["@rules_dart//dart/ext/webcrypto:__pkg__"],
    deps = [":boringssl_crypto"],
    # Nothing in the shared library references the two exported entry points,
    # so keep their object file from being dropped at link time.
    alwayslink = True,
)
