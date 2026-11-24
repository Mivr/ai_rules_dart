/// Launch configurations that debug through this tool (W10-2).
///
/// VS Code: the Dart extension runs a `customTool` in place of `flutter`, with the stock
/// arguments (`run --machine --start-paused ... --target lib/main.dart -d <device>`) after the
/// ones the configuration gives. IntelliJ has no such setting: its Flutter plugin always runs
/// `<Flutter SDK>/bin/flutter`. So the tool writes an SDK shim whose `bin/flutter` is this tool and
/// whose other entries link to the real SDK; the project's Flutter SDK path is set to the shim.
/// Every command other than `run` and `attach` passes through to the real SDK.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/src/stock_tool.dart';

/// Where `ide` puts its copy of this tool and the SDK shim, below the project.
const String toolDir = '.dart_tool/flutter_dev';

/// Copies this tool to `.dart_tool/flutter_dev/flutter_dev`, a stable path for launch
/// configurations (a `bazel run` path is not), and returns that path.
String installTool(String projectDir, String self) {
  final dest = File('$projectDir/$toolDir/flutter_dev');
  dest.parent.createSync(recursive: true);
  if (File(self).absolute.path != dest.absolute.path) {
    if (dest.existsSync()) dest.deleteSync();
    // A copy keeps the mode, so the copy is executable too.
    File(self).copySync(dest.path);
  }
  return dest.path;
}

/// The VS Code launch configurations: run and attach, both through the tool.
Map<String, Object?> vscodeLaunch({
  required String target,
  required List<String> flags,
}) {
  Map<String, Object?> config(String request) => <String, Object?>{
    'name': 'flutter_dev ${request == 'launch' ? 'run' : 'attach'} $target',
    'type': 'dart',
    'request': request,
    'cwd': r'${workspaceFolder}',
    'program': 'lib/main.dart',
    'customTool': '\${workspaceFolder}/$toolDir/flutter_dev',
    'customToolReplacesArgs': 0,
    'toolArgs': flags,
  };
  return <String, Object?>{
    'version': '0.2.0',
    'configurations': <Object?>[config('launch'), config('attach')],
  };
}

/// The IntelliJ run configuration (`.run/*.run.xml`) of the Flutter plugin.
String intellijRunConfiguration({
  required String target,
  required List<String> flags,
}) {
  String attr(String s) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(s);
  return '''
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="${attr('flutter_dev run $target')}" type="FlutterRunConfigurationType" factoryName="Flutter">
    <option name="additionalArgs" value="${attr(flags.join(' '))}" />
    <option name="filePath" value="\$PROJECT_DIR\$/lib/main.dart" />
    <method v="2" />
  </configuration>
</component>
''';
}

/// Writes the SDK shim for IntelliJ at `.dart_tool/flutter_dev/sdk` and returns its path.
String writeSdkShim({
  required String projectDir,
  required String tool,
  required String flutterRoot,
  required List<String> flags,
}) {
  final shim = Directory('$projectDir/$toolDir/sdk');
  final bin = Directory('${shim.path}/bin')..createSync(recursive: true);
  final flutter = File('${bin.path}/flutter');
  if (flutter.existsSync()) flutter.deleteSync();
  File(tool).copySync(flutter.path);
  File('${bin.path}/$shimConfigName').writeAsStringSync(
    const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{'flutterRoot': flutterRoot, 'flags': flags}),
  );
  void link(String rel) {
    final real = '$flutterRoot/$rel';
    if (FileSystemEntity.typeSync(real) == FileSystemEntityType.notFound) {
      return;
    }
    final l = Link('${shim.path}/$rel');
    if (l.existsSync()) l.deleteSync();
    l.createSync(real, recursive: true);
  }

  <String>[
    'bin/cache',
    'bin/internal',
    'bin/dart',
    'packages',
    'version',
    '.git',
  ].forEach(link);
  return shim.path;
}

/// The flags an SDK shim adds when this tool runs as its `bin/flutter`.
List<String> shimFlags(String self) {
  final config = File('${File(self).parent.path}/$shimConfigName');
  if (!config.existsSync()) return const <String>[];
  final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  return ((json['flags'] as List<Object?>?) ?? const <Object?>[])
      .cast<String>();
}

/// Writes [content] to [path] when there is no file there yet; returns whether it did.
bool writeNew(String path, String content) {
  final f = File(path);
  if (f.existsSync()) return false;
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  return true;
}
