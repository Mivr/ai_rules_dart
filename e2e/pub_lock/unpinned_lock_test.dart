void main() {
  const lockErr = String.fromEnvironment('LOCK_PACKAGE_ERROR');
  const shaErr = String.fromEnvironment('PUB_LOCK_PACKAGE_SHA256_ERROR');

  const expectedLockErr =
      'pub package "collection" 1.18.0 in //:pubspec.lock has no sha256. '
      'Run `dart pub get` (Dart 2.19 or newer records one) and commit the '
      'lock.';
  const expectedShaErr =
      'pub_lock_package "collection" (1.18.0) requires a non-empty sha256.';

  assert(
    lockErr == expectedLockErr,
    'Expected "$expectedLockErr", got "$lockErr"',
  );
  assert(shaErr == expectedShaErr, 'Expected "$expectedShaErr", got "$shaErr"');
}
