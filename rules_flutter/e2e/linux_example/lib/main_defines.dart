import 'package:defines_env/defines_env.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const DefinesApp());
}

/// An app whose title shows the environment its dependency compiled with.
class DefinesApp extends StatelessWidget {
  /// Creates the app.
  const DefinesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Defines',
      home: Scaffold(body: Center(child: Text('Defines $defcfgSummary'))),
    );
  }
}
