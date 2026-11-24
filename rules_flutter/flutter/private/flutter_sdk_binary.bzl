"""A runnable target that exposes the Flutter-bundled Dart binary via toolchain resolution.

Usage:
    bazel run @rules_flutter//dart -- --version
    bazel run @rules_flutter//dart -- analyze lib/
"""

load("//flutter:providers.bzl", "resolve_exec_dart")
load("//flutter/private:run_home.bzl", "RUN_HOME_SH", "RUN_HOME_SUPPRESS_ANALYTICS")

visibility(["//flutter/..."])

_BASH_RUNFILES_INIT = """\
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---"""

_BAT_TEMPLATE_RUN = """\
@echo off
setlocal
set RUNFILES_DIR=%~dp0%~n0.exe.runfiles
if not exist "%RUNFILES_DIR%" set RUNFILES_DIR=%~dp0%~n0.runfiles
set DART=%RUNFILES_DIR%\\{dart}
if defined BUILD_WORKING_DIRECTORY cd /d "%BUILD_WORKING_DIRECTORY%"
:: Caller-home policy (RT37-flutter:02). Mirrors runHomePolicy in
:: flutter/private/tools/run_home.dart and run_home_exec in
:: //flutter/private:run_home.bzl: command form keeps the caller env and
:: passes the analytics flag from //flutter/private:run_home.bzl so the CLI
:: writes no telemetry into the caller's HOME; a program file and an argv
:: with no positional argument run under a fresh private home, because the
:: VM rejects the flag for a program file and dartdev still writes telemetry
:: for --verbose. :run_home_classify scans %* in a subroutine, where shift
:: leaves the caller's %* intact, skipping leading dash-arguments; an empty
:: remainder or a first remainder ending in .dart/.dill/.snapshot/.aot/.jit
:: (any case, via IF /I) is a program file, and a leading
:: --no-suppress-analytics asks for analytics: both use a private home. A
:: leading --suppress-analytics on command form passes through unchanged.
call :run_home_classify %*
if "%RUN_HOME_PRIVATE%"=="1" goto :run_home_private
if "%RUN_HOME_SUPPRESS%"=="1" (
  "%DART%" {suppress} %*
) else (
  "%DART%" %*
)
goto :run_home_done
:run_home_private
set "RUN_HOME_TMP=%TEMP%\\run-home-%RANDOM%-%RANDOM%"
mkdir "%RUN_HOME_TMP%" >nul 2>&1
if errorlevel 1 (
  echo run-home: cannot create a private home "%RUN_HOME_TMP%" >&2
  exit /b 1
)
set "HOME=%RUN_HOME_TMP%"
set "USERPROFILE=%RUN_HOME_TMP%"
set "APPDATA=%RUN_HOME_TMP%"
set "LOCALAPPDATA=%RUN_HOME_TMP%"
set "XDG_CONFIG_HOME=%RUN_HOME_TMP%"
set "XDG_CACHE_HOME=%RUN_HOME_TMP%"
set "XDG_DATA_HOME=%RUN_HOME_TMP%"
"%DART%" %*
set "RUN_HOME_RC=%ERRORLEVEL%"
rmdir /s /q "%RUN_HOME_TMP%"
exit /b %RUN_HOME_RC%
"""

