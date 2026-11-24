/// Items for an Android APK, read with the SDK's own tools: `jar` (JDK) to
/// unpack, `aapt2 dump` for the manifest and the resource table, `dexdump`
/// for the classes, `llvm-nm` (NDK) for the native libraries' exports.
///
/// Categories: `manifest:` (one item per element and per attribute), `res:`
/// (one per resource and configuration), `dex:` (one per class), `native:`
/// (one per library, valued by its exported symbols), `asset:` (one per file
/// under `assets/flutter_assets/`), `compiled:` (the kernel or AOT snapshot),
/// `entry:` (every other entry, by content).
library;

import 'dart:convert';
import 'dart:io';

import 'package:conformance/compare.dart';
import 'package:conformance/normalise.dart';
import 'package:conformance/tree.dart';
import 'package:crypto/crypto.dart';

/// Paths of the tools that read an APK.
class AndroidTools {
  const AndroidTools({
    required this.jar,
    required this.aapt2,
    required this.dexdump,
    required this.nm,
  });

  /// From `JAVA_HOME`, `ANDROID_HOME` (its newest build-tools) and
  /// `ANDROID_NDK_HOME`, or null when one is missing.
  static AndroidTools? fromEnvironment(Map<String, String> env) {
    final String? java = env['JAVA_HOME'];
    final String? sdk = env['ANDROID_HOME'];
    final String? ndk = env['ANDROID_NDK_HOME'];
    if (java == null || sdk == null || ndk == null) return null;
    final buildTools = Directory('$sdk/build-tools');
    if (!buildTools.existsSync()) return null;
    final List<String> versions = [
      for (final d in buildTools.listSync())
        if (d is Directory) d.path,
    ]..sort();
    if (versions.isEmpty) return null;
    return AndroidTools(
      jar: '$java/bin/jar',
      aapt2: '${versions.last}/aapt2',
      dexdump: '${versions.last}/dexdump',
      nm: '$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm',
    );
  }

  final String jar;
  final String aapt2;
  final String dexdump;
  final String nm;
}

String _run(List<String> cmd, {String? cwd}) {
  final ProcessResult r = Process.runSync(
    cmd.first,
    cmd.sublist(1),
    workingDirectory: cwd,
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
    stderrEncoding: const Utf8Codec(allowMalformed: true),
  );
  if (r.exitCode != 0) {
    throw ProcessException(
      cmd.first,
      cmd.sublist(1),
      '${r.stderr}',
      r.exitCode,
    );
  }
  return r.stdout as String;
}

/// Exported dynamic symbols of an ELF file, sorted, or null when `llvm-nm`
/// cannot read it.
List<String>? readElfExports(String nm, File elf) {
  try {
    return exportedSymbols(_run([nm, '-D', '--defined-only', '-j', elf.path]));
  } on ProcessException {
    return null;
  }
}

/// The symbol names of `llvm-nm -j` output, sorted and unique.
List<String> exportedSymbols(String nmOutput) => {
  for (final l in const LineSplitter().convert(nmOutput))
    if (l.trim().isNotEmpty) l.trim(),
}.toList()..sort();

