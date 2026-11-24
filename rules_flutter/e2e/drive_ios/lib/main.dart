import 'package:flutter/material.dart';

void main() {
  runApp(const DriveApp());
}

/// The app both `flutter_drive_test` targets launch on the iOS simulator.
class DriveApp extends StatelessWidget {
  /// Creates the drive app.
  const DriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('drive ios', key: ValueKey('drive_label'))),
      ),
    );
  }
}
