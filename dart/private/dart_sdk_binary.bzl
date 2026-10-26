"""A runnable target that exposes the Dart SDK binary via toolchain resolution.

Usage:
    bazel run @rules_dart//dart -- --version
    bazel run @rules_dart//dart -- analyze lib/

The executable is the `sdk_launcher` tool symlinked into place: it resolves
the toolchain `dart` through runfiles, keeps the caller's environment so the
pub cache and hosted credentials keep working, and places the global
`--suppress-analytics` flag before command-form invocations so the run writes
no telemetry under HOME. Arguments and the exit code pass through untouched.
"""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "runfiles_path")

def _dart_sdk_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # The config sits beside the executable on purpose: the launcher finds it
    # there with no environment when another target runs it as a data
    # dependency, so the two files must stay side by side.
    run_config = ctx.actions.declare_file(ctx.label.name + ".sdk_config.json")
    ctx.actions.write(
        output = run_config,
        content = json.encode({
            "dart": runfiles_path(dart_sdk_info.dart, ctx.workspace_name),
        }),
    )

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(
        ctx.label.name + (".exe" if is_windows else ""),
    )
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._sdk_launcher,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [run_config, dart_sdk_info.dart],
        transitive_files = dart_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(ctx.attr._sdk_launcher[DefaultInfo].default_runfiles)

    config_key = runfiles_path(run_config, ctx.workspace_name)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        # `bazel run @rules_dart//dart -- args` forwards only the user's
        # arguments, so the launcher learns where its configuration is through
        # the environment, as `dart_format`'s runner does.
        RunEnvironmentInfo(environment = {"DART_SDK_CONFIG": config_key}),
        # The same file by label, for a caller that runs the binary as `data`
        # and so does not get the environment above.
        OutputGroupInfo(dart_sdk_config = depset([run_config])),
    ]

dart_sdk_binary = rule(
    implementation = _dart_sdk_binary_impl,
    attrs = dict({
        "_sdk_launcher": attr.label(
            doc = "Executable symlinked as this rule's output, running the toolchain Dart SDK binary with the caller's arguments. Defaults to `//dart/private/tools:sdk_launcher`.",
            default = "//dart/private/tools:sdk_launcher",
            executable = True,
            cfg = "target",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Exposes the Dart SDK binary from the resolved toolchain as a runnable target.",
)
