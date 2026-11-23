# Android release signing

How `flutter_android_app` signs its APK, and what the overlay reports.

## Debug and release

By default the overlay signs with the debug keystore, exactly as an
`android_binary` does. Passing `keystore` together with
`keystore_password_file` and `key_alias` — or setting the
`//flutter:android_release_keystore`,
`//flutter:android_release_keystore_password_file` and
`//flutter:android_release_key_alias` flags — switches the overlay's
`ApkSignerTool` action to the caller's keystore, with both passwords passed
only as `file:` references. An explicit attribute always wins over its flag.

## The debug lineage stays debug-only

`debug_signing_lineage_file` feeds apksigner's `--lineage` for key rotation
under **debug** signing only. A release-signed overlay signs **without** the
debug lineage: even when `debug_signing_lineage_file` is set, the release
`ApkSignerTool` action gets no `--lineage`, and the overlay's `ApkInfo` and
`StarlarkApkInfo` report no lineage. Shipping a rotated debug lineage with a
release key would attest a rotation history the release key never had, so the
overlay drops the flag rather than failing the build; debug signing keeps
today's arguments exactly.

The overlay's providers report what its own signing run used: the `File` it
passed with `--lineage` (or `None`), and the value it passed with
`--rotation-min-sdk-version` (or `None`) — never the base `android_binary`'s
fields.

## Signature schemes in debug and release

In debug builds (`-c dbg`), the overlay defaults to the fastest signature scheme
supported by the app's minimum SDK version (`minSdkVersion`):

- When `minSdkVersion` is 24 or higher, debug builds default to APK Signature
  Scheme v2 alone (`v2`). Android 7.0 (API 24) introduced APK Signature
  Scheme v2, which signs the entire APK binary archive and eliminates the need
  for entry-by-entry JAR hashing and verification in the ZIP central directory.
- When `minSdkVersion` is below 24 (such as the repository default
  `ANDROID_MIN_SDK_VERSION = "21"` in `flutter/private/constants.bzl`), debug
  builds default to `v1_v2` (both v1 JAR signing and v2 whole-APK signing).
  Android devices on API levels 21–23 do not support standalone v2 signature
  verification and fail package installation without a valid v1 JAR signature.

An explicit `@rules_android//flags:apk_signing_method` flag always overrides
this default. Release builds keep their existing default scheme (`v1_v2`) and
signing arguments.