# The classification half of the Windows launcher. It is a second string
# literal so neither half is an over-long literal; :run_home_done is the jump
# target of the dispatch above, and both halves are concatenated before
# `.format`.
_BAT_TEMPLATE_CLASSIFY = """\
:run_home_classify
set "RUN_HOME_PRIVATE=0"
set "RUN_HOME_SUPPRESS=0"
set "RUN_HOME_ALREADY=0"
set "RUN_HOME_FIRST="
:run_home_scan
if "%~1"=="" goto :run_home_scanned
if defined RUN_HOME_FIRST goto :run_home_shift
set "RUN_HOME_ARG=%~1"
if "%RUN_HOME_ARG:~0,1%"=="-" (
  if "%RUN_HOME_ARG%"=="--suppress-analytics" set "RUN_HOME_ALREADY=1"
  if "%RUN_HOME_ARG%"=="--no-suppress-analytics" set "RUN_HOME_PRIVATE=1"
  goto :run_home_shift
)
set "RUN_HOME_FIRST=%RUN_HOME_ARG%"
:run_home_shift
shift
goto :run_home_scan
:run_home_scanned
if "%RUN_HOME_PRIVATE%"=="1" goto :eof
if not defined RUN_HOME_FIRST (
  set "RUN_HOME_PRIVATE=1"
  goto :eof
)
if /I "%RUN_HOME_FIRST:~-5%"==".dart" goto :run_home_file
if /I "%RUN_HOME_FIRST:~-5%"==".dill" goto :run_home_file
if /I "%RUN_HOME_FIRST:~-9%"==".snapshot" goto :run_home_file
if /I "%RUN_HOME_FIRST:~-4%"==".aot" goto :run_home_file
if /I "%RUN_HOME_FIRST:~-4%"==".jit" goto :run_home_file
set "RUN_HOME_SUPPRESS=1"
if "%RUN_HOME_ALREADY%"=="1" set "RUN_HOME_SUPPRESS=0"
goto :eof
:run_home_file
set "RUN_HOME_PRIVATE=1"
goto :eof
:run_home_done
"""

_BAT_TEMPLATE = _BAT_TEMPLATE_RUN + _BAT_TEMPLATE_CLASSIFY

def _runfiles_path(f, workspace_name):
    """Convert a File to its path in the runfiles tree."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def _is_windows(ctx):
    """Whether the target platform satisfies the Windows OS constraint."""
    constraint = ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]
    return ctx.target_platform_has_constraint(constraint)

def _flutter_sdk_binary_impl(ctx):
    """Writes a launcher script that invokes the resolved Flutter SDK's `dart` binary."""
    toolchain = ctx.toolchains["//flutter:toolchain_type"]
    flutter_sdk_info = toolchain.flutter_sdk_info
    dart = resolve_exec_dart(ctx, flutter_sdk_info)

    dart_path = _runfiles_path(dart, ctx.workspace_name)

    if _is_windows(ctx):
        script = ctx.actions.declare_file(ctx.label.name + ".bat")
        ctx.actions.write(
            output = script,
            content = _BAT_TEMPLATE.format(
                dart = dart_path.replace("/", "\\"),
                suppress = RUN_HOME_SUPPRESS_ANALYTICS,
            ),
            is_executable = True,
        )
    else:
        script = ctx.actions.declare_file(ctx.label.name)
        ctx.actions.write(
            output = script,
            content = """#!/usr/bin/env bash
{runfiles_init}
{run_home_sh}
DART="$(rlocation "{dart}")"
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then
  cd "$BUILD_WORKING_DIRECTORY"
fi
# Caller-home policy (RT37-flutter:02): keep the caller env for command form so
# PUB_CACHE and credentials resolve; the helper execs dart with telemetry
# suppressed, or under a private home for the forms the flag does not cover.
run_home_exec "$DART" "$@"
""".format(
                runfiles_init = _BASH_RUNFILES_INIT,
                run_home_sh = RUN_HOME_SH,
                dart = dart_path,
            ),
            is_executable = True,
        )

    exec_tc_type = "@rules_dart//dart:exec_tools_toolchain_type"
    dart_tc = ctx.toolchains[exec_tc_type] if exec_tc_type in ctx.toolchains else None
    has_dart_sdk = dart_tc and getattr(dart_tc, "dart_sdk_info", None)
    sdk_files = dart_tc.dart_sdk_info.tool_files if has_dart_sdk else flutter_sdk_info.tool_files
    runfiles = ctx.runfiles(transitive_files = sdk_files)
    runfiles = runfiles.merge(ctx.attr._runfiles_lib[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

flutter_sdk_binary = rule(
    implementation = _flutter_sdk_binary_impl,
    attrs = {
        "_runfiles_lib": attr.label(
            doc = "Bazel runfiles library merged into the binary's runfiles.",
            default = "@bazel_tools//tools/bash/runfiles",
        ),
        "_windows_constraint": attr.label(
            doc = "Windows platform constraint value, selecting the `.bat` launcher.",
            default = "@platforms//os:windows",
        ),
    },
    executable = True,
    toolchains = [
        "//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Exposes the Flutter-bundled Dart binary from the resolved toolchain as a runnable target.",
)