/// Items of [apk], unpacked into [scratch] (emptied first).
Items apkItems(
  File apk,
  AndroidTools tools,
  Directory scratch,
  Applied applied,
) {
  if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  scratch.createSync(recursive: true);
  _run([tools.jar, 'xf', apk.absolute.path], cwd: scratch.path);
  applied.hit(archiveLayout);

  final resources = resourceItems(
    _run([tools.aapt2, 'dump', 'resources', apk.path]),
    applied,
  );
  final items = <String, Value>{
    ...resources.items,
    ...manifestItems(
      _run([
        tools.aapt2,
        'dump',
        'xmltree',
        '--file',
        'AndroidManifest.xml',
        apk.path,
      ]),
      resources.names,
      applied,
    ),
  };
  final dexFiles = <String>[];
  for (final entry in listFiles(scratch)) {
    final file = File('${scratch.path}/$entry');
    if (isSigningEntry(entry)) {
      applied.hit(apkSigning);
    } else if (entry == 'AndroidManifest.xml' || entry == 'resources.arsc') {
      continue;
    } else if (RegExp(r'^classes\d*\.dex$').hasMatch(entry)) {
      dexFiles.add(file.path);
    } else if (entry.startsWith('lib/') && entry.endsWith('.so')) {
      final List<String>? symbols = readElfExports(tools.nm, file);
      items['native:$entry'] = symbols == null
          ? Value(fileDigest(file), '${file.lengthSync()} B')
          : Value(
              sha256.convert(utf8.encode(symbols.join('\n'))).toString(),
              '${symbols.length} exported symbols, ${file.lengthSync()} B',
            );
    } else if (entry.startsWith('assets/flutter_assets/')) {
      final String asset = entry.substring('assets/flutter_assets/'.length);
      final String category =
          const {
            'kernel_blob.bin',
            'isolate_snapshot_data',
            'vm_snapshot_data',
          }.contains(asset)
          ? 'compiled'
          : 'asset';
      items['$category:$asset'] = Value(
        _assetDigest(file, applied),
        '${file.lengthSync()} B',
      );
    } else {
      items['entry:$entry'] = Value(fileDigest(file), '${file.lengthSync()} B');
    }
  }
  if (dexFiles.isNotEmpty) {
    applied.hit(dexClassSet);
    for (final c in dexClasses(_run([tools.dexdump, ...dexFiles]))) {
      items['dex:$c'] = const Value('present');
    }
  }
  return items;
}

String _assetDigest(File f, Applied applied) {
  if (f.path.endsWith('.json')) {
    final String? canonical = canonicalJson(
      f.readAsStringSync(encoding: const Utf8Codec(allowMalformed: true)),
    );
    if (canonical != null) {
      applied.hit(jsonFormat);
      return sha256.convert(utf8.encode(canonical)).toString();
    }
  }
  return fileDigest(f);
}

/// Class descriptors in `dexdump` output, sorted and unique.
List<String> dexClasses(String dexdump) {
  final re = RegExp(r"^\s*Class descriptor\s*:\s*'([^']+)'", multiLine: true);
  return {for (final m in re.allMatches(dexdump)) m.group(1)!}.toList()..sort();
}

/// Items of `aapt2 dump resources`: `res:<type>/<name> <config>`, valued by
/// what that configuration holds; plus the map from each app resource id
/// (`0x7f...`) to its `type/name`, for [resourceIds].
({Items items, Map<String, String> names}) resourceItems(
  String dump,
  Applied applied,
) {
  final names = <String, String>{};
  final header = RegExp(r'^\s*resource (0x[0-9a-f]{8}) (\S+)');
  for (final l in const LineSplitter().convert(dump)) {
    if (header.firstMatch(l) case final m?) names[m.group(1)!] = m.group(2)!;
  }
  final items = <String, Value>{};
  String? resource;
  String? config;
  int configIndent = 0;
  final buffer = <String>[];
  void flush() {
    if (resource != null && config != null) {
      if (buffer.length > 2 && buffer.first.startsWith('(attr)')) {
        final List<String> symbols = buffer.sublist(1)..sort();
        if (symbols.join() != buffer.sublist(1).join()) {
          applied.hit(attrSymbolOrder);
        }
        buffer.replaceRange(1, buffer.length, symbols);
      }
      final String text = buffer.join('\n');
      items['res:$resource $config'] = Value(text, _clip(text));
    }
    buffer.clear();
    config = null;
  }

  for (final l in const LineSplitter().convert(dump)) {
    final int indent = l.length - l.trimLeft().length;
    final String t = l.trim();
    if (header.firstMatch(l) case final m?) {
      flush();
      resource = m.group(2);
      continue;
    }
    if (t.startsWith('type ') || t.startsWith('Package ') || t.isEmpty) {
      flush();
      if (!t.startsWith('resource')) resource = null;
      continue;
    }
    if (resource == null) continue;
    final String line = _resolveIds(t, names, applied);
    if (config == null || indent <= configIndent) {
      flush();
      final int close = line.indexOf(')');
      config = close < 0 ? '()' : line.substring(0, close + 1);
      configIndent = indent;
      buffer.add(line.substring(config!.length).trim());
    } else {
      buffer.add(line);
    }
  }
  flush();
  return (items: items, names: names);
}

