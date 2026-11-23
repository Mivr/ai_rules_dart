import 'package:c/c.dart';

/// The workspace root is a package too: it builds on member `c`.
String rootGreeting() => greetBoth('root.txt', 'workspace.txt');
