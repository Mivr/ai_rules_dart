import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; // rdf-import
import 'package:shared_preferences/shared_preferences.dart'; // rdf-import
import 'package:webview_flutter/webview_flutter.dart'; // rdf-import
import 'package:url_launcher/url_launcher.dart'; // rdf-import
import 'package:camera/camera.dart'; // rdf-import
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // rdf-import
import 'package:firebase_core/firebase_core.dart'; // rdf-import
import 'package:firebase_messaging/firebase_messaging.dart'; // rdf-import
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart'; // rdf-import
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'; // rdf-import

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  rdfPlugins();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    print('rdf-dart-0');
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
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



// rdf-plugins-begin
Future<void> rdfPlugins() async {
  try {
    final r = await Future<String>(() async => (await getApplicationSupportDirectory()).path).timeout(const Duration(seconds: 8));
    print('rdf-plugin path_provider OK ' + r);
  } catch (e) {
    print('rdf-plugin path_provider ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => await (() async { final p = await SharedPreferences.getInstance(); await p.setInt('rdf', 41); return (p.getInt('rdf')! + 1).toString(); })()).timeout(const Duration(seconds: 8));
    print('rdf-plugin shared_preferences OK ' + r);
  } catch (e) {
    print('rdf-plugin shared_preferences ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => await (() async { final c = WebViewController(); await c.setJavaScriptMode(JavaScriptMode.unrestricted); return 'controller ' + (await c.currentUrl()).toString(); })()).timeout(const Duration(seconds: 8));
    print('rdf-plugin webview_flutter OK ' + r);
  } catch (e) {
    print('rdf-plugin webview_flutter ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => (await canLaunchUrl(Uri.parse('https://example.com'))).toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin url_launcher OK ' + r);
  } catch (e) {
    print('rdf-plugin url_launcher ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => 'cameras ' + (await availableCameras()).length.toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin camera OK ' + r);
  } catch (e) {
    print('rdf-plugin camera ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => (await FlutterLocalNotificationsPlugin().initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')))).toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin flutter_local_notifications OK ' + r);
  } catch (e) {
    print('rdf-plugin flutter_local_notifications ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => (await Firebase.initializeApp()).options.projectId.toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin firebase_core OK ' + r);
  } catch (e) {
    print('rdf-plugin firebase_core ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => (await FirebaseMessaging.instance.isSupported()).toString() + ' autoInit ' + FirebaseMessaging.instance.isAutoInitEnabled.toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin firebase_messaging OK ' + r);
  } catch (e) {
    print('rdf-plugin firebase_messaging ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  try {
    final r = await Future<String>(() async => (await (GoogleMapsFlutterPlatform.instance as GoogleMapsFlutterAndroid).initializeWithRenderer(AndroidMapRenderer.latest)).toString()).timeout(const Duration(seconds: 8));
    print('rdf-plugin google_maps_flutter OK ' + r);
  } catch (e) {
    print('rdf-plugin google_maps_flutter ERR ' + e.runtimeType.toString() + ' ' + e.toString().split('\n').first);
  }
  print('rdf-plugins-done');
}
// rdf-plugins-end
