/// Binds the native `cov13_asset_triple` function as a Dart Native Asset.
///
/// The `@Native` annotation names no asset id, so the VM derives the default
/// one from this library's URI (`package:native_asset_plugin/
/// native_asset_plugin.dart`); the BUILD file declares an asset under that id,
/// the frontend_server embeds the mapping in the kernel, and the engine opens
/// `libcov13_asset.so` from the APK's `lib/<abi>/` directory at first call.
library;

import 'dart:ffi' as ffi;

@ffi.Native<ffi.Int32 Function(ffi.Int32)>(symbol: 'cov13_asset_triple')
external int _tripleViaAsset(int value);

/// Multiplies [value] by three in native code reached through a native asset.
int tripleViaNativeAsset(int value) => _tripleViaAsset(value);
