// Same violation as `user`, in a package that opts out of the check.
import 'package:leaf/leaf.dart';
import 'package:mid/mid.dart';

/// Both values, one reached through `mid` only.
const String optedOut = '$leaf $mid';
