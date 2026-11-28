// Spike T17a (S9): one call into each plugin's native side, one line per plugin on the console.
// A `MissingPluginException` means the plugin's native code is not in the app.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

Future<void> _probe(String plugin, Future<Object?> Function() call) async {
  try {
    final result = await call().timeout(const Duration(seconds: 20));
    debugPrint('rdf-s9 $plugin OK $result');
  } on Object catch (error) {
    debugPrint('rdf-s9 $plugin ERR ${error.runtimeType}');
  }
}

Future<void> probePlugins() async {
  await _probe('url_launcher', () => canLaunchUrl(Uri.parse('https://example.com')));
  await _probe('permission_handler', () => Permission.camera.status);
  await _probe('webview_flutter', () async => WebViewController().getUserAgent());
  await _probe(
    'firebase_core',
    () async => (await Firebase.initializeApp(
      // Not a key of any project. Firebase refuses to start unless the key has 39 characters of the
      // base64 URL alphabet and begins with `A` (FIRInstallations validateAPIKey), so this has that
      // shape and nothing else of a real key.
      options: const FirebaseOptions(
        apiKey: 'A-rdf-s9-spike-dummy-not-a-real-key-000',
        appId: '1:1234567890:ios:0123456789abcdef',
        messagingSenderId: '1234567890',
        projectId: 'rdf-s9',
      ),
    )).name,
  );
  await _probe('firebase_messaging', () => FirebaseMessaging.instance.isSupported());
  await _probe('google_sign_in', () async {
    await GoogleSignIn.instance.initialize(clientId: 'rdf-s9.apps.googleusercontent.com');
    return 'initialized';
  });
  debugPrint('rdf-s9 done');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(probePlugins());
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('rdf-s9')))));
}
