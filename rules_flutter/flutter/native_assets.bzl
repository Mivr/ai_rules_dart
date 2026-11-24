"""Public surface for Flutter data assets.

`flutter_data_asset` declares a file a Flutter app bundles at
`flutter_assets/packages/<pkg>/<name>`, for a `flutter_plugin`'s
`data_assets`:

    load("@rules_flutter//flutter:native_assets.bzl", "flutter_data_asset")

    flutter_data_asset(
        name = "blob",
        asset_id = "package:pkg/blob.bin",
        file = "data/blob.bin",
    )

Code assets come from the packages' own build hooks, which rules_dart runs. A
native library Bazel builds itself is bound to an asset id with rules_dart's
`dart_code_asset`, listed in the owning `flutter_library` or `flutter_plugin`'s
`code_assets`.
"""

load(
    "//flutter/private:flutter_data_asset.bzl",
    _flutter_data_asset = "flutter_data_asset",
)

visibility("public")

flutter_data_asset = _flutter_data_asset
