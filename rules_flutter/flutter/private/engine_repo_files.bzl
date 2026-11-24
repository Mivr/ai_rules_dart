"""File lists of the engine and SDK artifacts that `flutter/repositories.bzl` relocates.

Each list names the paths a lazy repository moves out of the downloaded archive.
"""

visibility(["//flutter/..."])

PATCHED_SDK_PRODUCT_FILES = [
    "patched-sdk-product/LICENSE.flutter_patched_sdk.md",
    "patched-sdk-product/flutter_patched_sdk_product/platform_strong.dill",
    "patched-sdk-product/flutter_patched_sdk_product/vm_outline_strong.dill",
]

FONT_SUBSET_BASE_FILES = [
    "font-subset-tools/LICENSE.font_subset.md",
    "font-subset-tools/const_finder.dart.snapshot",
]

MATERIAL_FONTS_FILES = [
    "material-fonts/MaterialIcons-Regular.otf",
    "material-fonts/MaterialIcons_LICENSE.txt",
    "material-fonts/Roboto-Black.ttf",
    "material-fonts/Roboto-BlackItalic.ttf",
    "material-fonts/Roboto-Bold.ttf",
    "material-fonts/Roboto-BoldItalic.ttf",
    "material-fonts/Roboto-Italic.ttf",
    "material-fonts/Roboto-Light.ttf",
    "material-fonts/Roboto-LightItalic.ttf",
    "material-fonts/Roboto-Medium.ttf",
    "material-fonts/Roboto-MediumItalic.ttf",
    "material-fonts/Roboto-Regular.ttf",
    "material-fonts/Roboto-Thin.ttf",
    "material-fonts/Roboto-ThinItalic.ttf",
    "material-fonts/RobotoCondensed-Bold.ttf",
    "material-fonts/RobotoCondensed-BoldItalic.ttf",
    "material-fonts/RobotoCondensed-Italic.ttf",
    "material-fonts/RobotoCondensed-Light.ttf",
    "material-fonts/RobotoCondensed-LightItalic.ttf",
    "material-fonts/RobotoCondensed-Regular.ttf",
    "material-fonts/RobotoCondensed_LICENSE.txt",
    "material-fonts/Roboto_LICENSE.txt",
    "material-fonts/codepoints",
]

HOST_TOOLS_RELEASE_FILES = [
    "host-tools-release/LICENSE.artifacts.md",
    "host-tools-release/gen_snapshot",
]

LINUX_ENGINE_REL_FILES = [
    "LICENSE.flutter_gtk.md",
    "flutter_linux/fl_application.h",
    "flutter_linux/fl_basic_message_channel.h",
    "flutter_linux/fl_binary_codec.h",
    "flutter_linux/fl_binary_messenger.h",
    "flutter_linux/fl_dart_project.h",
    "flutter_linux/fl_engine.h",
    "flutter_linux/fl_event_channel.h",
    "flutter_linux/fl_json_message_codec.h",
    "flutter_linux/fl_json_method_codec.h",
    "flutter_linux/fl_message_codec.h",
    "flutter_linux/fl_method_call.h",
    "flutter_linux/fl_method_channel.h",
    "flutter_linux/fl_method_codec.h",
    "flutter_linux/fl_method_response.h",
    "flutter_linux/fl_pixel_buffer_texture.h",
    "flutter_linux/fl_plugin_registrar.h",
    "flutter_linux/fl_plugin_registry.h",
    "flutter_linux/fl_standard_message_codec.h",
    "flutter_linux/fl_standard_method_codec.h",
    "flutter_linux/fl_string_codec.h",
    "flutter_linux/fl_texture.h",
    "flutter_linux/fl_texture_gl.h",
    "flutter_linux/fl_texture_registrar.h",
    "flutter_linux/fl_value.h",
    "flutter_linux/fl_view.h",
    "flutter_linux/flutter_linux.h",
    "gen_snapshot",
    "libflutter_linux_gtk.so",
]

MACOS_FRAMEWORK_HEADERS = [
    "FlutterAppDelegate.h",
    "FlutterAppLifecycleDelegate.h",
    "FlutterBinaryMessenger.h",
    "FlutterChannels.h",
    "FlutterCodecs.h",
    "FlutterDartProject.h",
    "FlutterEngine.h",
    "FlutterHourFormat.h",
    "FlutterMacOS.h",
    "FlutterMacros.h",
    "FlutterPlatformViews.h",
    "FlutterPluginMacOS.h",
    "FlutterPluginRegistrarMacOS.h",
    "FlutterTexture.h",
    "FlutterViewController.h",
]

MACOS_FRAMEWORK_VERSION_REL_FILES = [
    "FlutterMacOS",
    "Modules/module.modulemap",
    "Resources/Info.plist",
    "Resources/PrivacyInfo.xcprivacy",
    "Resources/icudtl.dat",
] + ["Headers/" + h for h in MACOS_FRAMEWORK_HEADERS]

MACOS_ENGINE_REL_FILES = [
    "FlutterMacOS.framework/" + prefix + rel
    for prefix in ("", "Versions/A/", "Versions/Current/")
    for rel in MACOS_FRAMEWORK_VERSION_REL_FILES
] + [
    "FlutterMacOS.framework/Versions/A/_CodeSignature/CodeResources",
    "FlutterMacOS.framework/Versions/Current/_CodeSignature/CodeResources",
]

WINDOWS_ENGINE_COMMON_REL_FILES = [
    "LICENSE.windows_flutter.md",
    "flutter_export.h",
    "flutter_messenger.h",
    "flutter_plugin_registrar.h",
    "flutter_texture_registrar.h",
    "flutter_windows.dll",
    "flutter_windows.dll.exp",
    "flutter_windows.dll.lib",
    "flutter_windows.dll.pdb",
    "flutter_windows.h",
]

WINDOWS_ENGINE_RELEASE_REL_FILES = WINDOWS_ENGINE_COMMON_REL_FILES + [
    "gen_snapshot.exe",
]
