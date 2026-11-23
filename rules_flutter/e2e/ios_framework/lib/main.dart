import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Root widget of the add-to-app example.
class MyApp extends StatelessWidget {
  /// Creates the add-to-app example's root widget.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Hello from the iOS framework example')),
      ),
    );
  }
}
