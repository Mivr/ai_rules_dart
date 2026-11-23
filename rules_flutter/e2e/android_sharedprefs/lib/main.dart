import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Throws MissingPluginException when `shared_preferences_android` was not
  // registered with the engine.
  final prefs = await SharedPreferences.getInstance();
  final launches = (prefs.getInt('launches') ?? 0) + 1;
  await prefs.setInt('launches', launches);
  runApp(MyApp(launches: launches));
}

/// Root widget of the shared_preferences example.
class MyApp extends StatelessWidget {
  /// Creates the root widget, showing how often the app has launched.
  const MyApp({required this.launches, super.key});

  /// The launch count read back from `SharedPreferences`.
  final int launches;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android SharedPreferences',
      home: Scaffold(
        body: Center(child: Text('launches = $launches')),
      ),
    );
  }
}
