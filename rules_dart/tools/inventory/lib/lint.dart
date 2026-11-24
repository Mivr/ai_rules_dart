/// The lint: every rule, with this repository's scopes.
library;

import 'package:inventory/finding.dart';
import 'package:inventory/rules/depset.dart';
import 'package:inventory/rules/download.dart';
import 'package:inventory/rules/file_length.dart';
import 'package:inventory/rules/floors.dart';
import 'package:inventory/rules/maven.dart';
import 'package:inventory/rules/pub_fetch.dart';
import 'package:inventory/rules/toolchain.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/subsystems.dart';

/// Every rule's name, for the usage text and the debt summary.
const List<String> ruleNames = [
  depsetFlattenRule,
  downloadRule,
  pubFetchRule,
  actionToolchainRule,
  sdkFilesRule,
  bazelDepFloorRule,
  mavenLockRule,
];

/// What a lint run found.
typedef LintResult = ({List<Finding> findings, List<LongFile> longFiles});

/// Runs every rule over [tree], with test paths and source extensions from
/// [table].
LintResult runLint(SourceTree tree, SubsystemTable table) {
  final List<Finding> findings = [
    ...checkDepsetFlatten(tree, table.isProductionSource),
    ...checkDownloads(tree, const [
      (
        module: 'rules_dart',
        bzlDir: 'dart',
        helper: 'dart/private/download.bzl',
      ),
      (
        module: 'rules_flutter',
        bzlDir: 'flutter',
        helper: 'flutter/private/download.bzl',
      ),
    ]),
    ...checkPubFetch(tree, _pubScope),
    ...checkActionToolchains(tree, const [
      (module: 'rules_dart', bzlDir: 'dart', allowSpread: false),
      (module: 'rules_flutter', bzlDir: 'flutter', allowSpread: true),
    ]),
    ...checkSdkFiles(tree, path: 'rules_dart/dart/toolchain.bzl'),
    ...checkBazelDepFloors(tree, (
      module: 'rules_flutter',
      table: 'flutter/tests/dependency_floors.json',
    )),
    ...checkMavenLocks(tree, module: 'rules_flutter'),
  ];
  findings.sort((a, b) {
    final int byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });
  return (
    findings: findings,
    longFiles: longFiles(tree, table.isProductionSource),
  );
}

const PubFetchScope _pubScope = (
  dir: 'rules_dart/dart/pub',
  entry: 'private/pinned_sources.bzl',
  executors: {
    'private/pub_scan.bzl': 'runs the AOT header scanner',
    'private/pub_scanner_repo.bzl': 'builds and runs the AOT header scanner',
    'private/yaml2json.bzl': 'runs the pinned yaml2json binary',
  },
  notPackageFetches: {
    'private/yaml2json.bzl': 'downloads the pinned yaml2json tool',
  },
);
