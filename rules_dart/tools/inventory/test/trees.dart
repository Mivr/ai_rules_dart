/// A small repository that passes every lint rule, to break one rule at a time.
library;

import 'package:inventory/source_tree.dart';

const String _sha =
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

/// The files of a repository that has nothing to report.
Map<String, String> cleanFiles() => {
  'rules_dart/MODULE.bazel': 'module(name = "ai_rules_dart")\n',
  'rules_dart/dart/private/download.bzl':
      'def pinned_download(ctx):\n    ctx.download()\n'
      'def pinned_download_and_extract(ctx):\n    ctx.download_and_extract()\n',
  'rules_dart/dart/private/rule.bzl':
      'def _impl(ctx):\n'
      '    ctx.actions.run(executable = x, toolchain = T)\n'
      '    return depset(transitive = [a])\n',
  'rules_dart/dart/toolchain.bzl': [
    for (final a in [
      'sdk_root',
      'compile_files',
      'runtime_files',
      'analyze_files',
    ])
      'x = ctx.attr.$a[DefaultInfo].files\n',
  ].join(),
  'rules_dart/dart/pub/private/pinned_sources.bzl':
      'def pinned_source_error(x):\n    return None\n'
      'def git_transport_fetch(ctx):\n'
      '    ctx.execute(["git", "--no-replace-objects", "fetch"])\n'
      'def git_materialize(ctx):\n'
      '    ctx.execute(["git", "--no-replace-objects", "archive"])\n',
  'rules_dart/dart/pub/extensions.bzl':
      'load("//dart/pub:pinned_sources.bzl", "pinned_source_error")\n'
      'def f(ctx):\n    pinned_source_error(x)\n    pinned_download(ctx)\n',
  'rules_flutter/MODULE.bazel':
      'bazel_dep(name = "rules_cc", version = "0.2.20")\n'
      'bazel_dep(name = "platforms", version = "1.1.0")\n'
      'bazel_dep(name = "buildifier", version = "9.9.9", dev_dependency = True)\n'
      'single_version_override(module_name = "rules_cc", version = "0.2.26")\n',
  'rules_flutter/flutter/tests/dependency_floors.json': '''
{
  "rules_cc": {"floor": "0.2.20", "current": "0.2.26", "resolved": "0.2.26",
               "lifted_by": ["platforms"], "symbol": "x"},
  "platforms": {"floor": "1.1.0", "current": "1.1.0", "resolved": "1.1.0",
                "lifted_by": [], "symbol": "y"}
}
''',
  'rules_flutter/flutter/private/download.bzl':
      'def pinned_download(ctx):\n    ctx.download()\n'
      'def pinned_download_and_extract(ctx):\n    ctx.download_and_extract()\n',
  'rules_flutter/flutter/private/rule.bzl':
      'def _impl(ctx):\n    ctx.actions.run(**kwargs)\n',
  'rules_flutter/e2e/app/MODULE.bazel':
      'maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")\n'
      'maven.install(\n'
      '    name = "m",\n'
      '    artifacts = ["androidx.annotation:annotation:1.9.1"],\n'
      '    lock_file = "//:m_install.json",\n'
      ')\n',
  'rules_flutter/e2e/app/m_install.json':
      '{"version": "3", "artifacts": {"androidx.annotation:annotation": '
      '{"shasums": {"jar": "$_sha"}, "version": "1.9.1"}}}',
};

/// A tree over [cleanFiles] with [overrides] applied; a null value deletes.
SourceTree cleanTree([Map<String, String?> overrides = const {}]) {
  final Map<String, String> files = cleanFiles();
  for (final MapEntry<String, String?> entry in overrides.entries) {
    final String? text = entry.value;
    if (text == null) {
      files.remove(entry.key);
    } else {
      files[entry.key] = text;
    }
  }
  return SourceTree.inMemory(files);
}
