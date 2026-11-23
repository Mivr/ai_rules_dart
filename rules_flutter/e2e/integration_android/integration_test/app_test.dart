import 'dart:convert';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:android_greeting_plugin/android_greeting_plugin.dart';
import 'package:cov13font/cov13font.dart';
import 'package:federated_greeting/federated_greeting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_android/l10n/app_localizations.dart';
import 'package:integration_android/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_asset_plugin/native_asset_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'increments counter, decodes asset image, and calls Android Kotlin plugin',
    (tester) async {
      await tester.pumpWidget(const CounterApp());
      await tester.pumpAndSettle();

      expect(find.text('0'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('app_logo')), findsOneWidget);

      final incrementButton = find.byKey(
        const ValueKey<String>('increment_button'),
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(incrementButton);
        await tester.pump();
      }

      expect(find.text('3'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey<String>('counter_text')))
            .data,
        '3',
      );

      final assetBytes = await rootBundle.load('assets/logo.png');
      final codec = await ui.instantiateImageCodec(
        assetBytes.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      expect(frame.image.height, greaterThan(0));
      frame.image.dispose();
      codec.dispose();

      final greeting = await const AndroidGreetingPlugin().getGreeting();
      expect(greeting, 'Hello from Android Kotlin plugin!');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey<String>('plugin_greeting')))
            .data,
        'Hello from Android Kotlin plugin!',
      );
    },
  );

  testWidgets('calls federated greeting plugin through umbrella', (
    tester,
  ) async {
    final greeting = await const FederatedGreeting().getGreeting();
    const isAlt = bool.fromEnvironment('USE_ALT_GREETING');
    if (isAlt) {
      expect(greeting, 'Hello from alternative federated Android plugin!');
    } else {
      expect(greeting, 'Hello from default federated Android plugin!');
    }
  });

  testWidgets('forwards a define with a comma and an equals sign', (
    tester,
  ) async {
    expect(const String.fromEnvironment('COV13_GREETING'), 'hello, world=ok');
  });

  testWidgets('reads a value defined only in defines_files', (tester) async {
    const isAlt = bool.fromEnvironment('USE_ALT_GREETING');
    expect(
      const String.fromEnvironment('COV15_DEFINE'),
      isAlt ? '' : 'from_defines_file',
    );
  });

  testWidgets('renders the generated Spanish message under Locale es', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Cov13Localizations.localizationsDelegates,
        supportedLocales: Cov13Localizations.supportedLocales,
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: const Locale('es'),
            child: Builder(
              builder: (context) =>
                  Text(Cov13Localizations.of(context).cov13Greeting),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('¡Hola desde el emulador de Android!'), findsOneWidget);
    expect(
      Cov13Localizations.supportedLocales,
      containsAll(<Locale>[const Locale('en'), const Locale('es')]),
    );
  });

  testWidgets('resolves the package font and the MaterialIcons glyph font', (
    tester,
  ) async {
    const packageStyle = TextStyle(
      fontFamily: cov13FontFamily,
      package: cov13FontPackage,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: <Widget>[
            Text(
              'cov13',
              key: ValueKey<String>('package_font'),
              style: packageStyle,
            ),
            Icon(Icons.add, key: ValueKey<String>('material_icon')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paragraph = tester.renderObject<RenderParagraph>(
      find.byKey(const ValueKey<String>('package_font')),
    );
    expect(paragraph.text.style?.fontFamily, 'packages/cov13font/Cov13Sans');
    final iconParagraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('material_icon')),
        matching: find.byType(RichText),
      ),
    );
    expect(iconParagraph.text.style?.fontFamily, 'MaterialIcons');

    final manifest = jsonDecode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List<Object?>;
    final assetByFamily = <String, String>{
      for (final entry in manifest.cast<Map<String, Object?>>())
        entry['family']! as String:
            ((entry['fonts']! as List<Object?>).first!
                    as Map<String, Object?>)['asset']!
                as String,
    };
    expect(
      assetByFamily.keys,
      containsAll(<String>['MaterialIcons', 'packages/cov13font/Cov13Sans']),
    );
    for (final family in <String>[
      'MaterialIcons',
      'packages/cov13font/Cov13Sans',
    ]) {
      final bytes = await rootBundle.load(assetByFamily[family]!);
      expect(bytes.lengthInBytes, greaterThan(0), reason: family);
    }

    final loader = FontLoader('Cov13MaterialIconsProbe')
      ..addFont(rootBundle.load(assetByFamily['MaterialIcons']!));
    await loader.load();
  });

  testWidgets('calls the native asset through @Native', (tester) async {
    expect(tripleViaNativeAsset(14), 42);
  });

  testWidgets('opens the native dep through dart:ffi', (tester) async {
    final add = DynamicLibrary.open('libadd.so')
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'add',
        );
    expect(add(40, 2), 42);
  });
}
