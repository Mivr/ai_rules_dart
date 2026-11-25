"""What another rule set needs to ship its own tools prebuilt, as rules_dart does.

See `//dart/private:prebuilt_tools.bzl`: the table a release writes, the
switch (`--repo_env=RULES_DART_TOOLS=source`) that turns every table off, and
the rule an archive repository declares each tool with.
"""

load(
    "//dart/private:prebuilt_tools.bzl",
    _PREBUILT_TOOLS_ENV = "PREBUILT_TOOLS_ENV",
    _prebuilt_dart_tool = "prebuilt_dart_tool",
    _prebuilt_tools_table = "prebuilt_tools_table",
)

visibility("public")

PREBUILT_TOOLS_ENV = _PREBUILT_TOOLS_ENV
prebuilt_dart_tool = _prebuilt_dart_tool
prebuilt_tools_table = _prebuilt_tools_table
