import 'package:flutter/material.dart';

void main() {
  runApp(const AarHostApp());
}

/// Root widget for the Flutter module embedded into the native host app.
class AarHostApp extends StatelessWidget {
  /// Creates the AAR host app.
  const AarHostApp({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Print the exact marker string to logcat for the test harness to assert.
      // ignore: avoid_print
      print('FLUTTER_MARKER_RENDERED: AAR_HOST_MARKER_OK');
    });
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('AAR_HOST_MARKER_OK'),
        ),
      ),
    );
  }
}
