import 'package:scc_module_a/a.dart';

/// One half of a pub dependency cycle.
String bName() => 'b';

/// The other half's name, read across the cycle.
String bOther() => aName();
