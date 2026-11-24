"""Flutter test runner rule.

Compiles a Flutter test entry point to a kernel `.dill` and runs it under
`flutter_tester`, the headless Flutter engine. Tests interact with the test
runner via the same `package:test_api/backend.dart` `RemoteListener`
protocol that `flutter test` uses, so widget tests that initialize
`TestWidgetsFlutterBinding` (every `testWidgets`, every golden, the live
binding) work.

Wire-up:
  1. Bazel writes a per-target bootstrap `<name>_bootstrap.dart` that imports
     the user's test as `test`, then calls `RemoteListener.start(() => test.main)`
     and pipes the resulting StreamChannel over a WebSocket to the runner. When
     the suite carries `package:flutter_test`, the same callback installs the
     golden-file comparator, exactly where `flutter test` installs its own —
     see `flutter/private/goldens/comparator.dart`.
  2. The user's test + bootstrap are compiled together to a kernel `.dill` via
     the standard frontend_server (debug platform dill, `--enable-asserts`).
  3. The runner binary spawns `flutter_tester` with the dill, hosts a localhost
     WebSocket harness, drives the `package:test` MultiChannel protocol, and
     reports per-test pass/fail.

Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the runner
launches `flutter_tester` with the VM service enabled and collects source
reports via JSON-RPC, writing LCOV.

Usage:
    flutter_test(
        name = "widget_test",
        main = "test/widget_test.dart",
        deps = [
            "@deps//:flutter",
            "@deps//:flutter_test",
            "//:my_app_lib",
        ],
    )

The user's `deps` must transitively expose `package:flutter_test` (and
therefore `package:test_api`) so the generated bootstrap compiles.

Golden files: `matchesGoldenFile('goldens/x.png')` reads
`<dir of the test's main>/goldens/x.png` out of runfiles, so every golden has
to be a declared input — list them in `data`. Regenerate with
`bazel run //<pkg>:<target> -- --update-goldens`, which writes back to the
source tree; the same flag under `bazel test` is refused, because a test action
cannot write there.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "dart_analyzable_info_with_package",
    "dart_package_identity",
    "derive_lib_root",
    "entry_point_library",
)
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_hook_errors",
    "declare_flutter_assets_dir",
    "extract_library_tags_action",
)
load("//flutter/private:flutter_bundle.bzl", "BUNDLE_ATTRS", "flutter_bundle"
)
load("//flutter/private:flutter_defines_files.bzl", "defines_transition")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "compile_flutter_modular_test_kernel",
    "flutter_closure_packages",
    "flutter_kernel_module_aspect",
    "flutter_module_tools",
)
load("//flutter/private:code_assets.bzl", "FLUTTER_CODE_ASSETS_ATTRS", "flutter_code_assets")
load(
    "//flutter/private:flutter_test_common.bzl",
    _can_bootstrap = "can_bootstrap",
    _flutter_test_bootstrap_action = "flutter_test_bootstrap_action",
    _flutter_test_runner = "flutter_test_runner",
    _make_bootstrap_content = "make_bootstrap_content",
    _make_test_artifacts = "make_test_artifacts",
    _make_test_selection = "make_test_selection",
)
load(
    "//flutter/private:layering_check.bzl",
    "LAYERING_CHECK_ASPECT",
    "LAYERING_CHECK_ATTRS",
    "LAYERING_CHECK_TOOLCHAINS",
    "layering_check",
)

visibility(["//flutter/..."])

# Re-exported from `//flutter/private:flutter_test_common.bzl`, which holds the
# bootstrap implementation both test rules share. Kept under this name so
# existing loads of `make_bootstrap_content` from this module keep working.
make_bootstrap_content = _make_bootstrap_content

def _flutter_test_sdk_info(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    if not flutter_sdk_info.flutter_tester:
        fail(
            "flutter_test requires the active Flutter toolchain to provide a " +
            "flutter_tester binary; the resolved toolchain has none. This is " +
            "typically the case for cross-compile-only configurations — " +
            "build the test target with the host platform.",
        )
    return flutter_sdk_info

def _check_flutter_test_deps(ctx, closure):
    if not _can_bootstrap(ctx.attr.deps, closure.names):
        fail((
            "flutter_test target {name} must depend on package:flutter_test " +
            "(or at minimum package:test_api). Add `@<hub>//:flutter_test` " +
            "to deps so the generated bootstrap can import RemoteListener."
        ).format(name = ctx.label.name))

    # Same contract as `flutter_application`: a package whose build hook
    # cannot run (a member of a merged pub dependency cycle) would leave the
    # manifest below quietly one entry short.
    hook_err = check_hook_errors(ctx.label, ctx.attr.deps, closure.raw)
    if hook_err != None:
        fail(hook_err)

def _flutter_test_native_assets(ctx):
    # The closure's code assets, as for `flutter_application`; the test runs
    # out of runfiles, so the manifest names each library by its path there.
    return flutter_code_assets(ctx, runfiles = True)

def _flutter_test_sources(ctx, closure):
    # Per-target bootstrap. Imports the user's test via its `package:` URI when
    # `main` sits under `<lib_root>/lib/` (the URI of the library in `deps` that
    # lists it, when one does) and via `org-dartlang-app:///<stable_path>`
    # otherwise. Written by the shared helper, which also stages the golden
    # comparator next to it (a symlink) exactly when the suite carries
    # `package:flutter_test`.
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    entry_point = entry_point_library(ctx.file.main, ctx.attr.deps)
    test_import = entry_point.uri if entry_point != None else app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri
    staged_comparator = _flutter_test_bootstrap_action(ctx, test_import, bootstrap, names = closure.names)

    packages = closure.packages

    # Register the test's own package (when declared) so `package:<self>/foo`
    # imports inside test sources resolve across the multi-root `org-dartlang-app:///`
    # scheme without copying sources.
    packages = synthesize_app_package(
        ctx.label,
        packages,
        ctx.attr.package_name,
        lib_root,
        ctx.attr.language_version,
    )
    return struct(
        lib_root = lib_root,
        bootstrap = bootstrap,
        staged_comparator = staged_comparator,
        packages = packages,
        closure = closure,
    )

def _flutter_test_kernel(ctx, flutter_sdk_info, sources, native_assets):
    # The test's kernel is its entry module linked with its closure's modules, compiled against the
    # debug platform dill with assertions kept (`AssertStatement` / `AssertInitializer` preserved in
    # `.flutter.kmod` / `.flutter_entry.kmod`, run under `flutter_tester --enable-checked-mode`).
    # A shape the modules cannot take fails at analysis; the code assets ride the entry module.
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    own_files = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    modular_tools = flutter_module_tools(ctx, flutter_sdk_info, own_files, sources.packages, closure = sources.closure)
    base_dill = compile_flutter_modular_test_kernel(
        ctx,
        flutter_sdk_info,
        modular_tools,
        sources.bootstrap,
        sources.staged_comparator,
        sources.lib_root,
        sources.packages,
        kernel_dill,
        native_assets = native_assets.manifest if native_assets.any else None,
    )
    return struct(
        kernel_dill = kernel_dill,
        base_dill = base_dill,
    )

def _flutter_test_assets(ctx, flutter_sdk_info):
    # The test's `flutter_assets/`, as `flutter test` builds it: what the
    # pubspec names, for flutter_tester (its shaders compiled for it, SkSL for
    # Skia and Vulkan for Impeller). A debug bundle never reads the kernel.
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_bundle(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        target_platform = "tester",
        mode = "debug",
    )
    return flutter_assets

def test_coverage_libraries(package_name, lib_root, main, srcs):
    """The library URI prefixes a coverage run is scoped to: the test's own code.

    The package prefix first (when there is a `package_name`), then `main`,
    then `srcs` in the given order, each named as the compile path names it
    (`app_main_location`). The bootstrap, the golden comparator and every
    other generated file are not here. No duplicates, no blank entries.

    Args:
        package_name: The test's Dart package name, or `""`.
        lib_root: The test's library root, from `derive_lib_root`.
        main: The test's `main` File.
        srcs: The test's `srcs` Files.

    Returns:
        A list of URI strings.
    """
    libraries = ["package:%s/" % package_name] if package_name else []
    for f in [main] + list(srcs):
        uri = app_main_location(package_name, lib_root, f).uri
        if uri not in libraries:
            libraries.append(uri)
    return libraries

def _flutter_test_run(ctx, artifacts, native_assets):
    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, ctx.file.main)

    # The test run itself: the executable symlink, the `FLUTTER_TEST_*` env and
    # the runfiles, all from the implementation `flutter_prebuilt_test`
    # shares — one runner contract, no copy of it.
    runner = _flutter_test_runner(
        ctx = ctx,
        artifacts = _make_test_artifacts(
            dill = artifacts.kernel_dill,
            base_dill = artifacts.base_dill,
            assets_dir = artifacts.flutter_assets,
            library_tags = library_tags,
        ),
        selection = _make_test_selection(
            test_path = ctx.file.main.short_path,
            enable_impeller = ctx.attr.enable_impeller,
            include_tags = ctx.attr.include_tags,
            exclude_tags = ctx.attr.exclude_tags,
            coverage_libraries = test_coverage_libraries(
                ctx.attr.package_name,
                derive_lib_root(ctx.label.workspace_root, ctx.label.package),
                ctx.file.main,
                ctx.files.srcs,
            ),
        ),
        user_env = ctx.attr.env,
        data = ctx.attr.data,
        # The code assets' bundle directory ships here, at the
        # runfiles-relative path the manifest names.
        extra_files = native_assets.bundled,
    )
    return struct(
        executable = runner.executable,
        runfiles = runner.runfiles,
        env = runner.env,
        library_tags = library_tags,
    )

def _flutter_test_providers(ctx, sources, artifacts, runner):
    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "main"],
        dependency_attributes = ["deps"],
    )

    generated_dart_srcs = [
        f
        for f in ctx.files.srcs
        if f.extension == "dart" and not f.is_source
    ]

    # The same version the compile path above states. Analysis reading a
    # different one than the compiler is the divergence this attr exists to
    # close, reappearing one layer down.
    package = dart_package_identity(
        package_name = ctx.attr.package_name,
        lib_root = sources.lib_root,
        language_version = ctx.attr.language_version,
    )

    return [
        DefaultInfo(
            executable = runner.executable,
            files = depset([runner.executable] + generated_dart_srcs),
            runfiles = runner.runfiles,
        ),
        runner.env,
        instrumented_files_info,
        # What lets rules_dart's analysis check a `flutter_test`. The test's
        # `main` belongs to no package's `lib/`, so no
        # `DartInfo` can name it and it reaches the analyzer only through here.
        # Deliberately not offered as a `DartInfo`: `deps` requires one, and a
        # test is not a dependency.
        #
        # Built by `dart_analyzable_info_with_package` rather than
        # `dart_analyzable_info`, because a `flutter_test` is not package-less
        # the way a `dart_test` is: it declares `package_name`, and its `srcs`
        # are that package's `lib/`. The compile path already says so —
        # `synthesize_app_package` registers the same root record so
        # `package:<self>/…` imports resolve — and the package-less closure the
        # other constructor nests instead reports every such import as
        # `uri_does_not_exist`, blaming a line that is correct.
        #
        # Hence the source split: `srcs` is the `main` outside any `lib/`, and
        # `package_srcs` the `lib/` files reachable as `package:<self>/…`.
        #
        # `lib_root` comes from `derive_lib_root`, the same call the compile
        # path above now passes to `synthesize_app_package`. The two used to
        # disagree — synthesis hardcoded `""` — which is how a sub-package
        # target could analyze clean and compile against the *workspace
        # root's* `lib/`. One derivation, so they cannot drift again.
        #
        # `_sky_engine` joins the analyzer's closure and nothing else.
        # Compilation gets `dart:ui` from the patched SDK the toolchain
        # supplies; the analyzer resolves it only by following the
        # package_config to `package:sky_engine`'s `lib/_embedder.yaml`, so
        # analysis genuinely needs an entry compilation does not.
        dart_analyzable_info_with_package(
            label = ctx.label,
            package = package,
            deps = ctx.attr.deps + [ctx.attr._sky_engine],
            srcs = [ctx.file.main],
            package_srcs = ctx.files.srcs,
        ),
        # The test's own build products, for `flutter_prebuilt_test` to run
        # without compiling: `test_kernel` is exactly the test `.dill`,
        # `test_base_kernel` the base dill it links against at run time
        # (empty when the kernel was compiled whole-program),
        # `test_assets` its `flutter_assets/` tree, and `test_library_tags`
        # the entrypoint's `@Tags` as a `{"tags": [...]}` JSON file, for
        # `flutter_prebuilt_test`'s `library_tags`. A `filegroup` with
        # `output_group` on one of these feeds the matching
        # `flutter_prebuilt_test` attr.
        OutputGroupInfo(
            test_kernel = depset([artifacts.kernel_dill]),
            test_base_kernel = depset([artifacts.base_dill]) if artifacts.base_dill != None else depset(),
            test_assets = depset([artifacts.flutter_assets]),
            test_library_tags = depset([runner.library_tags]),
            # The strict-layering check on `main`, `srcs` and every first-party
            # library below: building the test runs it. The generated
            # bootstrap is not checked.
            _validation = layering_check(ctx, package),
        ),
    ]

def _flutter_test_impl(ctx):
    flutter_sdk_info = _flutter_test_sdk_info(ctx)
    closure = flutter_closure_packages(ctx.attr.deps)
    _check_flutter_test_deps(ctx, closure)

    native_assets = _flutter_test_native_assets(ctx)
    sources = _flutter_test_sources(ctx, closure)
    kernel = _flutter_test_kernel(ctx, flutter_sdk_info, sources, native_assets)
    artifacts = struct(
        kernel_dill = kernel.kernel_dill,
        base_dill = kernel.base_dill,
        flutter_assets = _flutter_test_assets(ctx, flutter_sdk_info),
    )
    runner = _flutter_test_run(ctx, artifacts, native_assets)
    return _flutter_test_providers(ctx, sources, artifacts, runner)

# flutter_test takes the compilation attrs plus the asset-bundle attrs: the
# pubspec says what the test's flutter_assets/ tree holds (Material widgets
# need `shaders/ink_sparkle.frag` and MaterialIcons), passed to
# flutter_tester via `--flutter-assets-dir`. Platform-runner-specific
# attrs (engines, plugin libs) are intentionally omitted — flutter_tester
# is a self-contained host engine.
_TEST_ATTRS = {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in (
        "main",
        "srcs",
        "deps",
        "defines",
        "language_version",
        "_extra_dart_defines",
        "package_name",
    )
} | BUNDLE_ATTRS
_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_kernel_module_aspect, LAYERING_CHECK_ASPECT],
    # The test's own `defines` are the configuration of its `deps`, so every module compiles with them and the
    # test stays modular.
    cfg = defines_transition,
)

# Standard `data` attr — files made available at test runtime via runfiles.
# Tests resolve them through `package:runfiles` / `Runfiles.create()`.
# Used for fixtures, golden images, and (importantly) FFI shared libraries the test loads via `dart:ffi`.
# Without this, a test that calls into a `cc_library`-produced dylib
# fails at `DynamicLibrary.open` with "file not found", and the
# failure surfaces silently from worker isolates as a hung
# `_opened.future` on the main isolate.
#
# Goldens in particular are *only* reachable through here. The comparator reads
# them from the test's directory in runfiles, so a PNG that exists in the source
# tree but is not a declared input fails as "non-existent file" rather than
# being read behind Bazel's back — which is what keeps a cached pass honest.
# The usual spelling is `data = glob(["test/goldens/**"])`.
_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data deps. Available in test runfiles. Use for " +
          "fixtures, goldens, and FFI dylibs. Golden PNGs must be listed " +
          "here or the comparator cannot see them.",
)

# Standard `env` attr — extra variables for the test process.
#
# Values are used **literally**: there is no `$(location)` or Make-variable
# expansion, so a path here has to be one the test itself can resolve (through
# runfiles, or relative to its working directory). Half-expanding would be
# worse than not expanding, because the unexpanded form still looks like a
# path.
#
# The `FLUTTER_TEST_*` keys the runner reads are its start-up contract;
# supplying one in `env` is rejected in the implementation rather than
# silently honoured or silently dropped. Tag selection is the exception with
# its own channel: a `--test_env=FLUTTER_TEST_TAGS=...` (or
# `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
_TEST_ATTRS["enable_impeller"] = attr.bool(
    doc = "Render with Impeller in flutter_tester, as `flutter test " +
          "--enable-impeller` does, instead of software Skia. A test that " +
          "draws an Impeller-only shader, or a golden meant to match an " +
          "Impeller device, needs it.",
    default = False,
)

_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test process. Values are " +
          "literal — no Make-variable or $(location) expansion. The " +
          "FLUTTER_TEST_* keys the runner reads cannot be set here; " +
          "override tag selection at run time with " +
          "--test_env=FLUTTER_TEST_TAGS=... instead.",
)

# Tag selection, as `flutter test --tags` / `--exclude-tags` resolve it.
# Named `include_tags` / `exclude_tags` rather than `tags` because Bazel's
# own `tags` attribute means something else. A `--test_env=FLUTTER_TEST_TAGS=...`
# (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
#
# Library-level `@Tags` on the entrypoint need no attribute: they are extracted
# at build time and always honoured (see `extract_library_tags_action`).
_TEST_ATTRS["include_tags"] = attr.string_list(
    doc = "Run only tests matching every one of these `package:test` tag " +
          "selectors (library, group or test level), as `flutter test " +
          "--tags` intersects them. Each entry is a boolean selector " +
          "(`a && b`, `a || b`, `!a`, parentheses); several entries, or " +
          "comma-separated values in one entry, all have to match. A test " +
          "matching an `exclude_tags` selector never runs. An attribute " +
          "selection that matches no test fails the target, so a tag name " +
          "nobody carries is a typo, not an empty pass.",
)
_TEST_ATTRS["exclude_tags"] = attr.string_list(
    doc = "Skip tests matching any of these `package:test` tag selectors " +
          "(library, group or test level), as `flutter test " +
          "--exclude-tags` unions them. Wins over `include_tags`.",
)
_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_TEST_ATTRS.update(FLUTTER_CODE_ASSETS_ATTRS)
_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
_TEST_ATTRS.update(LAYERING_CHECK_ATTRS)
_TEST_ATTRS["_library_tags_tool"] = LIBRARY_TAGS_TOOL_ATTR
_TEST_ATTRS["_tool"] = attr.label(
    doc = "The test runner binary that hosts the `package:test` protocol " +
          "and drives `flutter_tester`, built for the exec configuration.",
    default = Label("//flutter/private/tools:flutter_test_runner"),
    cfg = "exec",
)

# The golden-file comparator the generated bootstrap installs. Implicit rather
# than something each target lists, because needing it is a property of running
# Flutter tests at all, not a choice any BUILD file makes — and because the
# alternative to installing one is Flutter's `TrivialComparator`, which reports
# every golden assertion as passing without comparing anything.
_TEST_ATTRS["_golden_comparator_src"] = attr.label(
    doc = "Golden-file comparator staged into the generated bootstrap. " +
          "Compiled into the test only when its deps expose package:flutter_test.",
    default = Label("//flutter/private/goldens:comparator.dart"),
    allow_single_file = [".dart"],
)

# Analysis-only. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how
# the analyzer resolves `dart:ui`; without it every Flutter import in a widget
# test fails to resolve. It is an implicit attr rather than something each
# `flutter_test` lists, because needing it is a property of analyzing Flutter
# Dart, not a choice any BUILD file makes — and it reaches only
# `dart_analyzable_info`, so no compile action's inputs change.
_TEST_ATTRS["_sky_engine"] = attr.label(
    doc = "The `package:sky_engine` sources the analyzer needs to resolve " +
          "`dart:ui` in a widget test; compilation does not use them.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

flutter_test = rule(
    implementation = _flutter_test_impl,
    attrs = _TEST_ATTRS,
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + [
        t
        for t in LAYERING_CHECK_TOOLCHAINS
        if t not in MODULAR_KERNEL_TOOLCHAINS
    ] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter widget test, then runs it under flutter_tester " +
          "via the package:test_api RemoteListener protocol.",
)
