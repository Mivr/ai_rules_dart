"""The pinned source closure of the asset tool, per Flutter version.

The asset tool (`//flutter/private/assets_tool:flutter_assets_tool.dart`) runs
the Flutter tool's own asset, licence, web bootstrap and gen-l10n code. It is
compiled against `packages/flutter_tools` at the tag of the Flutter SDK the
build uses, so its output is the tool's of that release; `flutter_tools` uses
internal APIs, so a release that changes one fails the tool's build rather
than its output. Each supported Flutter version pins here:

- `flutter_tools_language_version`: the language version of
  `packages/flutter_tools/pubspec.yaml`. Its sources come from the release's
  source tarball, which `versions.bzl` already pins (`source_sha256`).
- `packages`: the hosted packages the tool's import closure reaches, at the
  versions the release's `packages/flutter_tools/pubspec.yaml` pins, with
  pub.dev's published archive checksums (the `sha256` of
  `packages/flutter_tools/pubspec.lock` once `flutter` has run) and the
  language version each package's pubspec states. Only the 64 packages the
  closure reaches are fetched, of the 101 in that lock.

A Flutter version without a row cannot bundle assets. Adding one is: run the
new release's `flutter` once so it resolves `packages/flutter_tools`, compile
the tool against that package config with `dart compile kernel --depfile`,
and record every hosted package the depfile names, with its lock checksum.
"""

visibility(["//flutter/..."])

