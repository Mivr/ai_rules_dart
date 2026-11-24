/// Finds out from `.bzl` source whether a function returns a value, which the
/// extract does not record: it keeps a `Returns:` section only when one is
/// written.
library;

import 'dart:io';

import 'failure.dart';

import 'rules.dart' show ReturnsValue;

final _def = RegExp(r'^def\s+(\w+)\s*\(');
final _returnValue = RegExp(r'^\s+return\s+(?!None\b)\S');
final _nestedDef = RegExp(r'^(\s+)def\s');

/// The names of the module-level functions in [source] that return a value.
///
/// A `return` inside a nested `def` or inside a triple-quoted string does not
/// count towards the enclosing function.
Set<String> valueReturningFunctions(String source) {
  final found = <String>{};
  String? current;
  String? quote;
  int? nestedIndent;
  for (final String line in source.split('\n')) {
    final opened = quote != null;
    quote = _quoteAfter(line, quote);
    if (opened || (quote != null && !line.contains(_def))) continue;
    final RegExpMatch? def = _def.firstMatch(line);
    if (def != null) {
      current = def[1];
      nestedIndent = null;
    } else if (line.isNotEmpty &&
        !line.startsWith(' ') &&
        !line.startsWith('\t')) {
      if (!line.startsWith(')') && !line.startsWith('#')) current = null;
    } else if (current != null) {
      nestedIndent = _afterNested(line, nestedIndent);
      if (nestedIndent == null && _returnValue.hasMatch(line)) {
        found.add(current);
      }
    }
  }
  return found;
}

/// The indent of the nested `def` still open after [line], or null.
int? _afterNested(String line, int? open) {
  final int indent = line.length - line.trimLeft().length;
  if (open != null && (line.trim().isEmpty || indent > open)) return open;
  final RegExpMatch? nested = _nestedDef.firstMatch(line);
  return nested == null ? null : nested[1]!.length;
}

/// The triple-quote delimiter still open at the end of [line], or null.
String? _quoteAfter(String line, String? open) {
  var state = open;
  for (final delimiter in const ['"""', "'''"]) {
    var from = 0;
    while (true) {
      final int at = line.indexOf(delimiter, from);
      if (at < 0) break;
      if (state == null) {
        state = delimiter;
      } else if (state == delimiter) {
        state = null;
      }
      from = at + 3;
    }
  }
  return state;
}

/// Reads `.bzl` sources below a root and answers [ReturnsValue] queries.
class SourceReturns {
  /// Resolves labels such as `//flutter/private:x.bzl` below [root].
  new(this.root);

  /// The directory holding the main repository's tree.
  final String root;

  final Map<String, Set<String>> _cache = {};

  /// Whether function [name] in the file labelled [label] returns a value.
  ///
  /// Throws [DocCheckFailure] naming the file when it cannot be read: a check that
  /// cannot see the source must fail rather than pass blindly.
  bool call(String label, String name) {
    final Set<String> functions = _cache.putIfAbsent(label, () => _load(label));
    return functions.contains(name);
  }

  Set<String> _load(String label) {
    final RegExpMatch? match = RegExp(r'^//([^:]*):(.+)$').firstMatch(label);
    if (match == null) {
      throw DocCheckFailure('cannot locate source for label $label');
    }
    final String dir = match[1]!;
    final file = File('$root/${dir.isEmpty ? '' : '$dir/'}${match[2]}');
    if (!file.existsSync()) {
      throw DocCheckFailure('source for $label is missing: ${file.path}');
    }
    return valueReturningFunctions(file.readAsStringSync());
  }
}
