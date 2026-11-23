/// Environment values a dependency module reads, so a test can see which
/// environment that module compiled with.
library;

/// From the executable's `defines`.
const String defcfgFoo = String.fromEnvironment(
  'DEFCFG_FOO',
  defaultValue: 'unset',
);

/// From the executable's defines file.
const String defcfgFile = String.fromEnvironment(
  'DEFCFG_FILE',
  defaultValue: 'unset',
);

/// From the application's flavor.
const String defcfgFlavor = String.fromEnvironment(
  'FLUTTER_APP_FLAVOR',
  defaultValue: 'unset',
);

/// All three.
const String defcfgSummary = '$defcfgFoo/$defcfgFile/$defcfgFlavor';
