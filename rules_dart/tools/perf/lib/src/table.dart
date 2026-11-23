/// The plan's target table (section 1) with a measured "today" for every
/// row, written from ledger rows.
library;

import 'growth_fit.dart';
import 'ledger.dart';

/// Mnemonics of actions that build Dart or package the app, not native code.
const dartMnemonics = {
  'DartKernel',
  'DartKernelLink',
  'DartImportCheck',
  'FlutterAndroidDebugAssets',
  'FlutterKernelCompile',
  'RdfApk',
  'RdfZip',
};

String _fmt(Row? r) {
  if (r == null) return 'not run';
  if (r.status == 'not_available') return 'not available here';
  if (r.status != 'ok' || r.median == null) {
    return 'failed (see ledger)';
  }
  final s = [...r.runs]..sort();
  final unit = r.unit == 's' ? ' s' : ' ${r.unit}';
  return '${_n(r.median!)}$unit (${_n(s.first)}–${_n(s.last)}, n=${s.length})${r.noisy ? ' *' : ''}';
}

String _n(double v) => v >= 100
    ? v.toStringAsFixed(0)
    : v >= 10
    ? v.toStringAsFixed(1)
    : v.toStringAsFixed(v >= 1 ? 2 : 3);

/// The rows of [rows] by id, the last one of each id winning.
Map<String, Row> byId(List<Row> rows) => {for (final r in rows) r.id: r};

String? _exponent(Map<String, Row> r, String shape, String mode) {
  final a = r['analysis.${shape}2000.$mode'];
  final b = r['analysis.${shape}5000.$mode'];
  if (a?.median == null || b?.median == null) return null;
  final e = fitGrowthExponent([(2000, a!.median!), (5000, b!.median!)]);
  return '${e.toStringAsFixed(2)}${a.noisy || b.noisy ? ' *' : ''}';
}

String? _ratio(Row? a, Row? b) {
  if (a?.median == null || b?.median == null || b!.median == 0) return null;
  return '${(a!.median! / b.median!).toStringAsFixed(2)}x${a.noisy || b.noisy ? ' *' : ''}';
}

String _native(Row? r) {
  if (r == null || r.status != 'ok') return _fmt(r);
  final native = {
    for (final e in r.mnemonics.entries)
      if (!e.key.endsWith('(cached)') && !dartMnemonics.contains(e.key))
        e.key: e.value,
  };
  return native.isEmpty
      ? 'none (ran: ${r.mnemonics.keys.where((k) => !k.endsWith('(cached)')).join(', ')})'
      : native.entries.map((e) => '${e.key} ${e.value}').join(', ');
}

