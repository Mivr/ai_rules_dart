import 'package:counter_lib/counter_lib.dart';
import 'package:counter_plugin/counter_plugin.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';
import 'marks.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context)!.appTitle,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  String _tempDir = '?';
  String _native = '?';

  @override
  void initState() {
    super.initState();
    // The plugin: a platform call through path_provider.
    getTemporaryDirectory().then((dir) {
      debugPrint('rdf-plugin temp=${dir.path}');
      if (mounted) {
        setState(() => _tempDir = dir.path);
      }
    });
    // The app's own Kotlin code (MainActivity), on Android only.
    if (defaultTargetPlatform == TargetPlatform.android) {
      const MethodChannel('rdf/native').invokeMethod<String>('nativeMark').then((String? mark) {
        if (mounted) {
          setState(() => _native = mark ?? 'null');
        }
      });
    }
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    // One line per build: a hot reload reassembles, so the new marks appear.
    debugPrint(
      'rdf-mark app=${appMark()} lib=${libMark()} gen=${l10n.genMark} '
      'plugin=${CounterPlugin.mark()} registered=${CounterPlugin.registered} native=$_native',
    );
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(l10n.appTitle),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: .center,
          children: [
            Text(describeCount(_counter),
                style: Theme.of(context).textTheme.headlineMedium),
            Text('temp: $_tempDir'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
