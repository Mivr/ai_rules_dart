// Runs one package's `hook/link.dart` for `dart_link_hook`.
//
// Builds the hook's `LinkInput` (package, roots, recorded uses), runs the hook
// on the hermetic SDK's `dart`, checks its `LinkOutput`, and copies each data
// asset it emits to the output Bazel declared for that asset's id.
//
// Usage:
//   link_hook_runner --dart <dart> --packages <package_config.json>
//       --package-name <name> --package-root <dir> --hook <hook/link.dart>
//       --recorded-uses <json> --output <link_output.json>
//       [--data-asset <name>=<path>]...
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

import 'package:rules_dart_guard/directive_guard.dart';

Future<void> main(List<String> arguments) async {
  final parsed = _parseHookArgs(arguments);

  final scratch = Directory.systemTemp.createTempSync('dart_link_hook_');
  try {
    final staged = _stageHook(parsed, scratch);
    final output = await _runHook(parsed, staged, scratch);
    _checkDeclaredAssets(parsed.packageName, parsed.declared, output);
    _emitDataAssets(parsed, output);
  } on _LinkFailure catch (failure) {
    stderr.writeln(failure.message);
    exitCode = 1;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Parsed `link_hook_runner` command line.
typedef _HookArgs = ({
  String dart,
  String packages,
  String packageName,
  String packageRoot,
  String hook,
  String recordedUses,
  String output,
  Map<String, String> declared,
});

/// Parses the command line into hook inputs and declared data assets.
_HookArgs _parseHookArgs(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('dart', mandatory: true)
    ..addOption('packages', mandatory: true)
    ..addOption('package-name', mandatory: true)
    ..addOption('package-root', mandatory: true)
    ..addOption('hook', mandatory: true)
    ..addOption('recorded-uses', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addMultiOption('data-asset', splitCommas: false);
  final args = parser.parse(arguments);
  final packageName = args.option('package-name')!;

  // Declared data assets, by name within the package.
  final declared = <String, String>{};
  for (final entry in args.multiOption('data-asset')) {
    final at = entry.indexOf('=');
    declared[entry.substring(0, at)] = entry.substring(at + 1);
  }
  return (
    dart: args.option('dart')!,
    packages: args.option('packages')!,
    packageName: packageName,
    packageRoot: args.option('package-root')!,
    hook: args.option('hook')!,
    recordedUses: args.option('recorded-uses')!,
    output: args.option('output')!,
    declared: declared,
  );
}

/// Stages the workspace and refuses hook sources whose directives reach
/// outside the staged tree.
///
/// No staged source may read the host: the hook runs with its staged
/// package root as its working directory, so a `file:` URI, a `package:`
/// URI climbing above its package, or a relative URI climbing out of the
/// staged tree in the hook (or anything it reaches) would read an
/// undeclared file. Refuse before running, through the one shared
/// staged-source check. At run time the hook is confined to its declared
/// inputs only by Bazel's sandbox or remote execution; an unsandboxed
/// strategy (`--spawn_strategy=local`) does not confine it.
({File packages, Directory packageRoot, File hook}) _stageHook(
  _HookArgs parsed,
  Directory scratch,
) {
  final staged = stageWorkspace(
    packages: File(parsed.packages),
    packageRoot: Directory(parsed.packageRoot),
    hook: File(parsed.hook),
    scratch: scratch,
  );
  final stagedViolations = findStagedDirectiveViolations([
    staged.packageRoot.path,
  ], tool: 'link_hook_runner');
  if (stagedViolations.isNotEmpty) {
    _fail(
      parsed.packageName,
      'reads files outside its declared inputs',
      stagedViolations.join('\n'),
    );
  }
  return staged;
}

/// Runs the hook and returns its validated `LinkOutput`.
Future<LinkOutput> _runHook(
  _HookArgs parsed,
  ({File packages, Directory packageRoot, File hook}) staged,
  Directory scratch,
) async {
  final packageName = parsed.packageName;
  final input = _linkInput(
    packageName: packageName,
    packageRoot: staged.packageRoot,
    recordedUses: File(parsed.recordedUses).absolute,
    scratch: scratch,
  );
  final inputFile = File('${scratch.path}/input.json')
    ..writeAsStringSync(jsonEncode(input.json));

  final homeDir = Directory('${scratch.path}/home')
    ..createSync(recursive: true);
  final hook = await Process.run(
    File(parsed.dart).absolute.path,
    [
      '--packages=${staged.packages.path}',
      staged.hook.path,
      '--config=${inputFile.path}',
    ],
    workingDirectory: input.packageRoot.toFilePath(),
    environment: {
      'HOME': homeDir.path,
      'USERPROFILE': homeDir.path,
      'LOCALAPPDATA': homeDir.path,
      'APPDATA': homeDir.path,
    },
  );
  final hookLog = [
    if ('${hook.stderr}'.trim().isNotEmpty) '${hook.stderr}'.trim(),
    if ('${hook.stdout}'.trim().isNotEmpty) '${hook.stdout}'.trim(),
  ].join('\n');
  final outputFile = File.fromUri(input.outputFile);
  if (hook.exitCode != 0) {
    _fail(packageName, 'exited with code ${hook.exitCode}', hookLog);
  }
  if (!outputFile.existsSync()) {
    _fail(packageName, 'wrote no output', hookLog);
  }
  final outputJson =
      jsonDecode(outputFile.readAsStringSync()) as Map<String, Object?>;
  final output = switch (LinkOutputMaybeFailure(outputJson)) {
    final LinkOutput success => success,
    final LinkOutputFailure failure => _fail(
      packageName,
      'reported a ${failure.type.name} failure',
      hookLog,
    ),
  };
  await _validateLinkOutput(packageName, input, output);
  return output;
}

/// Refuses a `LinkOutput` that fails validator or routing checks.
Future<void> _validateLinkOutput(
  String packageName,
  LinkInput input,
  LinkOutput output,
) async {
  final errors = [
    ...await ProtocolBase.validateLinkOutput(input, output),
    ...await DataAssetsExtension().validateLinkOutput(input, output),
    for (final asset in output.assets.encodedAssets)
      if (!asset.isDataAsset)
        'emitted a `${asset.type}` asset; dart_link_hook collects only '
            'data assets',
    if (output.assets.encodedAssetsForLink.isNotEmpty)
      'routed assets to the link hooks of '
          '${output.assets.encodedAssetsForLink.keys.join(', ')}; '
          'dart_link_hook runs each hook on its own',
  ];
  if (errors.isNotEmpty) {
    _fail(packageName, 'produced unusable output', errors.join('\n'));
  }
}

/// Refuses an output whose data assets differ from the declared set.
void _checkDeclaredAssets(
  String packageName,
  Map<String, String> declared,
  LinkOutput output,
) {
  final emitted = {for (final asset in output.assets.data) asset.name: asset};
  final undeclared = emitted.keys.where((n) => !declared.containsKey(n));
  final missing = declared.keys.where((n) => !emitted.containsKey(n));
  if (undeclared.isNotEmpty || missing.isNotEmpty) {
    String ids(Iterable<String> names) =>
        names.map((n) => '  package:$packageName/$n').join('\n');
    _fail(
      packageName,
      'emitted data assets other than the ones `data_assets` declares',
      [
        if (undeclared.isNotEmpty)
          'Emitted but not declared:\n${ids(undeclared)}',
        if (missing.isNotEmpty) 'Declared but not emitted:\n${ids(missing)}',
      ].join('\n'),
    );
  }
}

/// Copies the emitted data assets into place and records them.
void _emitDataAssets(_HookArgs parsed, LinkOutput output) {
  final packageName = parsed.packageName;
  final emitted = {for (final asset in output.assets.data) asset.name: asset};
  final declared = parsed.declared;
  for (final MapEntry(key: name, value: path) in declared.entries) {
    final dst = File(path);
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(File.fromUri(emitted[name]!.file).readAsBytesSync());
  }
  // The record kept of the hook's output names each asset by its declared
  // output rather than the scratch file it was copied from, and drops the
  // timestamp, so the same inputs always produce the same bytes.
  final record = {
    'assets': [
      for (final name in declared.keys)
        DataAsset(
          package: packageName,
          name: name,
          file: Uri.file(declared[name]!),
        ).encode().toJson(),
    ],
  };
  File(parsed.output)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record));
}

/// Copies the manifest-declared files for a link hook action into [scratch]
/// so the hook sees only declared sources in an isolated directory tree.
({File packages, Directory packageRoot, File hook}) stageWorkspace({
  required File packages,
  required Directory packageRoot,
  required File hook,
  required Directory scratch,
}) {
  final stageParent = packageRoot.parent;
  final manifest = File('${stageParent.path}/.manifest');
  if (!manifest.existsSync()) {
    return (
      packages: packages.absolute,
      packageRoot: packageRoot.absolute,
      hook: hook.absolute,
    );
  }
  final stageName = stageParent.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final hookDirName = packageRoot.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final stagedRoot = Directory('${scratch.path}/$stageName')
    ..createSync(recursive: true);
  for (final line in manifest.readAsLinesSync()) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length != 3) continue;
    final kind = parts[0];
    final rel = parts[1];
    final srcPath = parts[2];
    if (kind == 'file') {
      final dst = File('${stagedRoot.path}/$rel');
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(File(srcPath).readAsBytesSync());
    } else if (kind == 'dir') {
      _copyDirectory(Directory(srcPath), Directory('${stagedRoot.path}/$rel'));
    }
  }
  final stagedPackages = File(
    '${scratch.path}/${packages.uri.pathSegments.last}',
  )..writeAsBytesSync(packages.readAsBytesSync());
  final stagedPackageRoot = Directory('${stagedRoot.path}/$hookDirName')
    ..createSync(recursive: true);
  final stagedHook = File('${stagedPackageRoot.path}/hook/link.dart');
  if (!stagedHook.existsSync()) {
    stagedHook.parent.createSync(recursive: true);
    stagedHook.writeAsBytesSync(hook.readAsBytesSync());
  }
  return (
    packages: stagedPackages.absolute,
    packageRoot: stagedPackageRoot.absolute,
    hook: stagedHook.absolute,
  );
}

