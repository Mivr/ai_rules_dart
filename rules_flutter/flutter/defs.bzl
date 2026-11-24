"""Core rules for building Flutter applications.

This is the main entry point for rules_flutter. It exports platform-agnostic
rules that compile Dart code, bundle assets, and run tests.

## Recommended (start here)

- `flutter_application`: Compiles Dart code (kernel + AOT) and bundles assets.
    This is the primary rule — it produces a `FlutterApplicationInfo` provider
    that platform-specific packaging rules consume.
- `flutter_library`: Collects Flutter Dart sources into a reusable
    dependency. Wire into `flutter_application` via `deps`. What the app
    bundles comes from its `pubspec.yaml`, as `flutter build` reads it.
- `flutter_plugin`: Declares a Flutter plugin with optional Dart registration
    class and/or native shared library dependencies.
- `dart_defines`: Dart environment defines from `.json`/`.env` files, `-D`
    flagfiles and values, for `flutter_application.dart_defines`. Applications
    naming the same target share their debug modules.
- `flutter_test`: Runs Flutter widget tests using the flutter_tester runtime.
- `flutter_prebuilt_test`: Runs an already built test kernel under the same
    flutter_tester runtime, for custom compile pipelines that feed it a
    `flutter_test`'s output groups or their own kernel.
- `flutter_integration_test`: Runs end-to-end Flutter integration tests inside
    a real platform app (e.g. `platform = "web"` in headless Chrome).

## Advanced / Low-Level

Most users don't need these directly. `flutter_application` composes them
internally. They are exported for advanced use cases like custom pipelines.

- `flutter_kernel_target`: Runs the Flutter frontend compiler to produce a
    kernel .dill file from Dart sources.
- `flutter_aot_target`: Runs gen_snapshot to AOT-compile a kernel .dill into
    native code (ELF .so or Mach-O dylib).
- `flutter_pub_packages`: Every package of a pub lock, for an app's
    `pub_packages`. A Flutter hub declares one as `@<hub>//packages`.

## Platform packaging

After `flutter_application`, use platform-specific rules to produce runnable
artifacts:

- `@rules_flutter//flutter:macos.bzl` — `flutter_macos_app` + composable rules
- `@rules_flutter//flutter:ios.bzl` — `flutter_ios_app` + composable rules
- `@rules_flutter//flutter:linux.bzl` — `flutter_linux_app` + composable rules
- `@rules_flutter//flutter:windows.bzl` — `flutter_windows_app` + composable rules
- `@rules_flutter//flutter:web.bzl` — `flutter_web_app` + composable rules (takes source directly, not a flutter_application target)
"""

load("@flutter_l10n//:index.bzl", "L10N_PROJECTS")
load("//flutter/private:flutter_aot_target.bzl", _flutter_aot_target = "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", _flutter_application = "flutter_application")
load("//flutter/private:flutter_bundle.bzl", "project_pub_packages", _flutter_pub_packages = "flutter_pub_packages")
load("//flutter/private:flutter_defines_files.bzl", _dart_defines = "dart_defines")
load("//flutter/private:flutter_gen_l10n.bzl", "l10n_attach", "project_language_version")
load("//flutter/private:flutter_integration_test.bzl", _flutter_integration_test = "flutter_integration_test")
load("//flutter/private:flutter_kernel_target.bzl", _flutter_kernel_target = "flutter_kernel_target")
load("//flutter/private:flutter_library.bzl", _flutter_library = "flutter_library")
load("//flutter/private:flutter_native_library.bzl", _flutter_native_library = "flutter_native_library")
load("//flutter/private:flutter_plugin.bzl", _flutter_plugin = "flutter_plugin")
load("//flutter/private:flutter_prebuilt_test.bzl", _flutter_prebuilt_test = "flutter_prebuilt_test")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test")

visibility("public")

flutter_aot_target = _flutter_aot_target

