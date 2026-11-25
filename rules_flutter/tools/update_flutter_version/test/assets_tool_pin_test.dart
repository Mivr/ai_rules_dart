import 'package:test/test.dart';

import '../assets_tool_pin.dart';

const _depfile =
    'tool.dill: /sdk/packages/flutter_tools/lib/src/asset.dart '
    '/sdk/packages/flutter_tools/packages/flutter_tools_core/lib/core.dart '
    '/cache/hosted/pub.dev/args-2.7.0/lib/args.dart '
    '/cache/hosted/pub.dev/args-2.7.0/lib/src/utils.dart '
    '/cache/hosted/pub.dev/multicast_dns-0.3.3+1/lib/multicast_dns.dart '
    '/cache/hosted/pub.dev/yaml-3.1.4/lib/yaml.dart';

const _lock = '''
packages:
  args:
    dependency: "direct main"
    description:
      name: args
      sha256: "aaaa"
      url: "https://pub.dev"
    source: hosted
    version: "2.7.0"
  multicast_dns:
    dependency: transitive
    description:
      name: multicast_dns
      sha256: "bbbb"
      url: "https://pub.dev"
    source: hosted
    version: "0.3.3+1"
  yaml:
    dependency: transitive
    description:
      name: yaml
      sha256: "cccc"
      url: "https://pub.dev"
    source: hosted
    version: "3.1.4"
  unused:
    dependency: transitive
    description:
      name: unused
      sha256: "dddd"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
''';

const _packageConfig = '''
{
  "configVersion": 2,
  "packages": [
    {"name": "flutter_tools", "languageVersion": "3.13"},
    {"name": "flutter_tools_core", "languageVersion": "3.12"},
    {"name": "args", "languageVersion": "3.3"},
    {"name": "multicast_dns", "languageVersion": "3.10"},
    {"name": "yaml", "languageVersion": "3.4"},
    {"name": "unused", "languageVersion": "3.0"}
  ]
}
''';

void main() {
  test('hostedPackagesOf names each package a file was read from once', () {
    expect(hostedPackagesOf(_depfile), {
      'args': '2.7.0',
      'multicast_dns': '0.3.3+1',
      'yaml': '3.1.4',
    });
  });

  test('sourcePackagesOf names the path packages of flutter_tools', () {
    expect(sourcePackagesOf(_depfile), {'flutter_tools_core'});
  });

  test('renderAssetsToolPin writes the row from the lock and the config', () {
    expect(
      renderAssetsToolPin(
        version: '3.50.1',
        depfile: _depfile,
        lock: _lock,
        packageConfig: _packageConfig,
      ),
      '    "3.50.1": struct(\n'
      '        flutter_tools_language_version = "3.13",\n'
      '        source_packages = {"flutter_tools_core": "3.12"},\n'
      '        packages = {\n'
      '            "args": struct(version = "2.7.0", sha256 = "aaaa", language_version = "3.3"),\n'
      '            "multicast_dns": struct(version = "0.3.3+1", sha256 = "bbbb", language_version = "3.10"),\n'
      '            "yaml": struct(version = "3.1.4", sha256 = "cccc", language_version = "3.4"),\n'
      '        },\n'
      '    ),\n',
    );
  });

  test('a package the lock holds at another version is an error', () {
    expect(
      () => renderAssetsToolPin(
        version: '3.50.1',
        depfile: _depfile.replaceFirst('yaml-3.1.4', 'yaml-3.1.3'),
        lock: _lock,
        packageConfig: _packageConfig,
      ),
      throwsStateError,
    );
  });
}
