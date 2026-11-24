"""Unit tests for SwiftPM target file selection (skip, classify, entry drops)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_clang.bzl", "swiftpm_clang_module_spec", "swiftpm_generated_modulemap_content")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")
load("//flutter/private:swiftpm_package.bzl", "swiftpm_hoist_package_root", "swiftpm_is_code_file", "swiftpm_select_target_files")
load("//flutter/private:swiftpm_paths.bzl", "swiftpm_normalize_relative_path")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_DOCS = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Docs",
    products: [.library(name: "Docs", targets: ["Docs"])],
    targets: [.target(name: "Docs")],
)
"""

_EXCLUDE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", exclude: ["Missing", "Ghost.swift", "Sub"])],
)
"""

_SOURCES = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: ["Real.swift", "Ghost.swift"])],
)
"""

_SOURCES_ALL_MISSING = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: ["Ghost.swift"])],
)
"""

_ESCAPE_EXCLUDE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", exclude: ["../Escape"])],
)
"""

_ESCAPE_SOURCES = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: [".."])],
)
"""

_EXCLUDE_RESOURCE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Docs",
    products: [.library(name: "Docs", targets: ["Docs"])],
    targets: [.target(name: "Docs", exclude: ["Assets.xcassets"])],
)
"""

_CODE_NAMES = ["a.c", "a.cc", "a.cpp", "a.cxx", "a.c++", "a.C", "a.cp", "a.m", "a.mm", "a.M", "a.h", "a.hh", "a.hpp", "a.hxx", "a.inc", "a.s", "a.S", "a.asm", "module.modulemap", "Custom.modulemap"]

# Every resource type SwiftPM processes without a `resources:` declaration,
# paired with the leading path segment the refusal must name.
_RESOURCE_PATHS = [
    ("Main.xib", "Main.xib"),
    ("Main.nib", "Main.nib"),
    ("Main.storyboard/Info.plist", "Main.storyboard"),
    ("Assets.xcassets/Contents.json", "Assets.xcassets"),
    ("Model.xcdatamodeld/model.xcdatamodel/contents", "Model.xcdatamodeld"),
    ("Model.xcdatamodel/contents", "Model.xcdatamodel"),
    ("Mapping.xcmappingmodel/xcmapping.xml", "Mapping.xcmappingmodel"),
    ("Shader.metal", "Shader.metal"),
    ("Strings.xcstrings/Localizable.xcstrings", "Strings.xcstrings"),
    ("PrivacyInfo.xcprivacy", "PrivacyInfo.xcprivacy"),
    ("Base.lproj/Localizable.strings", "Base.lproj"),
]

_SKIPPED_NAMES = ["README.md", "LICENSE", "notes.txt", "logo.png", "data.json", "Guide.markdown", "CHANGELOG", "Makefile", "Docs.swift"]

def _only_target(manifest):
    parsed = parse_swiftpm_package("pkg", manifest)
    if not parsed.ok:
        fail(parsed.error)
    return parsed.model.targets[0]

def _is_code_file_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in _CODE_NAMES:
        asserts.true(env, swiftpm_is_code_file(name))
    for name in _SKIPPED_NAMES:
        asserts.true(env, not swiftpm_is_code_file(name))
    return unittest.end(env)

_CLANG_TARGET = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", publicHeadersPath: "include")],
)
"""

_PUBLIC_HEADERS_DOT = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", publicHeadersPath: ".")],
)
"""

_PUBLIC_HEADERS_EMPTY = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", publicHeadersPath: "")],
)
"""

_PUBLIC_HEADERS_SLASH = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", publicHeadersPath: "include/")],
)
"""

_NANOPB = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "nanopb",
    products: [.library(name: "nanopb", targets: ["nanopb"])],
    targets: [.target(name: "nanopb", path: ".", sources: ["pb_common.c"], publicHeadersPath: "spm_headers")],
)
"""

_EXCLUDE_NORMALIZED = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", exclude: ["Resources/", "./Info.plist"])],
)
"""

_SOURCES_NORMALIZED = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: ["./Sub/"])],
)
"""

_PATH_DOT = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", path: ".")],
)
"""

