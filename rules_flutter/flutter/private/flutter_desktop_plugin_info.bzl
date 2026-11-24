"""Per-platform providers for Flutter desktop plugin source bundles.

Re-exports `FlutterLinuxPluginInfo` and `FlutterWindowsPluginInfo` from
`//flutter:providers.bzl` for internal desktop plugin and runner rules.
"""

load(
    "//flutter:providers.bzl",
    _FlutterLinuxPluginInfo = "FlutterLinuxPluginInfo",
    _FlutterWindowsPluginInfo = "FlutterWindowsPluginInfo",
)

visibility(["//flutter/..."])

FlutterLinuxPluginInfo = _FlutterLinuxPluginInfo
FlutterWindowsPluginInfo = _FlutterWindowsPluginInfo
