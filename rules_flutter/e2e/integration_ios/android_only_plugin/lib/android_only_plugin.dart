/// An Android-only plugin, declared beside the app's iOS plugins.
///
/// It has no `dartPluginClass`, no Apple library and no iOS metadata: the
/// generated iOS native registrant must not import it or register it, while
/// the app still builds and runs with the package in its `deps`.
library;

/// A Dart-side marker proving the package is part of the app's dependency
/// graph in every configuration, including the iOS simulator run.
const String androidOnlyPluginMarker = 'android-only-plugin';
