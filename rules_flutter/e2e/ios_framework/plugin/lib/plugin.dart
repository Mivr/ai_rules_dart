/// Dart side of the first-party iOS plugin.
///
/// The native framework's marker is the same string, so the e2e test can prove
/// the plugin xcframework carries this workspace's compiled plugin.
library;

/// Marker shared with `ios/Classes/IosFrameworkPlugin.swift`.
const String iosFrameworkPluginMarker =
    'rules_flutter_ios_framework_plugin_marker';
