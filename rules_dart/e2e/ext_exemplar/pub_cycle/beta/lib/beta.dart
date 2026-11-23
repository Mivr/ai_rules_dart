import 'package:alpha/alpha.dart';

/// The name of the second member of the cycle.
String betaName() => 'beta';

/// What the second member says, having asked its sibling for its name.
String betaGreeting() => 'beta greets ${alphaName()}';