def flutter_application(name, package_name = "", defines_files = None, define_flagfiles = None, **kwargs):
    """Compiles a Flutter application with stable package: URIs for hot reload.

    Auto-derives `package_name` from the rule name if not explicitly set.
    This ensures the kernel uses `package:<name>/main.dart` URIs instead of
    sandbox `file:///` URIs, which is required for hot reload incremental
    deltas to match the running application's library URIs.

    `pubspec` defaults to the package's `pubspec.yaml`: it says what the
    asset bundle holds, as it does for `flutter build`, and `pubspec_srcs`
    lists the files it names.

    `defines_files` and `define_flagfiles` are a spelling of `dart_defines`:
    they become a `dart_defines` target named `<name>_dart_defines`. Two
    applications share their debug modules only when they name the same
    `dart_defines` target, so name one yourself where applications share
    their defines.

    Args:
        name: Name of the `flutter_application` target; also the default Dart package name.
        package_name: Dart package name (from pubspec.yaml). Defaults to name.
        defines_files: Files of Dart environment defines in `.json` or `.env`
            format (see `dart_defines.srcs`).
        define_flagfiles: Files of already-spelled `-Dname=value` lines (see
            `dart_defines.flagfiles`).
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    if defines_files or define_flagfiles:
        if kwargs.get("dart_defines"):
            fail("%s: set `dart_defines` or `defines_files`/`define_flagfiles`, not both" % name)
        _dart_defines(
            name = name + "_dart_defines",
            srcs = defines_files or [],
            flagfiles = define_flagfiles or [],
            tags = ["manual"],
            testonly = kwargs.get("testonly"),
            visibility = ["//visibility:private"],
        )
        kwargs["dart_defines"] = ":" + name + "_dart_defines"
    if "pubspec" not in kwargs and native.glob(["pubspec.yaml"], allow_empty = True):
        kwargs["pubspec"] = "pubspec.yaml"
    project_language_version(kwargs, L10N_PROJECTS)
    l10n_attach(name, kwargs, L10N_PROJECTS)
    project_pub_packages(kwargs)
    _flutter_application(
        name = name,
        package_name = package_name or name,
        **kwargs
    )

# Dart environment defines from `.json`/`.env` files, `-D` flagfiles and
# values, for `flutter_application.dart_defines`.
dart_defines = _dart_defines

flutter_integration_test = _flutter_integration_test
flutter_kernel_target = _flutter_kernel_target

def flutter_library(name, **kwargs):
    """Collects Flutter Dart sources into a reusable dependency.

    In a package with an `l10n.yaml`, a library whose `srcs` hold files under
    `lib/` depends on what gen-l10n writes for the package, as `flutter build`
    generates it: the files `l10n.yaml` and the `.arb` files say, at the paths
    they say. A copy of those files in the source tree is left out of `srcs`.

    A legacy macro over the `flutter_library` rule (the kind `bazel query`
    reports): its arguments are the rule's attributes, listed in the README
    under `flutter_library`.

    Args:
        name: Name of the `flutter_library` target.
        **kwargs: The `flutter_library` rule's attributes (`srcs`, `deps`,
            `package_name`, `pubspec`, ...), forwarded to it.
    """
    project_language_version(kwargs, L10N_PROJECTS)
    l10n_attach(name, kwargs, L10N_PROJECTS)
    _flutter_library(name = name, **kwargs)

flutter_native_library = _flutter_native_library
flutter_plugin = _flutter_plugin
flutter_prebuilt_test = _flutter_prebuilt_test
flutter_pub_packages = _flutter_pub_packages

def flutter_test(name, **kwargs):
    """Runs Flutter widget tests using the flutter_tester runtime.

    In a package with an `l10n.yaml`, the test depends on what gen-l10n
    writes for the package, as `flutter test` generates it.

    A legacy macro over the `flutter_test` rule (the kind `bazel query`
    reports): its arguments are the rule's attributes, listed in the README
    under `flutter_test`.

    Args:
        name: Name of the `flutter_test` target.
        **kwargs: The `flutter_test` rule's attributes (`main`, `srcs`,
            `deps`, `pubspec`, ...), forwarded to it.
    """
    project_language_version(kwargs, L10N_PROJECTS)
    l10n_attach(name, kwargs, L10N_PROJECTS, always = True)
    project_pub_packages(kwargs)
    _flutter_test(name = name, **kwargs)