/// The table as Markdown.
String planTable(List<Row> rows) {
  final r = byId(rows);
  final b = StringBuffer()
    ..writeln('| Flow | Target | Stock | Rules today |')
    ..writeln('|---|---|---|---|');
  void row(String flow, String target, String stock, String today) =>
      b.writeln('| $flow | $target | $stock | $today |');

  for (final shape in ['deep', 'wide']) {
    for (final n in [2000, 5000]) {
      final rules = r['analysis.$shape$n.rules'];
      final aspects = r['analysis.$shape$n.aspects'];
      row(
        'Analysis phase, $n generated libraries, $shape: rules only / with the analyze and format aspects',
        n == 2000
            ? 'aspects at most 2x rules-only'
            : 'growth exponent at most 1.1 up to 5,000',
        '`dart analyze` on the twin, cold: ${_fmt(r['analysis.$shape$n.stock'])}',
        '${_fmt(rules)} / ${_fmt(aspects)}; ratio ${_ratio(aspects, rules) ?? '-'}',
      );
    }
    row(
      'Analysis growth exponent 2,000 to 5,000, $shape',
      'at most 1.1',
      '-',
      'rules only ${_exponent(r, shape, 'rules') ?? '-'}, with aspects ${_exponent(r, shape, 'aspects') ?? '-'}',
    );
  }
  row(
    'Actions registered per source file, library',
    'none',
    '-',
    _fmt(r['actions_per_source.library.rules']),
  );
  row(
    'Actions registered per source file, test (closure)',
    'none',
    '-',
    _fmt(r['actions_per_source.test.rules']),
  );
  row(
    'Dart: leaf body edit to a rebuilt test kernel, small',
    'at most 1 s',
    'no same step',
    _fmt(r['dart.body.small.rules']),
  );
  row(
    'Dart: leaf body edit to a rebuilt test kernel, 500k lines',
    'at most 3 s',
    'no same step',
    _fmt(r['dart.body.500k.rules']),
  );
  row(
    'Dart: leaf API edit to a rebuilt test kernel, small / 500k lines',
    '-',
    'no same step',
    '${_fmt(r['dart.api.small.rules'])} / ${_fmt(r['dart.api.500k.rules'])}',
  );
  for (final (name, id) in [
    ('plain app', 'plain'),
    ('app with defines and a flavor', 'defines'),
    ('app with nine plugins', 'plugins'),
    ('app with native assets (Linux bundle)', 'native_assets'),
    ('500k-line app', '500k'),
  ]) {
    row(
      'Flutter: debug app edit, $name',
      id == '500k' ? 'at most 3 s' : 'at most 1 s',
      id == 'native_assets'
          ? 'no same step (stock runs the sqlite3 hook, which downloads)'
          : '`flutter build bundle --debug`: ${_fmt(r['flutter.$id.stock'])}',
      _fmt(r['flutter.$id.rules']),
    );
  }
  row(
    'Native actions executed after a Dart-only edit (Android, nine plugins)',
    'none',
    '-',
    _native(r['android.dart.rules']),
  );
  row(
    'Dart-only edit, rebuilt Android app (splits), nine plugins',
    'kernel build plus at most 3 s',
    'Gradle: ${_fmt(r['android.dart.stock'])}',
    _fmt(r['android.dart.rules']),
  );
  row(
    'Install after a Dart-only edit, Android emulator',
    'at most 3 s',
    '`adb install -r` of the debug APK: ${_fmt(r['android.install.stock'])}',
    _fmt(r['android.install.rules']),
  );
  row(
    'Dart-only update, iOS simulator',
    'kernel plus at most 1 s',
    'not available here',
    'not available here (no Mac)',
  );
  row(
    'Edit to the app\'s own Kotlin',
    'at most 10 s, and faster than Gradle',
    'Gradle: ${_fmt(r['android.kotlin_app.stock'])}',
    '${_fmt(r['android.kotlin_app.rules'])}; ${_ratio(r['android.kotlin_app.rules'], r['android.kotlin_app.stock']) ?? '-'} of Gradle',
  );
  row(
    'Edit to a plugin\'s Kotlin',
    'faster than Gradle',
    'Gradle: ${_fmt(r['android.kotlin_plugin.stock'])}',
    '${_fmt(r['android.kotlin_plugin.rules'])}; ${_ratio(r['android.kotlin_plugin.rules'], r['android.kotlin_plugin.stock']) ?? '-'} of Gradle',
  );
  row(
    'Edit to the app\'s own Swift',
    'at most 15 s',
    'not available here',
    'not available here (no Mac)',
  );
  final add = r['android.add_plugin.rules'];
  row(
    'Adding one plugin',
    'only that plugin\'s targets rebuild',
    'Gradle: ${_fmt(r['android.add_plugin.stock'])}',
    '${_fmt(add)}${add?.mnemonics.isNotEmpty ?? false ? '; ran: ${add!.mnemonics.entries.map((e) => '${e.key} ${e.value}').join(', ')}' : ''}'
        '${add?.extra['pin_s'] is List ? '; pin ${(add!.extra['pin_s'] as List).join(', ')} s' : ''}',
  );
  row(
    'Nothing changed, Android',
    '-',
    'Gradle: ${_fmt(r['android.nochange.stock'])}',
    _fmt(r['android.nochange.rules']),
  );
  row(
    'Fresh checkout with a warm cache (disk cache here; no remote cache on this host)',
    'no native compile at all',
    '-',
    '${_fmt(r['android.warm_cache.rules'])}; native actions run: ${_native(r['android.warm_cache.rules'])}',
  );
  row(
    'Clean build, warm cache',
    'at most 0.2x the stock tool',
    'Gradle clean: ${_fmt(r['android.clean.stock'])}',
    '${_ratio(r['android.warm_cache.rules'], r['android.clean.stock']) ?? '-'} of Gradle',
  );
  row(
    'Clean build, cold caches, Android nine plugins (5 jobs)',
    'at most 1.2x the stock tool',
    'Gradle, caches kept: ${_fmt(r['android.clean.stock'])}',
    '${_fmt(r['android.clean.rules'])}; ${_ratio(r['android.clean.rules'], r['android.clean.stock']) ?? '-'}',
  );
  for (final (p, k) in [
    ('counter', 'apk'),
    ('counter', 'web'),
    ('flavors_defines', 'apk'),
    ('flavors_defines', 'web'),
    ('large', 'web'),
    ('dart_pkg', 'exe'),
  ]) {
    row(
      'Clean build, cold caches, corpus $p $k',
      'at most 1.2x the stock tool',
      _fmt(r['clean.$p.$k.stock']),
      '${_fmt(r['clean.$p.$k.rules'])}; ${_ratio(r['clean.$p.$k.rules'], r['clean.$p.$k.stock']) ?? '-'}',
    );
  }
  for (final (name, id) in [
    ('small (petitparser)', 'small'),
    ('500k lines', '500k'),
  ]) {
    row(
      'One-file edit, then the package\'s tests, $name',
      'at most 0.2x `dart test`',
      '`dart test`: ${_fmt(r['dart.test.$id.stock'])}',
      '${_fmt(r['dart.test.$id.rules'])}; ${_ratio(r['dart.test.$id.rules'], r['dart.test.$id.stock']) ?? '-'}',
    );
  }
  final addPub = r['pub.add.rules'];
  row(
    'Module resolution, 300-package lock (local mirror)',
    '1 s warm, 15 s cold; adding one package fetches one repository',
    '-',
    'cold ${_fmt(r['pub.cold.rules'])}; warm ${_fmt(r['pub.warm.rules'])}; add ${_fmt(addPub)}'
        '${addPub?.extra['repositories_fetched'] is List ? ', repositories fetched ${(addPub!.extra['repositories_fetched'] as List).join(', ')}' : ''}',
  );
  for (final step in ['start', 'reload', 'restart']) {
    row(
      'Dev loop on the Android emulator: $step',
      step == 'reload' ? 'equal to stock `flutter run`' : '-',
      '`flutter run`: ${_fmt(r['devloop.$step.stock'])}',
      '`flutter_dev run`: ${_fmt(r['devloop.$step.flutter_dev'])}',
    );
  }
  for (final s in ['cold', 'warm', 'edit']) {
    row(
      'Code generation, $s, 200 files',
      '-',
      '`build_runner`: ${_fmt(r['codegen.$s.stock'])}',
      _fmt(r['codegen.$s.rules']),
    );
  }
  row(
    'Linux desktop debug edit, stock',
    '-',
    'not available here',
    _fmt(r['flutter.native_assets.rules']),
  );
  b
    ..writeln()
    ..writeln(
      'Numbers are medians with (min–max, number of runs). `*` marks a row with a run above the load threshold (noisy).',
    );
  return b.toString();
}
