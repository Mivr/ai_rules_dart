import 'package:beta/beta.dart';

/// The name of the first member of the cycle.
String alphaName() => 'alpha';

/// What the first member says, having asked its sibling for its name.
String alphaGreeting() => 'alpha greets ${betaName()}';
