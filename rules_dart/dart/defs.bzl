"""Rules for building, testing, and analyzing Dart code.

Load this file from your BUILD files to access the following rules:

- `dart_library`: Collects Dart sources and propagates dependency information. Does not compile.
- `dart_package_metadata`: Declares a Dart package's name and language version once, for every rule that builds part of it.
- `dart_source_set`: Assembles Dart sources (hand-written + generated) into one directory.
- `dart_binary`: Compiles a Dart application (`exe`, `aot-snapshot`, `kernel`, or `jit-snapshot`).
- `dart_test`: Runs a Dart test file using the Dart VM.
- `dart_analysis_options`: An `analysis_options.yaml` plus the packages its `include:` directives resolve against.
- `dart_analysis_config`: Lists every `dart_analysis_options` for the `dart_analyze` aspect (`//dart:analyze.bzl`), which runs `dart analyze` and the `dart format` check under `bazel test`.
- `dart_analysis_test`: Runs the `dart_analyze` aspect's checks on named targets `bazel test //...` cannot reach (tagged `manual`, fixtures).
- `dart_fix`: Applies `dart fix` to a target's own sources via `bazel run`, under the `dart_analyze` aspect's options.
- `dart_format`: Formats workspace files via `bazel run`, under the options the `dart_analyze` aspect's format check applies.
- `dart_js_binary`: Compiles a Dart web application to JavaScript.
- `dart_wasm_binary`: Compiles a Dart web application to WebAssembly.
- `dart_build_runner`: Builds a Dart package's generated files with the `build_runner` builders of the lock, byte for byte what `dart run build_runner build` writes.
- `build_runner_sdk_summary`: The SDK summary `dart_build_runner` needs for a package that imports Flutter.
- `dart_code_asset`: Binds a native dynamic library — a Bazel-built `cc_shared_library` or a pinned prebuilt file — to a Dart code-asset id, for a `dart_library`'s `code_assets` (or a `dart_test`/`dart_binary`'s).
- `dart_link_hook`: Runs packages' `hook/link.dart` over a `dart_binary`'s recorded uses and collects the data assets they emit.
"""

load("@dart_projects//:index.bzl", "PROJECTS")
load("//dart:providers.bzl", _DartCodeAssetInfo = "DartCodeAssetInfo")
load("//dart/build_runner/private:build_runner.bzl", _build_runner_sdk_summary = "build_runner_sdk_summary", _dart_build_runner = "dart_build_runner")
load("//dart/private:dart_analysis_options.bzl", _dart_analysis_options = "dart_analysis_options")
load("//dart/private:dart_analysis_test.bzl", _dart_analysis_test = "dart_analysis_test")
load("//dart/private:dart_analyze_aspect.bzl", _dart_analysis_config = "dart_analysis_config")
load("//dart/private:dart_binary.bzl", _dart_binary = "dart_binary")
load("//dart/private:dart_code_asset.bzl", _dart_code_asset = "dart_code_asset")
load("//dart/private:dart_fix.bzl", _dart_fix = "dart_fix")
load("//dart/private:dart_format.bzl", _dart_format = "dart_format")
load("//dart/private:dart_library.bzl", _dart_library = "dart_library")
load("//dart/private:dart_link_hook.bzl", _dart_link_hook = "dart_link_hook")
load("//dart/private:dart_package_member.bzl", _dart_package_member = "dart_package_member")
load("//dart/private:dart_package_metadata.bzl", _dart_package_metadata = "dart_package_metadata")
load("//dart/private:dart_test.bzl", _dart_test = "dart_test")
load("//dart/private:dart_web_application.bzl", _dart_js_binary = "dart_js_binary", _dart_wasm_binary = "dart_wasm_binary")
load("//dart/private:project_defaults.bzl", "project_identity", "project_language_version", "project_of", "project_test_dir", "project_test_files")
load("//dart/private:source_set.bzl", _dart_source_set = "dart_source_set")

visibility("public")

# The project defaults of a target in a project's own package (see
# `project_defaults.bzl`); what a target states wins.

def dart_library(name, **kwargs):
    """A `dart_library`; in a project's package it compiles with the pubspec's language version by default.

    Args:
      name: The target's name.
      **kwargs: The `dart_library` rule's attributes.
    """
    project_language_version(kwargs, project_of(PROJECTS))
    _dart_library(name = name, **kwargs)

def dart_binary(name, **kwargs):
    """A `dart_binary`; in a project's package it is a member of the pubspec's package by default.

    Args:
      name: The target's name.
      **kwargs: The `dart_binary` rule's attributes.
    """
    project_identity(kwargs, project_of(PROJECTS))
    _dart_binary(name = name, **kwargs)

def dart_test(name, **kwargs):
    """A `dart_test`; in a project's package it runs as under `dart test` by default.

    It is a member of the pubspec's package, runs in the project's directory
    (`pubspec`), and has the files under the project's `test/` as `data`.

    Args:
      name: The target's name.
      **kwargs: The `dart_test` rule's attributes.
    """
    project = project_of(PROJECTS)
    project_identity(kwargs, project)
    project_test_dir(kwargs, project)
    project_test_files(kwargs, project, "dart_test")
    _dart_test(name = name, **kwargs)

dart_package_member = _dart_package_member
dart_package_metadata = _dart_package_metadata
dart_source_set = _dart_source_set
dart_analysis_options = _dart_analysis_options
dart_analysis_config = _dart_analysis_config
dart_analysis_test = _dart_analysis_test
dart_fix = _dart_fix
dart_format = _dart_format
dart_js_binary = _dart_js_binary
dart_wasm_binary = _dart_wasm_binary
dart_build_runner = _dart_build_runner
build_runner_sdk_summary = _build_runner_sdk_summary
dart_code_asset = _dart_code_asset
dart_link_hook = _dart_link_hook
DartCodeAssetInfo = _DartCodeAssetInfo
