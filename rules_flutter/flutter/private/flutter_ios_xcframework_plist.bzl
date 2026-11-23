"""Info.plist rendering for add-to-app iOS xcframeworks.

Split out of `flutter_ios_xcframework.bzl` so the assembly rule stays under the
file size limit. Everything here is pure text generation: the per-slice
framework `Info.plist` and the xcframework-level `Info.plist` whose
`AvailableLibraries` lists exactly the device slice and the simulator slice.
"""

visibility(["//flutter/..."])

IOS_DEVICE = "ios-arm64"
IOS_SIMULATOR = "ios-arm64_x86_64-simulator"
_DEVICE_ARCHITECTURES = ["arm64"]
_SIMULATOR_ARCHITECTURES = ["arm64", "x86_64"]

def framework_info_plist(name, minimum_os_version, bundle_id):
    """Renders the `Info.plist` every framework slice carries.

    Args:
        name: The framework name, used as executable and bundle name.
        minimum_os_version: The `MinimumOSVersion` value.
        bundle_id: The `CFBundleIdentifier` value.

    Returns:
        The plist text.
    """
    return "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>CFBundleDevelopmentRegion</key>",
        "    <string>en</string>",
        "    <key>CFBundleExecutable</key>",
        "    <string>%s</string>" % name,
        "    <key>CFBundleIdentifier</key>",
        "    <string>%s</string>" % bundle_id,
        "    <key>CFBundleInfoDictionaryVersion</key>",
        "    <string>6.0</string>",
        "    <key>CFBundleName</key>",
        "    <string>%s</string>" % name,
        "    <key>CFBundlePackageType</key>",
        "    <string>FMWK</string>",
        "    <key>CFBundleShortVersionString</key>",
        "    <string>1.0</string>",
        "    <key>CFBundleVersion</key>",
        "    <string>1.0</string>",
        "    <key>MinimumOSVersion</key>",
        "    <string>%s</string>" % minimum_os_version,
        "</dict>",
        "</plist>",
        "",
    ])

def _library_entry(path, identifier, architectures, variant):
    """Builds one `AvailableLibraries` entry."""
    lines = [
        "        <dict>",
        "            <key>LibraryIdentifier</key>",
        "            <string>%s</string>" % identifier,
        "            <key>LibraryPath</key>",
        "            <string>%s</string>" % path,
        "            <key>SupportedArchitectures</key>",
        "            <array>",
    ]
    for arch in architectures:
        lines.extend(["                <string>%s</string>" % arch])
    lines.extend([
        "            </array>",
        "            <key>SupportedPlatform</key>",
        "            <string>ios</string>",
    ])
    if variant:
        lines.extend([
            "            <key>SupportedPlatformVariant</key>",
            "            <string>%s</string>" % variant,
        ])
    lines.append("        </dict>")
    return lines

def _xcframework_plist_text(entries):
    """Renders the xcframework-level `Info.plist` from its library entries."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>AvailableLibraries</key>",
        "    <array>",
    ]
    for entry in entries:
        lines.extend(entry)
    lines.extend([
        "    </array>",
        "    <key>CFBundlePackageType</key>",
        "    <string>XFWK</string>",
        "    <key>XCFrameworkFormatVersion</key>",
        "    <string>1.0</string>",
        "</dict>",
        "</plist>",
        "",
    ])
    return "\n".join(lines)

def _device_and_simulator_entries(framework_name):
    """The two library entries every add-to-app xcframework carries.

    `LibraryPath` is relative to the slice's `LibraryIdentifier` directory.
    """
    return [
        _library_entry(
            "%s.framework" % framework_name,
            IOS_DEVICE,
            _DEVICE_ARCHITECTURES,
            "",
        ),
        _library_entry(
            "%s.framework" % framework_name,
            IOS_SIMULATOR,
            _SIMULATOR_ARCHITECTURES,
            "simulator",
        ),
    ]

def xcframework_info_plist(framework_name):
    """Renders the xcframework-level `Info.plist` for a two-slice framework.

    Args:
        framework_name: The framework (without extension) the slices hold.

    Returns:
        The plist text listing the device and the simulator library.
    """
    return _xcframework_plist_text(_device_and_simulator_entries(framework_name))
