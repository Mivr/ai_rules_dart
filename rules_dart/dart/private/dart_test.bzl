"""Implementation of the dart_test rule.

Unified with `dart_binary`: the test's `main` is compiled to a self-contained
kernel (`.dill`) **at build time**, so package resolution and `part`/`import`
resolution happen in the execroot — exactly where `dart_binary` already proves
they work — and the test launcher merely runs the dill. No sources and no
package layout are needed at runtime, so manifest-mode runfiles (Windows) are a
non-issue. The launcher does write a runtime package config for
`Isolate.resolvePackageUri`, from the list of packages the rule stages for it.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:build_hooks.bzl", "NATIVE_ASSETS_CONSUMER_ATTRS", "native_assets_manifest")
load(
    "//dart/private:build_settings.bzl",
    "EXTRA_DART_DEFINES_ATTR",
    "REFUSED_DART_LIBRARIES_ATTR",
    "executable_defines_transition",
)
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "WINDOWS_CONSTRAINT_ATTR",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "create_test_executable",
    "runfiles_path",
    "target_dart_abi",
)
load("//dart/private:coverage_map.bzl", "COVERAGE_MAP_TOOLCHAINS", "write_coverage_map", "write_generated_list")
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect", "executable_import_check")
load(
    "//dart/private:dart_kernel.bzl",
    "DartKernelInfo",
    "MODULAR_KERNEL_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "dart_kernel_module_aspect",
    "entry_source_uri",
    "entry_sources",
    "modular_executable_kernel",
    "modular_executable_tools",
)
load("//dart/private:dart_test_runner.bzl", "DartTestKernelInfo")
load(
    "//dart/private:executable_package.bzl",
    "EXECUTABLE_PACKAGE_ATTRS",
    "executable_has_package",
    "executable_hook_error",
    "executable_native_assets",
    "executable_package",
    "executable_package_set",
    "executable_packages",
)
load("//dart/private:kernel_params.bzl", "kernel_compile_settings", "kernel_link_options")
load("//dart/private:package_files.bzl", "collect_transitive_package_files")
load("//dart/private:test_package_roots.bzl", "write_package_roots")
load("//dart/private:test_runner_info.bzl", "DartTestRunnerInfo")

visibility(["//dart/..."])

def _check_tag_entries(target, attr_name, tags):
    """Validates that tag selectors contain no empty entries or newlines.

    Args:
        target: The label of the target being checked.
        attr_name: The name of the attribute (`include_tags` or `exclude_tags`).
        tags: The list of tag selector strings.
    """
    for tag in tags:
        if not tag or "\n" in tag or "\r" in tag:
            fail("%s: `%s` entries cannot be empty or contain newlines" % (target, attr_name))

def _dart_test_impl(ctx):
    _check_tag_entries(ctx.label, "include_tags", ctx.attr.include_tags)
    _check_tag_entries(ctx.label, "exclude_tags", ctx.attr.exclude_tags)
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    # The build-time compile resolves each package, and the test's own `main`
    # with any generated sibling sources (e.g. a `.mocks.dart`), where they sit.
    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    runner = _test_runner(ctx, own, dart_sdk_info)
    kernel = _compile_test_kernel(ctx, own, bootstrap = runner != None, use_base_dill = runner != None)
    dill = kernel.dill

    # Thin launcher: run the self-contained dill with asserts enabled. The dill
    # carries all sources/imports, so runfiles need only the VM and (for code
    # assets) the `.so` libraries.
    env = {
        "RULES_DART_DART": runfiles_path(dart_sdk_info.dart, workspace_name),
        "RULES_DART_DILL": runfiles_path(dill, workspace_name),
    }

    # The launcher turns this list into the package config the test runs with.
    package_roots = write_package_roots(ctx, executable_package_set(own))
    env["RULES_DART_PACKAGE_ROOTS"] = runfiles_path(package_roots, workspace_name)
    coverage_files = []
    if ctx.configuration.coverage_enabled:
        coverage_map = _coverage_map(ctx, executable_packages(own))
        coverage_files.append(coverage_map)
        env["RULES_DART_COVERAGE_MAP"] = runfiles_path(coverage_map, workspace_name)
    generated_list = write_generated_list(ctx, ctx.files.srcs + [ctx.file.main], ctx.attr.deps)
    env["RULES_DART_COVERAGE_GENERATED"] = runfiles_path(generated_list, workspace_name)
    runner_files = []
    if runner:
        # The runner reads the test file for its annotations (`@TestOn`,
        # `@Timeout`, `@Tags`) and names the suite after it.
        env["RULES_DART_TEST_RUNNER"] = runfiles_path(runner, workspace_name)
        env["RULES_DART_TEST_MAIN"] = runfiles_path(ctx.file.main, workspace_name)
        env["RULES_DART_TEST_PATH"] = _test_path(ctx)
        env["RULES_DART_BASE_DILL"] = (
            runfiles_path(kernel.base_dill, workspace_name) if kernel.base_dill != None else ""
        )
        runner_files = [runner, ctx.file.main] + (
            [kernel.base_dill] if kernel.base_dill != None else []
        )
    if ctx.attr.include_tags:
        env["RULES_DART_INCLUDE_TAGS"] = " && ".join(["(%s)" % t for t in ctx.attr.include_tags])
    if ctx.attr.exclude_tags:
        env["RULES_DART_EXCLUDE_TAGS"] = " || ".join(["(%s)" % t for t in ctx.attr.exclude_tags])
    for key, value in ctx.attr.env.items():
        if key.startswith("RULES_DART_"):
            fail("%s: `env` cannot set %s; rules_dart uses the RULES_DART_ prefix to drive the test" % (ctx.label, key))
        env[key] = ctx.expand_location(value, ctx.attr.data)
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = env,
        env_inherit = ctx.attr.env_inherit,
    )

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    # Its non-`lib/` `data` files come along for the same reason: a program
    # that walks a dependency's package root (`pubspec.yaml`, `LICENSE`) has
    # no other way to see them once the dill is all that runs.
    #
    # The test runs its kernel with the launcher and the VM, so it takes only
    # `runtime_files`. A test that runs SDK commands itself (`dart format`,
    # `dart compile`) declares `@rules_dart//dart` in `data`, which brings the
    # whole SDK.
    runfiles = ctx.runfiles(
        files = (
            [dill, generated_list, package_roots] + coverage_files + kernel.runtime_libs +
            runner_files + ctx.files.data
        ),
        transitive_files = depset(
            transitive = [
                dart_sdk_info.runtime_files,
                collect_transitive_resources(ctx.attr.deps),
                collect_transitive_package_files(ctx.attr.deps),
            ],
        ),
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        env_info,
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. The analyze/fix rules stage by `short_path`, which is the
        # source file's own path.
        own.analyzable,
        # `bazel coverage` instruments the Dart sources this test and its deps
        # own; the launcher collects the LCOV (see `test_runner.dart`).
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs", "main"],
            dependency_attributes = ["deps", "data"],
            extensions = ["dart"],
        ),
        OutputGroupInfo(_validation = executable_import_check(ctx, own.record)),
    ]

def _coverage_map(ctx, packages):
    """Writes the map from the source URIs the VM reports to exec paths.

    Only `bazel coverage` needs it, so a test built without coverage has none.
    The launcher turns the VM's coverage into LCOV with it: every `SF:` is the
    file's exec path (a generated file's `bazel-out/<cfg>/bin/...`, an external
    file's `external/<repo>/...`).
    A Dart source is reported by the VM under the URI the compile embeds:
    `package:<name>/<path under lib/>` for a file in a package's `lib/`, and the
    multi-root `org-dartlang-root:///<path>` URI for any file (a test's own, or
    one outside `lib/`). The VM's `file://` URI of a source is resolved by the
    launcher against the exec paths; no host path is written here. All are
    written, from the packages the compile resolves against, for the
    test's own files and for every source its `deps` reach. The action reads the
    sources from the depset, so the closure is never flattened in analysis. A test
    with no Dart source to map gets `{}`.

    Args:
      ctx: The `dart_test` rule context.
      packages: The `DartPackageInfo` records the compile resolves against.

    Returns:
      The `<name>.coverage_map.json` File.
    """
    return write_coverage_map(
        ctx,
        collect_transitive_srcs(ctx.attr.deps),
        [ctx.file.main] + ctx.files.srcs,
        packages,
    )

def _compile_test_kernel(ctx, own, bootstrap, use_base_dill = False):
    """Compiles a test's `main` to the kernel that a test runs from.

    `dart_test` and `dart_test_kernel` both compile through here, so the kernel
    a runner snapshot is trained on is built exactly as the kernel a test runs
    is.

    Args:
      ctx: The rule context, carrying the test attributes.
      own: The `executable_package` result for the test's own sources.
      bootstrap: Whether the test runs under `package:test`'s runner, so that
        the compiled entrypoint is the bootstrap that hands `main` to it. The
        kernel is then declared where the runner's `--precompiled` layout
        expects it.
      use_base_dill: Whether to link `dill` in modular mode as a delta against a
        shared `base_dill` provided by `deps` (e.g. `package:test`), returning
        that `base_dill` in the result struct.

    Returns:
      `struct(dill, base_dill, runtime_libs)`: the kernel `.dill` File, the
      shared `base_dill` File (or `None`), and the code-asset libraries that
      ship in runfiles beside it.
    """
    if ctx.attr.code_assets_from_deps:
        hook_err = executable_hook_error(ctx.label, own)
        if hook_err != None:
            fail(hook_err)

    # The closure's build hook outputs (unless opted out) plus any code asset
    # named outright — see the same comment in `dart_binary`.
    native_assets = executable_native_assets(ctx)
    kernel_tools = modular_executable_tools(
        ctx,
        [ctx.file.main] + ctx.files.srcs,
        own.record,
        kernel_mode = True,
        resolved_assets = native_assets,
        closure = own.closure,
    )
    return _compile_modular_test_kernel(ctx, own, bootstrap, kernel_tools, native_assets, use_base_dill = use_base_dill)

def _test_native_assets(ctx, native_assets, dill):
    """Writes the code-asset mapping a test's kernel embeds, and bundles its libraries.

    The entry module embeds the mapping, which resolves each `relative` path
    against the dill at run time. The libraries ship in runfiles, in one
    directory beside the dill.

    Args:
      ctx: The rule context.
      native_assets: depset of the native assets the test ships.
      dill: The kernel `.dill` the mapping's relative paths resolve against.

    Returns:
      `(native_assets_yaml, runtime_libs)`: the mapping File (or `None` when
      there are no native assets) and the files to ship in runfiles.
    """
    if not native_assets:
        return None, []

    # Under the `package:test` runner the libraries go inside the precompiled
    # directory, which the runner takes along when it runs a copy of the dill.
    precompiled = "%s.precompiled/" % ctx.label.name
    in_precompiled = dill.short_path.startswith(ctx.label.package + "/" + precompiled) if ctx.label.package else dill.short_path.startswith(precompiled)
    result = native_assets_manifest(
        ctx,
        native_assets,
        target_dart_abi(ctx),
        ctx.label.name,
        relative_to = dill.dirname,
        bundle_path = precompiled + "native_assets" if in_precompiled else None,
    )
    return result.manifest, [result.bundle]

def _test_kernel_output(ctx, bootstrap):
    """Declares the kernel a test runs from, in the place its runner expects.

    Args:
      ctx: The rule context.
      bootstrap: Whether the test runs under the `package:test` runner.

    Returns:
      The output File.
    """
    if bootstrap:
        # Declared where the runner's `--precompiled` layout expects it, so it
        # is loaded in place: code-asset paths are relative to the dill, and a
        # copy elsewhere would leave them pointing at nothing.
        return ctx.actions.declare_file(
            "%s.precompiled/%s.vm_test.vm.app.dill" % (ctx.label.name, _test_path(ctx)),
        )
    return ctx.actions.declare_file(ctx.label.name + ".dill")

def _compile_modular_test_kernel(ctx, own, bootstrap, tools, native_assets, use_base_dill = False):
    """Compiles a test's entry module and links it: the one way a test's kernel is built.

    The entry module holds only the test (or its bootstrap) and the test's own
    sources. Everything the test imports is in a dependency module, which the
    link concatenates in. The sources are addressed by where they sit, so the
    test's relative imports resolve as they do in the monolithic compile.

    Args:
      ctx: The rule context.
      own: The `executable_package` result for the test's own sources.
      bootstrap: Whether the test runs under the `package:test` runner.
      tools: The exec kernel tools, from `modular_executable_tools`.
      native_assets: depset of the native assets the test ships. Their
        mapping is embedded in the entry module, against the linked `dill`.
      use_base_dill: Whether to link `dill` as a delta against a shared `base_dill`.

    Returns:
      `struct(dill, base_dill, runtime_libs)`, as `_compile_test_kernel` returns.
    """
    dill = _test_kernel_output(ctx, bootstrap)
    native_assets_yaml, runtime_libs = _test_native_assets(ctx, native_assets, dill)
    if bootstrap:
        entry_files = [_write_modular_bootstrap(ctx, getattr(tools, "entry_point", None)), ctx.file.main]
    else:
        entry_files = [ctx.file.main]
    base_dill = modular_executable_kernel(
        ctx,
        tools,
        entry_sources(entry_files + ctx.files.srcs),
        own.packages,
        [dep[DartKernelInfo] for dep in ctx.attr.deps],
        dill,
        kernel_compile_settings(product = False),
        kernel_link_options(use_base_dill = use_base_dill),
        own_defines = ctx.attr.defines,
        native_assets = native_assets_yaml,
    )
    return struct(dill = dill, base_dill = base_dill, runtime_libs = runtime_libs)

def _write_modular_bootstrap(ctx, entry_point = None):
    """Writes the modular entrypoint: the runner's bootstrap, importing the test by URI.

    The monolithic bootstrap imports the test by a path relative to itself. A
    modular entry module names every source by its `org-dartlang-root` URI, so
    the import names the test the same way, and the test's own relative imports
    resolve from that URI. A `main` that a library in `deps` lists is that
    library's, so the import names it by the library's `package:` URI.

    Args:
      ctx: The rule context.
      entry_point: The struct from `entry_point_library`, or None.

    Returns:
      The bootstrap File.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".vm_test.dart")
    ctx.actions.write(
        output = bootstrap,
        content = _BOOTSTRAP.format(
            test = ctx.file.main.short_path,
            import_path = entry_point.uri if entry_point != None else entry_source_uri(ctx.file.main.short_path),
        ),
    )
    return bootstrap

