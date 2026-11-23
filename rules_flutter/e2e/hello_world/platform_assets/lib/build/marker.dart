/// COV-76 marker: a `lib/build/` file the path spoke must mirror.
///
/// `flutter_tools` takes all of `lib/`, so `lib/build/` is a normal
/// importable directory. The spoke used to skip it like package-root
/// build output; importing this file proves it mirrors instead.
library;

/// Symbol the hello_world widget test imports to prove `lib/build/`
/// mirrors into the `platform_assets` spoke.
const platformAssetsBuildMarker = 'platform_assets lib/build marker';