void _copyDirectory(Directory src, Directory dst) {
  if (!src.existsSync()) return;
  dst.createSync(recursive: true);
  final prefix = src.uri.path;
  for (final entity in src.listSync(recursive: true, followLinks: true)) {
    if (entity is! File) continue;
    final rel = entity.uri.path.substring(prefix.length);
    final out = File.fromUri(dst.uri.resolve(rel));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(entity.readAsBytesSync());
  }
}

LinkInput _linkInput({
  required String packageName,
  required Directory packageRoot,
  required File recordedUses,
  required Directory scratch,
}) {
  final builder = LinkInputBuilder()
    ..setupShared(
      packageRoot: packageRoot.uri,
      packageName: packageName,
      outputDirectoryShared: Directory('${scratch.path}/shared').uri,
      outputFile: File('${scratch.path}/output.json').uri,
    )
    ..setupLink(
      assets: [],
      assetsFromLinking: [],
      recordedUsesFile: recordedUses.uri,
    )
    ..addExtension(DataAssetsExtension());
  return builder.build();
}

Never _fail(String packageName, String what, String detail) =>
    throw _LinkFailure(
      [
        'dart_link_hook: hook/link.dart of package `$packageName` $what.',
        if (detail.isNotEmpty) detail,
      ].join('\n'),
    );

/// A hook or its output that fails the action; thrown so the scratch
/// directory is still removed.
final class _LinkFailure implements Exception {
  _LinkFailure(this.message);

  final String message;
}