def _dart_test_kernel_impl(ctx):
    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    dill = _compile_test_kernel(ctx, own, bootstrap = True).dill
    test_path = _test_path(ctx)

    # The runner's `--precompiled` directory: the kernel's path less the
    # `/<testPath>.vm_test.vm.app.dill` layout that `dart_test` declares it at.
    suffix = "/" + test_path + ".vm_test.vm.app.dill"
    return [
        DefaultInfo(files = depset([dill])),
        DartTestKernelInfo(
            dill = dill,
            precompiled_dir = dill.path[:-len(suffix)],
            test_path = test_path,
            source = ctx.file.main,
        ),
    ]

def _test_runner(ctx, own, dart_sdk_info):
    """The `package:test` runner for this test, or `None` to run it directly.

    The runner is found on the direct dependency that provides `package:test`
    (see `dart_test_runner.bzl`). A test that reaches `package:test` only
    through another library is refused rather than run directly: run directly
    it would silently lose the filter, sharding and timeout behaviour Bazel
    expects, which is a worse failure than a clear one here.

    Args:
      ctx: The rule context.
      own: The `executable_package` result for the test.
      dart_sdk_info: The `DartSdkInfo` that will execute the test and runner.

    Returns:
      The runner `.dill` File, or `None`.
    """
    for dep in ctx.attr.deps:
        if DartTestRunnerInfo in dep:
            info = dep[DartTestRunnerInfo]
            runner_sdk = getattr(info, "sdk_version", "")
            if runner_sdk and dart_sdk_info.version and runner_sdk != dart_sdk_info.version:
                fail((
                    "%s: `deps` target %s carries a test runner kernel (.dill) compiled by " +
                    "Dart SDK %s, but will be executed by Dart SDK %s. A kernel binary can " +
                    "only run on the exact Dart SDK version that compiled it."
                ) % (ctx.label, dep.label, runner_sdk, dart_sdk_info.version))
            return info.runner
    if executable_has_package(own, "test"):
        fail(("%s: depends on `package:test` without listing it in " +
              "`deps`. Add the `package:test` target (e.g. " +
              "`@<hub>//:test`) to `deps`: `dart_test` runs tests through " +
              "the runner that target carries.") % ctx.label)
    return None

