import 'package:conformance/apk.dart';
import 'package:conformance/compare.dart';
import 'package:conformance/normalise.dart';
import 'package:test/test.dart';

const _resources = '''
Binary APK
Package name=dev.rdf.counter id=7f
  type mipmap id=01 entryCount=1
    resource 0x7f010000 mipmap/ic_launcher
      (mdpi) (file) res/mipmap-mdpi-v4/ic_launcher.png type=PNG
      (hdpi) (file) res/mipmap-hdpi-v4/ic_launcher.png type=PNG
  type style id=02 entryCount=1
    resource 0x7f020000 style/LaunchTheme PUBLIC
      () (style) size=1 parent=@android:style/Theme.Light.NoTitleBar
        android:windowBackground(0x01010054)=@0x7f010000
''';

const _ns = 'http://schemas.android.com/apk/res/android';

String _manifest({String label = '"counter"', bool twoPermissions = true}) =>
    '''
N: android=$_ns (line=2)
  E: manifest (line=2)
    A: $_ns:versionCode(0x0101021b)=1
    A: package="dev.rdf.counter" (Raw: "dev.rdf.counter")
      E: uses-sdk (line=5)
        A: $_ns:minSdkVersion(0x0101020c)=24
${twoPermissions ? '''      E: uses-permission (line=9)
        A: $_ns:name(0x01010003)="android.permission.INTERNET" (Raw: "android.permission.INTERNET")
''' : ''}      E: uses-permission (line=11)
        A: $_ns:name(0x01010003)="dev.rdf.counter.P" (Raw: "dev.rdf.counter.P")
      E: application (line=31)
        A: $_ns:label(0x01010001)=$label (Raw: $label)
        A: $_ns:icon(0x01010002)=@0x7f010000
          E: activity (line=36)
            A: $_ns:name(0x01010003)="dev.rdf.counter.MainActivity" (Raw: "dev.rdf.counter.MainActivity")
              E: intent-filter (line=56)
                  E: action (line=57)
                    A: $_ns:name(0x01010003)="android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")
''';

void main() {
  group('resourceItems', () {
    test('one item per resource and configuration, ids named', () {
      final applied = Applied();
      final r = resourceItems(_resources, applied);
      expect(r.names, {
        '0x7f010000': 'mipmap/ic_launcher',
        '0x7f020000': 'style/LaunchTheme',
      });
      expect(
        {for (final e in r.items.entries) e.key: e.value.digest},
        {
          'res:mipmap/ic_launcher (mdpi)':
              '(file) res/mipmap-mdpi-v4/ic_launcher.png type=PNG',
          'res:mipmap/ic_launcher (hdpi)':
              '(file) res/mipmap-hdpi-v4/ic_launcher.png type=PNG',
          'res:style/LaunchTheme ()':
              '(style) size=1 parent=@android:style/Theme.Light.NoTitleBar\n'
              'android:windowBackground(0x01010054)=@mipmap/ic_launcher',
        },
      );
      expect(applied.counts['resource-ids'], 1);
    });
  });

  test('the symbols of an attr resource are compared in name order', () {
    String attr(List<String> symbols) =>
        '''
Package name=p id=7f
  type attr id=01 entryCount=1
    resource 0x7f010000 attr/fontStyle
      () (attr) type=enum size=2
${symbols.map((s) => '        $s').join('\n')}
''';
    final applied = Applied();
    final a = resourceItems(attr(['normal=0x0', 'italic=0x1']), applied);
    final b = resourceItems(attr(['italic=0x1', 'normal=0x0']), applied);
    expect(diffItems(a.items, b.items).differences, isEmpty);
    expect(applied.counts['attr-symbol-order'], 1);
  });

  group('manifestItems', () {
    final names = {'0x7f010000': 'mipmap/ic_launcher'};

    test('flattens elements and attributes with stable names', () {
      final Items items = manifestItems(_manifest(), names, Applied());
      expect(
        {for (final e in items.entries) e.key: e.value.digest},
        {
          'manifest:manifest': 'present',
          'manifest:manifest@android:versionCode': '1',
          'manifest:manifest@package': '"dev.rdf.counter"',
          'manifest:manifest/uses-sdk': 'present',
          'manifest:manifest/uses-sdk@android:minSdkVersion': '24',
          'manifest:manifest/uses-permission[android.permission.INTERNET]':
              'present',
          'manifest:manifest/uses-permission[android.permission.INTERNET]@android:name':
              '"android.permission.INTERNET"',
          'manifest:manifest/uses-permission[dev.rdf.counter.P]': 'present',
          'manifest:manifest/uses-permission[dev.rdf.counter.P]@android:name':
              '"dev.rdf.counter.P"',
          'manifest:manifest/application': 'present',
          'manifest:manifest/application@android:label': '"counter"',
          'manifest:manifest/application@android:icon': '@mipmap/ic_launcher',
          'manifest:manifest/application/activity[dev.rdf.counter.MainActivity]':
              'present',
          'manifest:manifest/application/activity[dev.rdf.counter.MainActivity]@android:name':
              '"dev.rdf.counter.MainActivity"',
          'manifest:manifest/application/activity[dev.rdf.counter.MainActivity]/intent-filter':
              'present',
          'manifest:manifest/application/activity[dev.rdf.counter.MainActivity]/intent-filter/action[android.intent.action.MAIN]':
              'present',
          'manifest:manifest/application/activity[dev.rdf.counter.MainActivity]/intent-filter/action[android.intent.action.MAIN]@android:name':
              '"android.intent.action.MAIN"',
        },
      );
    });

    test('one changed attribute is exactly one difference', () {
      final diff = diffItems(
        manifestItems(_manifest(), names, Applied()),
        manifestItems(_manifest(label: '"counter2"'), names, Applied()),
      );
      expect(
        [for (final d in diff.differences) '${d.item} ${d.cause}'],
        ['manifest:manifest/application@android:label manifest: differs'],
      );
    });

    test('element order does not matter for named elements', () {
      final String reordered = _manifest().replaceFirst(
        RegExp(r'      E: uses-permission \(line=9\)\n.*\n', multiLine: true),
        '',
      );
      final diff = diffItems(
        manifestItems(_manifest(twoPermissions: false), names, Applied()),
        manifestItems(reordered, names, Applied()),
      );
      expect(diff.differences, isEmpty);
    });
  });

  test('dexClasses lists class descriptors once each', () {
    const dump = '''
Processing 'classes.dex'...
Class #0            -
  Class descriptor  : 'Lb/B;'
  Superclass        : 'Ljava/lang/Object;'
Class #1            -
  Class descriptor  : 'La/A;'
Processing 'classes2.dex'...
  Class descriptor  : 'La/A;'
''';
    expect(dexClasses(dump), ['La/A;', 'Lb/B;']);
  });

  test('exportedSymbols sorts and drops blanks', () {
    expect(exportedSymbols('b\n\na\nb\n'), ['a', 'b']);
  });
}
