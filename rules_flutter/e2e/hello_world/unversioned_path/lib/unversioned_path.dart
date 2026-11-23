// Fixture library for the unversioned path-package probe: this package has
// no `version:` field, so `pub get` locks it as "0.0.0" and the spoke must
// read the missing field the same way.
int unversionedValue = 1;