def _test_path(ctx):
    """The test's path as the runner names it.

    That is its `short_path`, with a file from another repository placed under
    `external/` rather than above the root.

    Args:
      ctx: The rule context.

    Returns:
      The forward-slashed relative path.
    """
    path = ctx.file.main.short_path
    return "external/" + path[3:] if path.startswith("../") else path

_BOOTSTRAP = """\
// Generated by rules_dart: runs `{test}` under the `package:test` runner.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/bootstrap/vm.dart';

import '{import_path}' as test;

void main(List<String> _, SendPort sendPort) {{
  internalBootstrapVmTest(() {{
    final Function main = test.main;
    // The runner calls `main` with no arguments. A test that reads its
    // `args` gets the ones Bazel would have passed it, from the launcher.
    if (main is void Function(List<String>)) {{
      final encoded = Platform.environment['RULES_DART_TEST_ARGS'] ?? '[]';
      final args = (jsonDecode(encoded) as List).cast<String>();
      return () => main(args);
    }}
    return main;
  }}, sendPort);
}}
"""

def _test_vm_transition_impl(_settings, _attr):
    return {"//dart/private:vm_product": False}

_test_vm_transition = transition(
    implementation = _test_vm_transition_impl,
    inputs = [],
    outputs = ["//dart/private:vm_product"],
)