/// Items of `aapt2 dump xmltree` of the manifest: one per element
/// (`manifest:manifest/application/activity[.Main]`) and one per attribute
/// (`...@android:exported`). An element is named by its `android:name`, or
/// by its position among its unnamed siblings of the same tag.
Items manifestItems(String dump, Map<String, String> names, Applied applied) {
  final root = _Element('', -1);
  final stack = <_Element>[root];
  final elem = RegExp(r'^E: (\S+)(?: \(line=\d+\))?$');
  final attr = RegExp(r'^A: (.+?)=(.*)$');
  for (final l in const LineSplitter().convert(dump)) {
    final int indent = l.length - l.trimLeft().length;
    final String t = l.trim();
    if (elem.firstMatch(t) case final m?) {
      if (t.contains('(line=')) applied.hit(xmlSourceLines);
      while (stack.last.indent >= indent) {
        stack.removeLast();
      }
      final e = _Element(m.group(1)!, indent);
      stack.last.children.add(e);
      stack.add(e);
    } else if (attr.firstMatch(t) case final m?) {
      var value = m.group(2)!;
      final int raw = value.indexOf(' (Raw: ');
      if (raw >= 0) {
        applied.hit(xmlRawValues);
        value = value.substring(0, raw);
      }
      stack.last.attrs[_attrName(m.group(1)!)] = _resolveIds(
        value,
        names,
        applied,
      );
    }
  }
  final items = <String, Value>{};
  void walk(_Element e, String path) {
    final unnamed = <String, int>{};
    for (final c in e.children) {
      final String? name = c.attrs['android:name'];
      final String id;
      if (name != null) {
        id = '${c.tag}[${name.replaceAll('"', '')}]';
      } else {
        final int n = unnamed[c.tag] = (unnamed[c.tag] ?? -1) + 1;
        id = n == 0 ? c.tag : '${c.tag}#$n';
      }
      final String p = path.isEmpty ? id : '$path/$id';
      items['manifest:$p'] = const Value('present');
      for (final MapEntry(:key, :value) in c.attrs.entries) {
        items['manifest:$p@$key'] = Value(value, value);
      }
      walk(c, p);
    }
  }

  walk(root, '');
  return items;
}

class _Element {
  _Element(this.tag, this.indent);
  final String tag;
  final int indent;
  final Map<String, String> attrs = {};
  final List<_Element> children = [];
}

/// `http://schemas.android.com/apk/res/android:label(0x01010001)` becomes
/// `android:label`.
String _attrName(String raw) {
  var name = raw.replaceFirst(RegExp(r'\(0x[0-9a-f]+\)$'), '');
  const ns = 'http://schemas.android.com/apk/res/android:';
  if (name.startsWith(ns)) name = 'android:${name.substring(ns.length)}';
  return name;
}

/// Replaces app resource ids (`0x7f......`) with their `type/name`.
String _resolveIds(String text, Map<String, String> names, Applied applied) =>
    text.replaceAllMapped(RegExp(r'0x7f[0-9a-f]{6}'), (m) {
      final String? name = names[m.group(0)];
      if (name == null) return m.group(0)!;
      applied.hit(resourceIds);
      return name;
    });

String _clip(String s) {
  final String one = s.replaceAll('\n', ' | ');
  return one.length > 80 ? '${one.substring(0, 80)}...' : one;
}
