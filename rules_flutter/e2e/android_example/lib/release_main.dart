import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the release fixtures. `:app_release` obfuscates this
/// program and `:app_release_plain` does not, so the test can tell identifiers
/// that obfuscation renamed from identifiers that were never there.
class MyApp extends StatelessWidget {
  /// Creates the release fixtures' root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // One MaterialIcons glyph, so tree shaking has a font to subset.
              Icon(Icons.rocket_launch),
              ObfuscationCanaryRelease(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Canary identifier. Obfuscation renames identifiers, not string constants,
/// so the canary is a class name: absent from an obfuscated `libapp.so`,
/// present in the un-obfuscated twin's. It is a widget that the tree above
/// builds, so the AOT compiler keeps the class the way it keeps `MyApp`.
class ObfuscationCanaryRelease extends StatelessWidget {
  /// Creates the canary.
  const ObfuscationCanaryRelease({super.key});

  @override
  Widget build(BuildContext context) => const Text('release fixture');
}