_TEST_COMMON_ATTRS = (
    WINDOWS_CONSTRAINT_ATTR |
    DART_ABI_CONSTRAINT_ATTRS |
    NATIVE_ASSETS_CONSUMER_ATTRS |
    EXTRA_DART_DEFINES_ATTR |
    REFUSED_DART_LIBRARIES_ATTR |
    MODULAR_KERNEL_ATTRS |
    EXECUTABLE_PACKAGE_ATTRS
)

# The attributes that define a test's kernel, shared by `dart_test` and
# `dart_test_kernel` so the two compile the same way.
_SHARED_TEST_ATTRS = {
    "main": attr.label(
        doc = "The Dart test file to run. Must contain a top-level `main()` function.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files that are part of this test's package but not reachable via `deps`.",
        allow_files = [".dart"],
    ),
    "defines": attr.string_list(
        doc = """Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` \
flag on the build-time compile, so `String.fromEnvironment` resolves to it. Set these here rather \
than at run time: the test's `main` is compiled to a kernel during the build, and environment \
declarations are resolved by the front end at that point — the VM cannot supply them later.""",
    ),
    "code_assets": attr.label_list(
        doc = """`dart_code_asset` targets the test's `@Native` FFI bindings resolve against, \
besides the code assets its `deps` bring (their packages' build hooks, and their own \
`code_assets`). The test's kernel embeds the mapping, and the libraries ship in runfiles.""",
        providers = [DartCodeAssetInfo],
    ),
    "code_assets_from_deps": attr.bool(
        default = True,
        doc = """Whether to take the native code assets of `deps`: the outputs of their packages' \
build hooks, and their `code_assets`. Defaults to `True`.

Leave this on for a test that runs the native packages it depends on. Turn it off for a pure-Dart \
`dart_test` that imports packages for their Dart API (such as `package:drift` with a mock or \
custom executor) without loading their native libraries at runtime: no build hook then runs.""",
    ),
    "_allowlist_function_transition": attr.label(
        doc = "Allowlist target permitting the Starlark function transition this rule applies. Defaults to `@bazel_tools//tools/allowlists/function_transition_allowlist`.",
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
} | _TEST_COMMON_ATTRS

dart_test = rule(
    implementation = _dart_test_impl,
    cfg = _test_vm_transition,
    attrs = _SHARED_TEST_ATTRS | {
        "data": attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be resolved via `Runfiles.rlocation()`.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "`dart_library` targets this test depends on. The test's `defines` are the environment every module of this closure compiles with, so two tests with equal `defines` share every module.",
            providers = [DartInfo],
            aspects = [dart_kernel_module_aspect, dart_import_check_aspect],
            cfg = executable_defines_transition,
        ),
        "env": attr.string_dict(
            doc = """Environment variables set when the test runs. Values expand \
`$(rlocationpath ...)` and the other location functions for labels in `data`, so a test can be \
told where a runfile is (resolve it with `Runfiles.rlocation()`).""",
        ),
        "env_inherit": attr.string_list(
            doc = "Names of environment variables passed through from the environment `bazel test` runs in.",
        ),
        "exclude_tags": attr.string_list(
            doc = (
                "Skip the cases matching any selector listed, where each entry is a " +
                "complete selector evaluated on its own, passed as the runner's `--exclude-tags`. Defaults to empty."
            ),
        ),
        "include_tags": attr.string_list(
            doc = (
                "Run only the cases whose tags match every selector listed, where each " +
                "entry is a complete selector evaluated on its own, passed as the runner's `--tags`. Defaults to empty."
            ),
        ),
        "_import_check": attr.label(
            doc = "The tool that checks this test's imports against its direct `deps` (see the `dart_layering_check` feature).",
            default = Label("//dart/private/tools:import_check"),
            executable = True,
            cfg = "exec",
        ),
        "_tool": attr.label(
            doc = "Executable that launches the test's kernel with the SDK's VM. Defaults to `//dart/private/tools:test_runner`.",
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    },
    test = True,
    toolchains = ["//dart:toolchain_type"] + MODULAR_KERNEL_TOOLCHAINS + COVERAGE_MAP_TOOLCHAINS,
    doc = (
        "Compiles a Dart test to a kernel at build time and runs it with " +
        "asserts enabled. A test with `package:test` in `deps` runs under " +
        "that package's runner, so `--test_filter`, `shard_count` and " +
        "per-case results work and Bazel's `timeout` is the only time limit. " +
        "Every test runs with a runtime package config (`Platform.packageConfig` is set), " +
        "so `Isolate.resolvePackageUri` resolves `package:<name>/<path>` to the file " +
        "staged in runfiles for each package whose `lib/` has staged files (a " +
        "dependency's `resources` and `data`); a package with none still resolves to " +
        "`null`. `Runfiles.rlocation()` stays supported for reaching runfiles directly."
    ),
)

dart_test_kernel = rule(
    implementation = _dart_test_kernel_impl,
    cfg = _test_vm_transition,
    attrs = _SHARED_TEST_ATTRS | {
        "deps": attr.label_list(
            doc = "`dart_library` targets this test depends on, compiled with the test's `defines` as for `dart_test`.",
            providers = [DartInfo],
            aspects = [dart_kernel_module_aspect],
            cfg = executable_defines_transition,
        ),
    },
    toolchains = ["//dart:toolchain_type"] + MODULAR_KERNEL_TOOLCHAINS,
    doc = (
        "Compiles a test to the kernel that `dart_test` runs under the " +
        "`package:test` runner, without a runner of its own. " +
        "`dart_test_runner_snapshot` trains the runner on one of these."
    ),
)
