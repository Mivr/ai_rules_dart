/// First-party package that ships the `Cov13Sans` font family.
///
/// `//:app_test` depends on it so the Android app bundles a font family that
/// comes from a package rather than from the app itself.
library;

/// The family name the package declares for its font.
const String cov13FontFamily = 'Cov13Sans';

/// The package name a `TextStyle` passes to resolve [cov13FontFamily].
const String cov13FontPackage = 'cov13font';
