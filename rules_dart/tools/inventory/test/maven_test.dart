import 'package:inventory/finding.dart';
import 'package:inventory/rules/maven.dart';
import 'package:test/test.dart';

import 'trees.dart';

const String _module = 'rules_flutter/e2e/app/MODULE.bazel';
const String _lock = 'rules_flutter/e2e/app/m_install.json';
const String _sha =
    '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6';

String _lockJson({
  Object version = '"3"',
  String artifacts = '',
  String extra = '',
}) =>
    '{"version": $version, $extra"artifacts": {'
    '${artifacts.isEmpty ? '"androidx.annotation:annotation": {"shasums": {"jar": "$_sha"}, "version": "1.9.1"}' : artifacts}}}';

String _install({
  String artifacts = '["androidx.annotation:annotation:1.9.1"]',
  String lockFile = '"//:m_install.json"',
  String name = '"m"',
  String after = '',
}) =>
    'maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")\n'
    'maven.install(\n    name = $name,\n    artifacts = $artifacts,\n'
    '${lockFile.isEmpty ? '' : '    lock_file = $lockFile,\n'})\n$after';

List<Finding> _check({String? module, String? lock}) => checkMavenLocks(
  cleanTree({_module: ?module, _lock: ?lock}),
  module: 'rules_flutter',
);

void expectOne(List<Finding> findings, String text) {
  expect(
    findings,
    hasLength(1),
    reason: findings.map((f) => f.message).join('\n'),
  );
  expect(findings.single.message, contains(text));
}

void main() {
  test('a pinned install and a v2 lock pass', () {
    expect(_check(), isEmpty);
    expect(_check(lock: _lockJson(version: '"2"')), isEmpty);
  });

  test('an install with no lock_file, or two that disagree, is found', () {
    expectOne(_check(module: _install(lockFile: '')), 'has no lock_file');
    expectOne(
      _check(
        module:
            '${_install()}maven.install(name = "m", lock_file = "//:other.json")\n',
      ),
      'disagree',
    );
  });

  test('a commented-out lock_file is no lock_file', () {
    expectOne(
      _check(
        module: _install(lockFile: '')
            .replaceFirst(')\n', '    # lock_file = "//:m_install.json",\n)\n'),
      ),
      'has no lock_file',
    );
  });

  test('a lock outside the workspace, or missing, is found', () {
    expectOne(
      _check(module: _install(lockFile: '"//:../x.json"')),
      'inside the workspace',
    );
    expectOne(
      _check(module: _install(lockFile: '"@other//:x.json"')),
      'inside the workspace',
    );
    expectOne(
      _check(module: _install(lockFile: '"//:gone.json"')),
      'is missing',
    );
  });

  test('a lock that is not JSON, not an object, or of another version', () {
    expectOne(_check(lock: 'not json'), 'not valid JSON');
    expectOne(_check(lock: '[]'), 'expected a JSON object');
    expectOne(
      _check(lock: _lockJson(version: '"4"')),
      'expected lock version 2 or 3',
    );
    expectOne(
      _check(lock: '{"version": "3", "artifacts": {}}'),
      'no valid artifacts map',
    );
  });

  test('every artifact needs a 64-hex sha256 under shasums', () {
    for (final entry in [
      '"a:b": {"shasums": {"jar": "abc"}, "version": "1"}',
      '"a:b": {"shasums": {}, "version": "1"}',
      '"a:b": {"version": "1"}',
      '"a:b": {"shasums": {"jar": "$_sha", "sources": null}, "version": "1"}',
    ]) {
      expectOne(
        _check(
          module: _install(artifacts: '["a:b:1"]'),
          lock: _lockJson(artifacts: entry),
        ),
        'no 64-hex sha256',
      );
    }
  });

  test('a declared coordinate must be in the lock at its version', () {
    expectOne(
      _check(module: _install(artifacts: '["a:b:1"]')),
      'is absent from lock',
    );
    expectOne(
      _check(
        module: _install(artifacts: '["androidx.annotation:annotation:2.0"]'),
      ),
      "version '2.0' is not pinned",
    );
  });

  test('a conflict_resolution that maps to a pinned version counts', () {
    final String module = _install(
      artifacts: '["androidx.annotation:annotation:2.0"]',
    );
    expect(
      _check(
        module: module,
        lock: _lockJson(
          extra: '"conflict_resolution": {"androidx.annotation:annotation:2.0": "androidx.annotation:annotation:1.9.1"}, ',
        ),
      ),
      isEmpty,
    );
    expectOne(
      _check(
        module: module,
        lock: _lockJson(
          extra: '"conflict_resolution": {"androidx.annotation:annotation:2.0": "androidx.annotation:annotation:3.0"}, ',
        ),
      ),
      'is not pinned',
    );
  });

  test('a coordinate without a version is refused', () {
    expectOne(
      _check(module: _install(artifacts: '["androidx.annotation:annotation"]')),
      'explicit non-empty',
    );
  });

  test('maven.artifact tags count, in the list and beside the install', () {
    const tag = 'maven.artifact(group = "a", artifact = "b", version = "1")';
    expectOne(
      _check(module: _install(artifacts: '[$tag]')),
      'is absent from lock',
    );
    expectOne(
      _check(
        module: _install(
          after: '$tag\n'.replaceFirst(
            'maven.artifact(',
            'maven.artifact(name = "m", ',
          ),
        ),
      ),
      'is absent from lock',
    );
    expectOne(
      _check(
        module: _install(
          artifacts: '["androidx.annotation:annotation:1.9.1"] + [$tag]',
        ),
      ),
      'is absent from lock',
    );
  });

  test(
    'an unnamed install is called maven, and a second one is checked too',
    () {
      final List<Finding> findings = _check(
        module: '${_install()}maven.install(artifacts = ["a:b:1"])\n',
      );
      expectOne(findings, "install 'maven': has no lock_file");
    },
  );

  test('a repository with no install at all has nothing to report', () {
    expect(_check(module: '# nothing\n'), isEmpty);
  });
}