_PATH_EMPTY = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", path: "")],
)
"""

def _select(identity, manifest, rel_dir, files, dirs):
    return swiftpm_select_target_files(identity, _only_target(manifest), rel_dir, files, dirs)

def _skips_non_code_files_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/README.md": True,
        rel_dir + "/LICENSE": True,
        rel_dir + "/notes.txt": True,
        rel_dir + "/logo.png": True,
        rel_dir + "/Docs.docc/Documentation.md": True,
    }
    dirs = {rel_dir + "/Docs.docc": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    asserts.equals(env, [], selected.c_srcs)
    asserts.equals(env, [], selected.public_hdrs)
    asserts.equals(env, None, selected.explicit_map)
    return unittest.end(env)

def _classifies_c_family_files_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/Shims"
    files = {
        rel_dir + "/Shims.c": True,
        rel_dir + "/extra.cc": True,
        rel_dir + "/include/Shims.h": True,
        rel_dir + "/include/detail.h": True,
        rel_dir + "/Internal/secret.h": True,
        rel_dir + "/include/module.modulemap": True,
        rel_dir + "/README.md": True,
    }
    dirs = {rel_dir + "/include": True, rel_dir + "/Internal": True}
    selected = _select("shims", _CLANG_TARGET, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.srcs)
    asserts.equals(env, [rel_dir + "/Shims.c", rel_dir + "/extra.cc"], selected.c_srcs)
    asserts.equals(env, [rel_dir + "/include/Shims.h", rel_dir + "/include/detail.h"], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Internal/secret.h"], selected.private_hdrs)
    asserts.equals(env, rel_dir + "/include/module.modulemap", selected.explicit_map)
    asserts.true(env, selected.map_in_include)
    return unittest.end(env)

def _root_headers_are_private_without_include_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.c": True,
        rel_dir + "/Docs.h": True,
        rel_dir + "/Sub/helper.h": True,
        rel_dir + "/module.modulemap": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.c"], selected.c_srcs)
    asserts.equals(env, [], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Docs.h", rel_dir + "/Sub/helper.h"], selected.private_hdrs)
    asserts.equals(env, rel_dir + "/module.modulemap", selected.explicit_map)
    asserts.true(env, not selected.map_in_include)
    return unittest.end(env)

def _spec_target(name, public_headers_path):
    return struct(name = name, public_headers_path = public_headers_path)

def _umbrella_header_order_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _spec_target("Shims", "include")
    rel_dir = "pkg/Sources/Shims"
    headers = [rel_dir + "/include/Shims.h", rel_dir + "/include/detail.h"]
    spec = swiftpm_clang_module_spec(target, "Shims", rel_dir, [rel_dir + "/Shims.c"], headers, None)
    asserts.true(env, spec.ok)
    asserts.equals(env, rel_dir + "/include/module.modulemap", spec.module_map)
    asserts.equals(env, rel_dir + "/include", spec.include_dir)
    asserts.equals(env, "Shims.h", spec.umbrella_header)
    nested = [rel_dir + "/include/Shims/Shims.h"]
    spec = swiftpm_clang_module_spec(target, "Shims", rel_dir, [rel_dir + "/Shims.c"], nested, None)
    asserts.true(env, spec.ok)
    asserts.equals(env, "Shims/Shims.h", spec.umbrella_header)
    other = [rel_dir + "/include/Other.h"]
    spec = swiftpm_clang_module_spec(target, "Shims", rel_dir, [rel_dir + "/Shims.c"], other, None)
    asserts.true(env, spec.ok)
    asserts.equals(env, None, spec.umbrella_header)
    asserts.equals(env, rel_dir + "/include/module.modulemap", spec.module_map)
    spec = swiftpm_clang_module_spec(target, "Shims", rel_dir, [rel_dir + "/Shims.c"], [], None)
    asserts.true(env, spec.ok)
    asserts.equals(env, None, spec.module_map)
    asserts.equals(env, None, spec.include_dir)
    return unittest.end(env)

def _generated_map_paths_are_map_relative_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "module Shims {\n    umbrella header \"Shims.h\"\n    export *\n}\n",
        swiftpm_generated_modulemap_content("Shims", "Shims.h", "pkg/Sources/Shims/include", ["pkg/Sources/Shims/include/Shims.h"]),
    )
    asserts.equals(
        env,
        "module Shims {\n    umbrella \".\"\n    header \"Other.h\"\n    header \"Sub/detail.h\"\n    export *\n}\n",
        swiftpm_generated_modulemap_content("Shims", None, "pkg/Sources/Shims/include", ["pkg/Sources/Shims/include/Other.h", "pkg/Sources/Shims/include/Sub/detail.h"]),
    )
    return unittest.end(env)

def _stray_module_map_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Sub/module.modulemap": True,
        rel_dir + "/Custom.modulemap": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    asserts.equals(env, None, selected.explicit_map)
    return unittest.end(env)

def _drops_missing_exclude_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_EXCLUDE)
    rel_dir = "pkg/Sources/P"
    files = {
        rel_dir + "/P.swift": True,
        rel_dir + "/Sub/Extra.swift": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("p", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/P.swift"], selected.srcs)
    return unittest.end(env)

def _drops_missing_sources_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_SOURCES)
    rel_dir = "pkg/Sources/P"
    files = {
        rel_dir + "/Real.swift": True,
        rel_dir + "/Other.swift": True,
    }
    selected = swiftpm_select_target_files("p", target, rel_dir, files, {})
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Real.swift"], selected.srcs)
    return unittest.end(env)

def _all_missing_sources_zero_files_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_SOURCES_ALL_MISSING)
    rel_dir = "pkg/Sources/P"
    files = {rel_dir + "/P.swift": True}
    selected = swiftpm_select_target_files("p", target, rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "reaches zero Swift files" in selected.error)
    return unittest.end(env)

def _escape_still_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/P"
    files = {rel_dir + "/P.swift": True}
    selected = swiftpm_select_target_files("p", _only_target(_ESCAPE_EXCLUDE), rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "escaping" in selected.error)
    selected = swiftpm_select_target_files("p", _only_target(_ESCAPE_SOURCES), rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "escaping" in selected.error)
    return unittest.end(env)

def _docc_swift_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Docs.docc/Snippet.swift": True,
    }
    dirs = {rel_dir + "/Docs.docc": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    return unittest.end(env)

def _refuses_implicit_resources_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    for resource, named in _RESOURCE_PATHS:
        files = {
            rel_dir + "/Docs.swift": True,
            rel_dir + "/" + resource: True,
        }
        selected = swiftpm_select_target_files("docs", target, rel_dir, files, {})
        asserts.true(env, not selected.ok)
        asserts.true(env, "no Bazel translation" in selected.error)
        asserts.true(env, "Point at a hand-written BUILD file with swift_package_build_files" in selected.error)
        asserts.true(env, "\"docs\"" in selected.error)
        asserts.true(env, "\"Docs\"" in selected.error)
        asserts.true(env, (rel_dir + "/" + named) in selected.error)

    # A resource directory is refused even when it holds no file yet.
    selected = swiftpm_select_target_files("docs", target, rel_dir, {rel_dir + "/Docs.swift": True}, {rel_dir + "/Empty.xcassets": True})
    asserts.true(env, not selected.ok)
    asserts.true(env, (rel_dir + "/Empty.xcassets") in selected.error)

    # `sources:` narrows compilation but does not hide a resource SwiftPM
    # still processes, while `exclude:` removes the resource and the refusal.
    narrowed = swiftpm_select_target_files("p", _only_target(_SOURCES), "pkg/Sources/P", {
        "pkg/Sources/P/Real.swift": True,
        "pkg/Sources/P/Assets.xcassets/Contents.json": True,
    }, {})
    asserts.true(env, not narrowed.ok)
    asserts.true(env, "pkg/Sources/P/Assets.xcassets" in narrowed.error)
    excluded = swiftpm_select_target_files("docs", _only_target(_EXCLUDE_RESOURCE), rel_dir, {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Assets.xcassets/Contents.json": True,
    }, {rel_dir + "/Assets.xcassets": True})
    asserts.true(env, excluded.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], excluded.srcs)
    excluded_flat = swiftpm_select_target_files("docs", _only_target(_EXCLUDE_RESOURCE), rel_dir, {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Assets.xcassets/Contents.json": True,
    }, {})
    asserts.true(env, excluded_flat.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], excluded_flat.srcs)

    # DocC catalog contents stay ignored even when they look like resources.
    docc = swiftpm_select_target_files("docs", target, rel_dir, {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Docs.docc/Assets.xcassets/Contents.json": True,
    }, {rel_dir + "/Docs.docc": True, rel_dir + "/Docs.docc/Assets.xcassets": True})
    asserts.true(env, docc.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], docc.srcs)
    return unittest.end(env)

def _normalizes_relative_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        (".", ""),
        ("./", ""),
        ("", ""),
        ("include/", "include"),
        ("./x", "x"),
        ("x/", "x"),
        ("x/../y", "y"),
        ("x/..", ""),
    ]
    for raw, expected in cases:
        normalized = swiftpm_normalize_relative_path(raw)
        asserts.true(env, normalized.ok)
        asserts.equals(env, expected, normalized.path)
    for raw in ["/absolute", "../x", "x/../../y"]:
        normalized = swiftpm_normalize_relative_path(raw)
        asserts.true(env, not normalized.ok)
        asserts.true(env, normalized.error != "")
    return unittest.end(env)

def _normalized_public_headers_path_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/Shims"
    files = {
        rel_dir + "/Shims.c": True,
        rel_dir + "/Shims.h": True,
        rel_dir + "/include/Other.h": True,
        rel_dir + "/include/Shims.h": True,
    }
    dirs = {rel_dir + "/include": True}
    for manifest in [_PUBLIC_HEADERS_DOT, _PUBLIC_HEADERS_EMPTY]:
        selected = _select("shims", manifest, rel_dir, files, dirs)
        asserts.true(env, selected.ok)
        asserts.equals(env, [rel_dir + "/Shims.h", rel_dir + "/include/Other.h", rel_dir + "/include/Shims.h"], selected.public_hdrs)
        asserts.equals(env, [], selected.private_hdrs)
    selected = _select("shims", _PUBLIC_HEADERS_SLASH, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/include/Other.h", rel_dir + "/include/Shims.h"], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Shims.h"], selected.private_hdrs)
    selected = _select("docs", _DOCS, rel_dir, {
        rel_dir + "/Docs.c": True,
        rel_dir + "/Docs.h": True,
        rel_dir + "/include/Other.h": True,
    }, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/include/Other.h"], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Docs.h"], selected.private_hdrs)

    # An explicit empty publicHeadersPath is the target directory, so the
    # generated map and its include path sit at the target root.
    target = _only_target(_PUBLIC_HEADERS_EMPTY)
    selected = _select("shims", _PUBLIC_HEADERS_EMPTY, rel_dir, files, dirs)
    spec = swiftpm_clang_module_spec(target, "Shims", rel_dir, selected.c_srcs, selected.public_hdrs, selected.explicit_map)
    asserts.true(env, spec.ok)
    asserts.equals(env, rel_dir + "/module.modulemap", spec.module_map)
    asserts.equals(env, rel_dir, spec.include_dir)
    asserts.equals(env, "Shims.h", spec.umbrella_header)
    return unittest.end(env)

def _normalized_exclude_and_sources_entries_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/P"
    files = {
        rel_dir + "/P.swift": True,
        rel_dir + "/Info.plist": True,
        rel_dir + "/Resources/Old.swift": True,
        rel_dir + "/Sub/Kept.swift": True,
    }
    dirs = {
        rel_dir + "/Resources": True,
        rel_dir + "/Sub": True,
    }
    selected = _select("p", _EXCLUDE_NORMALIZED, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/P.swift", rel_dir + "/Sub/Kept.swift"], selected.srcs)
    selected = _select("p", _SOURCES_NORMALIZED, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Sub/Kept.swift"], selected.srcs)
    return unittest.end(env)

def _target_path_spellings_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, _only_target(_DOCS).path)
    asserts.equals(env, ".", _only_target(_PATH_DOT).path)
    asserts.equals(env, "", _only_target(_PATH_EMPTY).path)
    asserts.equals(env, "", swiftpm_normalize_relative_path(_only_target(_PATH_DOT).path).path)
    asserts.equals(env, "", swiftpm_normalize_relative_path(_only_target(_PATH_EMPTY).path).path)
    return unittest.end(env)

def _unlisted_public_header_stays_public_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg"
    files = {
        rel_dir + "/pb.h": True,
        rel_dir + "/pb_common.c": True,
        rel_dir + "/pb_decode.c": True,
        rel_dir + "/spm_headers/pb.h": True,
        rel_dir + "/spm_headers/pb_extra.h": True,
    }
    selected = _select("nanopb", _NANOPB, rel_dir, files, {rel_dir + "/spm_headers": True})
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/pb_common.c"], selected.c_srcs)
    asserts.equals(env, [rel_dir + "/spm_headers/pb.h", rel_dir + "/spm_headers/pb_extra.h"], selected.public_hdrs)
    asserts.equals(env, [], selected.private_hdrs)
    return unittest.end(env)

_unlisted_public_header_stays_public_test = unittest.make(_unlisted_public_header_stays_public_test_impl)
_normalizes_relative_paths_test = unittest.make(_normalizes_relative_paths_test_impl)
_normalized_public_headers_path_test = unittest.make(_normalized_public_headers_path_test_impl)
_normalized_exclude_and_sources_entries_test = unittest.make(_normalized_exclude_and_sources_entries_test_impl)
_target_path_spellings_test = unittest.make(_target_path_spellings_test_impl)

def _fake_repo(files):
    """A mutable fake repository context over a dict of file path -> text."""
    state = {"files": dict(files)}

    def _children(path):
        prefix = "" if path == "." else path + "/"
        names = {}
        for full in state["files"]:
            if full.startswith(prefix):
                rest = full[len(prefix):]
                names[rest.split("/")[0]] = "/" in rest
        return [struct(basename = name, is_dir = is_dir) for name, is_dir in sorted(names.items())]

    def _rename(src, dst):
        moved = {}
        for full in state["files"]:
            if full == src or full.startswith(src + "/"):
                moved[full] = dst + full[len(src):]
        for old, new in moved.items():
            state["files"][new] = state["files"].pop(old)

    def _delete(path):
        for full in list(state["files"]):
            if full == path or full.startswith(path + "/"):
                state["files"].pop(full)

    return struct(
        state = state,
        path = lambda path: struct(readdir = lambda: _children(path)),
        rename = _rename,
        delete = _delete,
    )

def _hoist_files(revision):
    top = "BigInt-" + revision
    return {
        ".swiftpm_extract/" + top + "/Package.swift": "manifest",
        ".swiftpm_extract/" + top + "/Sources/BigInt/BigInt.swift": "code",
    }

def _hoist_strips_top_level_directory_test_impl(ctx):
    env = unittest.begin(ctx)
    for revision in ["63feef78" + "0" * 32, "a" * 40]:
        repo = _fake_repo(_hoist_files(revision))
        asserts.equals(env, "", swiftpm_hoist_package_root(repo, "bigint"))
        asserts.equals(env, ["Package.swift", "Sources/BigInt/BigInt.swift"], sorted(repo.state["files"].keys()))
    return unittest.end(env)

def _hoist_refuses_two_top_level_entries_test_impl(ctx):
    env = unittest.begin(ctx)
    files = _hoist_files("a" * 40)
    files[".swiftpm_extract/README.md"] = "x"
    error = swiftpm_hoist_package_root(_fake_repo(files), "bigint")
    asserts.true(env, "expected the archive to hold one top-level directory" in error, error)
    return unittest.end(env)

_hoist_strips_top_level_directory_test = unittest.make(_hoist_strips_top_level_directory_test_impl)
_hoist_refuses_two_top_level_entries_test = unittest.make(_hoist_refuses_two_top_level_entries_test_impl)
_is_code_file_test = unittest.make(_is_code_file_test_impl)
_skips_non_code_files_test = unittest.make(_skips_non_code_files_test_impl)
_classifies_c_family_files_test = unittest.make(_classifies_c_family_files_test_impl)
_root_headers_are_private_test = unittest.make(_root_headers_are_private_without_include_test_impl)
_umbrella_header_order_test = unittest.make(_umbrella_header_order_test_impl)
_generated_map_paths_are_map_relative_test = unittest.make(_generated_map_paths_are_map_relative_test_impl)
_stray_module_map_skipped_test = unittest.make(_stray_module_map_skipped_test_impl)
_drops_missing_exclude_test = unittest.make(_drops_missing_exclude_test_impl)
_drops_missing_sources_test = unittest.make(_drops_missing_sources_test_impl)
_all_missing_sources_zero_files_test = unittest.make(_all_missing_sources_zero_files_test_impl)
_escape_still_refused_test = unittest.make(_escape_still_refused_test_impl)
_docc_swift_skipped_test = unittest.make(_docc_swift_skipped_test_impl)
_refuses_implicit_resources_test = unittest.make(_refuses_implicit_resources_test_impl)

def swiftpm_package_test_suite(name):
    """Registers the target file selection unit tests."""
    small_unittest_suite(
        name + "_unit",
        _normalizes_relative_paths_test,
        _unlisted_public_header_stays_public_test,
        _normalized_public_headers_path_test,
        _normalized_exclude_and_sources_entries_test,
        _target_path_spellings_test,
        _is_code_file_test,
        _skips_non_code_files_test,
        _classifies_c_family_files_test,
        _root_headers_are_private_test,
        _umbrella_header_order_test,
        _generated_map_paths_are_map_relative_test,
        _stray_module_map_skipped_test,
        _drops_missing_exclude_test,
        _drops_missing_sources_test,
        _all_missing_sources_zero_files_test,
        _escape_still_refused_test,
        _docc_swift_skipped_test,
        _refuses_implicit_resources_test,
        _hoist_strips_top_level_directory_test,
        _hoist_refuses_two_top_level_entries_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
