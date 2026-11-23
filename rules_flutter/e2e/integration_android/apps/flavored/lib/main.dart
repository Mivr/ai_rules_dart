/// Flavored test app for the Android flavor proof.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Entry point of the flavored app.
void main() {
  runApp(const FlavoredApp());
}

/// Minimal app showing the current appFlavor.
class FlavoredApp extends StatelessWidget {
  /// Creates the flavored app widget.
  const FlavoredApp({super.key});

  @override
  Widget build(BuildContext context) {
    const flavor = appFlavor ?? 'none';
    return const MaterialApp(
      title: flavor,
      home: Scaffold(
        body: Center(
          child: Text(flavor),
        ),
      ),
    );
  }
}
