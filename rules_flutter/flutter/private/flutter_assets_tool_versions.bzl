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
- `source_packages`: the path packages of `packages/flutter_tools/packages/`
  that the import closure reaches, with their language versions; they come
  from the same tarball.
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
    "3.50.1": struct(
        flutter_tools_language_version = "3.13",
        source_packages = {"flutter_tools_core": "3.13", "flutter_tools_extension": "3.13"},
        packages = {
            "archive": struct(version = "3.6.1", sha256 = "cb6a278ef2dbb298455e1a713bda08524a175630ec643a242c399c932a0a1f7d", language_version = "3.0"),
            "args": struct(version = "2.7.0", sha256 = "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04", language_version = "3.3"),
            "async": struct(version = "2.13.1", sha256 = "e2eb0491ba5ddb6177742d2da23904574082139b07c1e33b8503b9f46f3e1a37", language_version = "3.4"),
            "browser_launcher": struct(version = "1.2.0", sha256 = "3b81cb3b35dd3734952585c2dd78b7808fa2630b740ba0dfee17f057d406a990", language_version = "3.4"),
            "clock": struct(version = "1.1.3", sha256 = "e51d50bca3217c9a9fa2b41a30e4a38971133f5f9ec7a3d57bae095007f1d28e", language_version = "3.4"),
            "code_assets": struct(version = "2.1.0", sha256 = "828110d598123b5ea96c00c9f3c72105bf79f8ee36c20a39b26209ade421ec57", language_version = "3.10"),
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
            "glob": struct(version = "2.2.0", sha256 = "218aeb56050c714f62a3182775320dfa04602b55074873e24e31bbd39bda96fb", language_version = "3.3"),
            "graphs": struct(version = "2.3.2", sha256 = "741bbf84165310a68ff28fe9e727332eef1407342fca52759cb21ad8177bb8d0", language_version = "3.4"),
            "hooks": struct(version = "2.2.0", sha256 = "eaac480a35ec0814146c2c48d96aaa829e0e44a7662c88ae84c9edf4bc35651f", language_version = "3.10"),
            "hooks_runner": struct(version = "1.6.4", sha256 = "f9b924b204fd325d6945d5f92821ab3ac626e425c4aff1c6ffda48ba5e22c896", language_version = "3.10"),
            "html": struct(version = "0.15.7", sha256 = "43b67b8f43321ab066817dfac5619596c98bb1b61624e77203bb4351785f9699", language_version = "3.6"),
            "http": struct(version = "1.6.0", sha256 = "87721a4a50b19c7f1d49001e51409bddc46303966ce89a65af4f4e6004896412", language_version = "3.4"),
            "http_parser": struct(version = "4.1.2", sha256 = "178d74305e7866013777bab2c3d8726205dc5a4dd935297175b19a23a2e66571", language_version = "3.4"),
            "intl": struct(version = "0.20.3", sha256 = "1ca20c894b1717686a2319b8548763d812bc0aabdac580420a44c5178c57a867", language_version = "3.9"),
            "json_rpc_2": struct(version = "4.1.0", sha256 = "82dfd37d3b2e5030ae4729e1d7f5538cbc45eb1c73d618b9272931facac3bec1", language_version = "3.4"),
            "logging": struct(version = "1.3.0", sha256 = "c8245ada5f1717ed44271ed1c26b8ce85ca3228fd2ffdb75468ab01979309d61", language_version = "3.4"),
            "meta": struct(version = "1.19.0", sha256 = "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9", language_version = "3.5"),
            "mime": struct(version = "2.1.0", sha256 = "bd47de35f07e27267e69c8c8b22edf9473bfee170a60d60fcc93730c5144b7f6", language_version = "3.2"),
            "multicast_dns": struct(version = "0.3.3+1", sha256 = "134668a9605c747322d8c3eb0e89a4c0cbdedb29f8d2d5ae29d14daef724987b", language_version = "3.10"),
            "package_config": struct(version = "2.2.0", sha256 = "f096c55ebb7deb7e384101542bfba8c52696c1b56fca2eb62827989ef2353bbc", language_version = "3.4"),
            "path": struct(version = "1.9.1", sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5", language_version = "3.4"),
            "petitparser": struct(version = "7.1.0", sha256 = "2f1564aadb14215e478563b5406cb80729d022158c01dc50c96013c2f7eb4790", language_version = "3.13"),
            "platform": struct(version = "3.2.0", sha256 = "a36d119c13416516a7b5913fbe8af8531e11633d784c550b2125f76c758524ec", language_version = "3.10"),
            "pool": struct(version = "1.5.3", sha256 = "4177f68c237ea2128d1bee66ac17b2ce05ba3dbaafcbdd54c5d40a39d0b6b11c", language_version = "3.4"),
            "process": struct(version = "5.0.6", sha256 = "4242ba3508d37e01808bdf71ad1d5bb93a8d671bf2e7450e6b1b353fb0808891", language_version = "3.5"),
            "pub_semver": struct(version = "2.2.1", sha256 = "261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24", language_version = "3.4"),
            "record_use": struct(version = "1.1.1", sha256 = "1cb8564af8d43b464294411db9217f5ec04891c6f22ee2c32d73ae05e88a6bd2", language_version = "3.10"),
            "shelf": struct(version = "1.4.2", sha256 = "e7dd780a7ffb623c57850b33f43309312fc863fb6aa3d276a754bb299839ef12", language_version = "3.4"),
            "shelf_proxy": struct(version = "1.0.5", sha256 = "0c3a7b2b4c111cae8a6d9077701e0622c6013d38a780373ac359d6d45b3aa10b", language_version = "3.3"),
            "shelf_static": struct(version = "1.1.3", sha256 = "c87c3875f91262785dade62d135760c2c69cb217ac759485334c5857ad89f6e3", language_version = "3.3"),
            "shelf_web_socket": struct(version = "3.0.0", sha256 = "3632775c8e90d6c9712f883e633716432a27758216dfb61bd86a8321c0580925", language_version = "3.5"),
            "source_span": struct(version = "1.10.2", sha256 = "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab", language_version = "3.1"),
            "sse": struct(version = "4.2.0", sha256 = "a9a804dbde8bfd369da3b4aa241d44d63a6486a97388c54ec166073d88c52302", language_version = "3.11"),
            "stack_trace": struct(version = "1.12.2", sha256 = "277654b3034d17ac6f9f1cb5595db011b1d5d41e8806866db28e0abaa101c490", language_version = "3.4"),
            "standard_message_codec": struct(version = "0.0.1+5", sha256 = "f10b3fbdb4d56c6bc4d160ef5b3d6346df7a998a84876d05886a75d17eb290e6", language_version = "3.10"),
            "stream_channel": struct(version = "2.1.4", sha256 = "969e04c80b8bcdf826f8f16579c7b14d780458bd97f56d107d3950fdbeef059d", language_version = "3.3"),
            "string_scanner": struct(version = "1.4.1", sha256 = "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43", language_version = "3.1"),
            "term_glyph": struct(version = "1.2.2", sha256 = "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e", language_version = "3.1"),
            "typed_data": struct(version = "1.4.0", sha256 = "f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006", language_version = "3.5"),
            "unified_analytics": struct(version = "8.0.18", sha256 = "28bb11ef24567e720dc1397cba60df03cc5aded5bf6bef4d17b49934402c719b", language_version = "3.10"),
            "uuid": struct(version = "4.6.0", sha256 = "9b129329f58692f6e6578329498a8fe9fbe98f090beb764ffbb8ee2eadd01dcd", language_version = "3.0"),
            "vm_service": struct(version = "15.3.0", sha256 = "5f37239c4851efcef929cea7824e76df7f2f0970aef85d66bbc430afa40e72f0", language_version = "3.5"),
            "vm_snapshot_analysis": struct(version = "0.7.6", sha256 = "5a79b9fbb6be2555090f55b03b23907e75d44c3fd7bdd88da09848aa5a1914c8", language_version = "2.14"),
            "web_socket": struct(version = "1.0.1", sha256 = "34d64019aa8e36bf9842ac014bb5d2f5586ca73df5e4d9bf5c936975cae6982c", language_version = "3.4"),
            "web_socket_channel": struct(version = "3.0.3", sha256 = "d645757fb0f4773d602444000a8131ff5d48c9e47adfe9772652dd1a4f2d45c8", language_version = "3.3"),
            "webkit_inspection_protocol": struct(version = "1.2.1", sha256 = "87d3f2333bb240704cd3f1c6b5b7acd8a10e7f0bc28c28dcf14e782014f4a572", language_version = "3.0"),
            "xml": struct(version = "6.6.1", sha256 = "971043b3a0d3da28727e40ed3e0b5d18b742fa5a68665cca88e74b7876d5e025", language_version = "3.8"),
            "yaml": struct(version = "3.1.4", sha256 = "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea", language_version = "3.4"),
            "yaml_edit": struct(version = "2.2.4", sha256 = "07c9e63ba42519745182b88ca12264a7ba2484d8239958778dfe4d44fe760488", language_version = "3.1"),
        },
    ),
}
