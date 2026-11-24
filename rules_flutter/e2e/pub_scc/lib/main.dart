import 'package:acyclic_pkg/acyclic_pkg.dart';
import 'package:cycle_a/cycle_a.dart';
import 'package:cycle_b/cycle_b.dart';
import 'package:flutter/material.dart';

void main() {
  final message = '${getAcyclic()}: ${getCycleA()} & ${getCycleB()}';
  runApp(
    MaterialApp(
      home: Scaffold(body: Center(child: Text(message))),
    ),
  );
}
