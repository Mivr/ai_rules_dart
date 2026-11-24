import 'package:scc_module_b/b.dart';

/// One half of a pub dependency cycle.
String aName() => 'a';

/// The other half's name, read across the cycle.
String aOther() => bName();
