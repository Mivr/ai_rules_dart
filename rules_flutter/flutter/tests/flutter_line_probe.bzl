"""The release line of the Flutter toolchain a test resolves, for tests whose expectation is the line's.

A test that can hold on one line only reads the line here and asserts what
that line's entry says (`//flutter/private:sdk_lines.bzl`), so the suites
pass with either supported line as the default.
"""

visibility(["//flutter/tests/..."])

FlutterLineInfo = provider(
    doc = "The `FlutterSdkInfo.line` of the resolved Flutter toolchain.",
    fields = {"line": "struct: the `FLUTTER_SDK_LINES` entry."},
)

def _flutter_line_probe_impl(ctx):
    info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    return [FlutterLineInfo(line = info.line)]

flutter_line_probe = rule(
    implementation = _flutter_line_probe_impl,
    doc = "Returns the resolved Flutter toolchain's line as `FlutterLineInfo`.",
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

# The attribute a line-aware analysis test adds.
FLUTTER_LINE_ATTR = {
    "_flutter_line": attr.label(
        default = Label("//flutter/tests:flutter_line"),
        providers = [FlutterLineInfo],
    ),
}

def flutter_line(ctx):
    """The line entry of the Flutter toolchain, from a test that has `FLUTTER_LINE_ATTR`.

    Args:
      ctx: The analysis test's context.

    Returns:
      The `FLUTTER_SDK_LINES` entry.
    """
    return ctx.attr._flutter_line[FlutterLineInfo].line
