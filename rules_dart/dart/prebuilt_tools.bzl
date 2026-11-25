"""What another rule set needs to ship its own tools prebuilt, as rules_dart does.

See `//dart/private:prebuilt_tools.bzl`: the table a release writes, the
switch (`--repo_env=RULES_DART_TOOLS=source`) that turns every table off, the
rule an archive repository declares each tool with, and the AOT snapshot
tools of rules_dart (`SNAPSHOT_TOOLS`) a Dart toolchain carries prebuilt for
its own SDK: an archive of another rule set that holds them, built by the
SDK its toolchain declares, passes `prebuilt_tools` to
`declare_dart_sdk_toolchains`.
"""

load(
    "//dart/private:prebuilt_tools.bzl",
    _PREBUILT_TOOLS = "PREBUILT_TOOLS",
    _PREBUILT_TOOLS_ENV = "PREBUILT_TOOLS_ENV",
    _SNAPSHOT_TOOLS = "SNAPSHOT_TOOLS",
    _prebuilt_dart_tool = "prebuilt_dart_tool",
    _prebuilt_tools_table = "prebuilt_tools_table",
)

visibility("public")

PREBUILT_TOOLS = _PREBUILT_TOOLS
PREBUILT_TOOLS_ENV = _PREBUILT_TOOLS_ENV
SNAPSHOT_TOOLS = _SNAPSHOT_TOOLS
prebuilt_dart_tool = _prebuilt_dart_tool
prebuilt_tools_table = _prebuilt_tools_table
