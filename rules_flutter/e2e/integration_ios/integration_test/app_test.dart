import 'dart:ui' as ui;

import 'package:android_only_plugin/android_only_plugin.dart';
import 'package:dart_registration_plugin/dart_registration_plugin.dart';
import 'package:ffi_plugin/ffi_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/l10n/app_localizations.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ios_greeting_plugin/ios_greeting_plugin.dart';
import 'package:xcframework_plugin/xcframework_plugin.dart';

void main() {
  // Captured when the integration test entrypoint's own `main()` starts. The
  // engine runs the generated Dart plugin registrant before this, so only the
  // plugin's `registerWith` event can be here; `testMain` follows it.
  final startupEventsAtTestMain = <String>[
    ...DartRegistrationPlugin.startupEvents,
    testMainEvent,
  ];

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs the Dart plugin registerWith before main', (tester) async {
    expect(startupEventsAtTestMain, <String>[registerEvent, testMainEvent]);
    expect(DartRegistrationPlugin.isRegistered, isTrue);
    expect(
      DartRegistrationPlugin.greet(),
      'registered by the generated Dart registrant',
    );
  });

  testWidgets('calls the first-party FFI plugin through dart:ffi', (
    tester,
  ) async {
    expect(FfiPlugin.answer(), 42);
  });

  testWidgets('calls tinykit_answer through the imported framework', (
    tester,
  ) async {
    expect(await const XcframeworkPlugin().tinykitAnswer(), 42);
  });

  testWidgets('forwards a define with a comma and an equals sign', (
    tester,
  ) async {
    expect(
      const String.fromEnvironment('COV79_GREETING'),
      'hello, world=ok',
    );

    await tester.pumpWidget(const CounterApp());
  });

  testWidgets('renders the generated Spanish message under Locale es', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Cov79Localizations.localizationsDelegates,
        supportedLocales: Cov79Localizations.supportedLocales,
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: const Locale('es'),
            child: Builder(
              builder: (context) => Text(
                Cov79Localizations.of(context).cov79Greeting,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('¡Hola desde el simulador de iOS!'), findsOneWidget);
    expect(
      Cov79Localizations.supportedLocales,
      containsAll(<Locale>[const Locale('en'), const Locale('es')]),
    );
  });

  testWidgets('loads and paints the committed Impeller shader', (
    tester,
  ) async {
    final program = await ui.FragmentProgram.fromAsset('shaders/ink_stub.frag');
    final shader = program.fragmentShader();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomPaint(
          size: const Size(16, 16),
          painter: _InkPainter(shader),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('builds and runs with the Android-only plugin in deps', (
    tester,
  ) async {
    // The plugin is in this app's `deps` but has no iOS implementation; the
    // app still boots, and its Dart package is part of the compiled graph.
    expect(androidOnlyPluginMarker, 'android-only-plugin');
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('shows the counter text and serves the bundled asset', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    expect(find.text('0'), findsOneWidget);
    expect(
      find.text('You have pushed the button this many times:'),
      findsOneWidget,
    );

    final assetBytes = await rootBundle.load('assets/logo.png');
    final bytes = assetBytes.buffer.asUint8List();
    expect(bytes.lengthInBytes, 82);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 16);
    expect(frame.image.height, 16);
    frame.image.dispose();
    codec.dispose();
  });

  testWidgets('reports the native bundle id over the plugin channel', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());

    // The rule-assigned `ios_bundle_id` default for this target.
    const expectedBundleId = 'com.example.app.app-test.h1715444662';
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text(expectedBundleId).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text(expectedBundleId), findsOneWidget);
    expect(
      await const IosGreetingPlugin().getAppBundleId(),
      expectedBundleId,
    );
  });
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.shader);

  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_InkPainter oldDelegate) => oldDelegate.shader != shader;
}