FLUTTER_ASSETS_TOOL_SOURCES = {
    "3.47.7": struct(
        flutter_tools_language_version = "3.11",
        packages = {
            "archive": struct(version = "3.6.1", sha256 = "cb6a278ef2dbb298455e1a713bda08524a175630ec643a242c399c932a0a1f7d", language_version = "3.0"),
            "args": struct(version = "2.7.0", sha256 = "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04", language_version = "3.3"),
            "async": struct(version = "2.13.1", sha256 = "e2eb0491ba5ddb6177742d2da23904574082139b07c1e33b8503b9f46f3e1a37", language_version = "3.4"),
            "browser_launcher": struct(version = "1.1.3", sha256 = "ca2557663d3033845f2ef2b60f94fc249528324fd1affddccb7c63ac0ccd6c67", language_version = "3.4"),
            "clock": struct(version = "1.1.2", sha256 = "fddb70d9b5277016c77a80201021d40a2247104d9f4aa7bab7157b7e3f05b84b", language_version = "3.4"),
            "code_assets": struct(version = "1.2.1", sha256 = "bf394f466ba9205f1812a0433b392d6af280f155f56651eda7c18cc32ed493b8", language_version = "3.10"),
            "collection": struct(version = "1.19.1", sha256 = "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76", language_version = "3.4"),
            "completion": struct(version = "1.0.2", sha256 = "82fa09800c0b71a2e8396bf3ca6b36b43cd35fe7ba2aeab53b6349ac671d0f5b", language_version = "3.7"),
            "convert": struct(version = "3.1.2", sha256 = "b30acd5944035672bc15c6b7a8b47d773e41e2f17de064350988c5d02adb1c68", language_version = "3.4"),
            "crypto": struct(version = "3.0.7", sha256 = "c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf", language_version = "3.4"),
            "csslib": struct(version = "1.0.2", sha256 = "09bad715f418841f976c77db72d5398dc1253c21fb9c0c7f0b0b985860b2d58e", language_version = "3.1"),
            "dap": struct(version = "1.4.0", sha256 = "42b0b083a09c59a118741769e218fc3738980ab591114f09d1026241d2b9c290", language_version = "2.19"),
            "dart_service_protocol_shared": struct(version = "0.0.3", sha256 = "1737875c176d7e3d87bb3a359182828b542fe20a0b34198b8d31a81af5c7a76d", language_version = "3.5"),
            "data_assets": struct(version = "0.20.0", sha256 = "8bfdbf25ec8a0f4b5a3c993042c4ab9996ba354f0b03d40f4e360f3730d71cae", language_version = "3.10"),
            "dds": struct(version = "5.4.0", sha256 = "f8e875dcd7b5e5073a7bfe54095144c70487f18e2f8e47fa51c09dd67eccfb0c", language_version = "3.5"),
            "dds_service_extensions": struct(version = "2.1.0", sha256 = "afe0fce921953ac0c5bb276bccd7e36fa5035d7769567d122523fdd09beb4d03", language_version = "3.5"),
            "devtools_shared": struct(version = "13.1.0", sha256 = "13df2c17d5f21dd7c92d08145386d45e1153364c04e531e994afb0ee7b67554b", language_version = "3.11"),
            "dtd": struct(version = "4.0.0", sha256 = "09ddb228b3d1478a093556357692a4c203ff4f9d5f8cda05dfdca0ff3fb7c5d3", language_version = "3.5"),
            "extension_discovery": struct(version = "2.1.0", sha256 = "de1fce715ab013cdfb00befc3bdf0914bea5e409c3a567b7f8f144bc061611a7", language_version = "3.4"),
            "file": struct(version = "7.0.1", sha256 = "a3b4f84adafef897088c160faf7dfffb7696046cb13ae90b508c2cbc95d3b8d4", language_version = "3.0"),
            "fixnum": struct(version = "1.1.1", sha256 = "b6dc7065e46c974bc7c5f143080a6764ec7a4be6da1285ececdc37be96de53be", language_version = "3.1"),
            "glob": struct(version = "2.1.3", sha256 = "c3f1ee72c96f8f78935e18aa8cecced9ab132419e8625dc187e1c2408efc20de", language_version = "3.3"),
            "graphs": struct(version = "2.3.2", sha256 = "741bbf84165310a68ff28fe9e727332eef1407342fca52759cb21ad8177bb8d0", language_version = "3.4"),
            "hooks": struct(version = "2.0.2", sha256 = "9a62a50b50b769a737bc0a8ff381f333529df3ab746b2f6b02e83760231455ba", language_version = "3.10"),
            "hooks_runner": struct(version = "1.5.0", sha256 = "a67ab8106545fcffcf5c43edf84b4be222fc95a9fbec8baef1bcaf4534540cfc", language_version = "3.10"),
            "html": struct(version = "0.15.6", sha256 = "6d1264f2dffa1b1101c25a91dff0dc2daee4c18e87cd8538729773c073dbf602", language_version = "3.2"),
            "http": struct(version = "1.6.0", sha256 = "87721a4a50b19c7f1d49001e51409bddc46303966ce89a65af4f4e6004896412", language_version = "3.4"),
            "http_parser": struct(version = "4.1.2", sha256 = "178d74305e7866013777bab2c3d8726205dc5a4dd935297175b19a23a2e66571", language_version = "3.4"),
            "intl": struct(version = "0.20.3", sha256 = "1ca20c894b1717686a2319b8548763d812bc0aabdac580420a44c5178c57a867", language_version = "3.9"),
            "json_rpc_2": struct(version = "4.1.0", sha256 = "82dfd37d3b2e5030ae4729e1d7f5538cbc45eb1c73d618b9272931facac3bec1", language_version = "3.4"),
            "logging": struct(version = "1.3.0", sha256 = "c8245ada5f1717ed44271ed1c26b8ce85ca3228fd2ffdb75468ab01979309d61", language_version = "3.4"),
            "meta": struct(version = "1.18.3", sha256 = "c82594181e3312f3d0695fc95aaaf7758d75b8d4ae2bbecf223b9fd5109a059d", language_version = "3.5"),
            "mime": struct(version = "2.0.0", sha256 = "41a20518f0cb1256669420fdba0cd90d21561e560ac240f26ef8322e45bb7ed6", language_version = "3.2"),
            "multicast_dns": struct(version = "0.3.3+1", sha256 = "134668a9605c747322d8c3eb0e89a4c0cbdedb29f8d2d5ae29d14daef724987b", language_version = "3.10"),
            "package_config": struct(version = "2.2.0", sha256 = "f096c55ebb7deb7e384101542bfba8c52696c1b56fca2eb62827989ef2353bbc", language_version = "3.4"),
            "path": struct(version = "1.9.1", sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5", language_version = "3.4"),
            "petitparser": struct(version = "7.0.2", sha256 = "91bd59303e9f769f108f8df05e371341b15d59e995e6806aefab827b58336675", language_version = "3.8"),
            "platform": struct(version = "3.1.6", sha256 = "5d6b1b0036a5f331ebc77c850ebc8506cbc1e9416c27e59b439f917a902a4984", language_version = "3.2"),
            "pool": struct(version = "1.5.2", sha256 = "978783255c543aa3586a1b3c21f6e9d720eb315376a915872c61ef8b5c20177d", language_version = "3.4"),
            "process": struct(version = "5.0.5", sha256 = "c6248e4526673988586e8c00bb22a49210c258dc91df5227d5da9748ecf79744", language_version = "3.5"),
            "pub_semver": struct(version = "2.2.0", sha256 = "5bfcf68ca79ef689f8990d1160781b4bad40a3bd5e5218ad4076ddb7f4081585", language_version = "3.4"),
            "record_use": struct(version = "0.6.0", sha256 = "2551bd8eecfe95d14ae75f6021ad0248be5c27f138c2ec12fcb52b500b3ba1ed", language_version = "3.10"),
            "shelf": struct(version = "1.4.2", sha256 = "e7dd780a7ffb623c57850b33f43309312fc863fb6aa3d276a754bb299839ef12", language_version = "3.4"),
            "shelf_proxy": struct(version = "1.0.5", sha256 = "0c3a7b2b4c111cae8a6d9077701e0622c6013d38a780373ac359d6d45b3aa10b", language_version = "3.3"),
            "shelf_static": struct(version = "1.1.3", sha256 = "c87c3875f91262785dade62d135760c2c69cb217ac759485334c5857ad89f6e3", language_version = "3.3"),
            "shelf_web_socket": struct(version = "3.0.0", sha256 = "3632775c8e90d6c9712f883e633716432a27758216dfb61bd86a8321c0580925", language_version = "3.5"),
            "source_span": struct(version = "1.10.2", sha256 = "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab", language_version = "3.1"),
            "sse": struct(version = "4.2.0", sha256 = "a9a804dbde8bfd369da3b4aa241d44d63a6486a97388c54ec166073d88c52302", language_version = "3.11"),
            "stack_trace": struct(version = "1.12.1", sha256 = "8b27215b45d22309b5cddda1aa2b19bdfec9df0e765f2de506401c071d38d1b1", language_version = "3.4"),
            "standard_message_codec": struct(version = "0.0.1+5", sha256 = "f10b3fbdb4d56c6bc4d160ef5b3d6346df7a998a84876d05886a75d17eb290e6", language_version = "3.10"),
            "stream_channel": struct(version = "2.1.4", sha256 = "969e04c80b8bcdf826f8f16579c7b14d780458bd97f56d107d3950fdbeef059d", language_version = "3.3"),
            "string_scanner": struct(version = "1.4.1", sha256 = "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43", language_version = "3.1"),
            "term_glyph": struct(version = "1.2.2", sha256 = "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e", language_version = "3.1"),
            "typed_data": struct(version = "1.4.0", sha256 = "f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006", language_version = "3.5"),
            "unified_analytics": struct(version = "8.0.15", sha256 = "0988c50d794f3cd96f6df92b4b35b7c333bbf869df304fc6062a45ebc7eb0776", language_version = "3.10"),
            "uuid": struct(version = "4.5.3", sha256 = "1fef9e8e11e2991bb773070d4656b7bd5d850967a2456cfc83cf47925ba79489", language_version = "3.0"),
            "vm_service": struct(version = "15.2.0", sha256 = "0016aef94fc66495ac78af5859181e3f3bf2026bd8eecc72b9565601e19ab360", language_version = "3.5"),
            "vm_snapshot_analysis": struct(version = "0.7.6", sha256 = "5a79b9fbb6be2555090f55b03b23907e75d44c3fd7bdd88da09848aa5a1914c8", language_version = "2.14"),
            "webkit_inspection_protocol": struct(version = "1.2.1", sha256 = "87d3f2333bb240704cd3f1c6b5b7acd8a10e7f0bc28c28dcf14e782014f4a572", language_version = "3.0"),
            "web_socket": struct(version = "1.0.1", sha256 = "34d64019aa8e36bf9842ac014bb5d2f5586ca73df5e4d9bf5c936975cae6982c", language_version = "3.4"),
            "web_socket_channel": struct(version = "3.0.3", sha256 = "d645757fb0f4773d602444000a8131ff5d48c9e47adfe9772652dd1a4f2d45c8", language_version = "3.3"),
            "xml": struct(version = "6.6.1", sha256 = "971043b3a0d3da28727e40ed3e0b5d18b742fa5a68665cca88e74b7876d5e025", language_version = "3.8"),
            "yaml": struct(version = "3.1.3", sha256 = "b9da305ac7c39faa3f030eccd175340f968459dae4af175130b3fc47e40d76ce", language_version = "3.4"),
            "yaml_edit": struct(version = "2.2.4", sha256 = "07c9e63ba42519745182b88ca12264a7ba2484d8239958778dfe4d44fe760488", language_version = "3.1"),
        },
    ),
}
