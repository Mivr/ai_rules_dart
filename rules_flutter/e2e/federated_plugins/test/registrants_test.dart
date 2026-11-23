/// E2E test: verifies federated plugin resolution in generated Linux registrants.
///
/// In each scenario:
/// 1. `app_sp_wrapper` (deps `fed_sp` and `fed_wrapper`): registers `fed_sp_linux`
///    and not `fed_alt_linux`.
/// 2. `app_sp_chain` (deps `fed_sp` and `fed_chain`): registers `fed_sp_linux`
///    and not `fed_alt_linux`.
/// 3. `app_sp_alt_linux` (deps `fed_sp` and `fed_alt_linux` directly): registers
///    `fed_alt_linux` and not `fed_sp_linux`.
library;

import 'dart:io';

const _defaultPlugin = 'fed_sp_linux';
const _defaultPluginClass = 'FedSpLinuxPlugin';

const _altPlugin = 'fed_alt_linux';
const _altPluginClass = 'FedAltLinuxPlugin';

String _resolvePath(String relativePath) {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir != null && workspace != null) {
    final file = File('$srcDir/$workspace/$relativePath');
    if (file.existsSync()) {
      return file.path;
    }
  }
  final runfilesDir = Platform.environment['RUNFILES_DIR'];
  if (runfilesDir != null && workspace != null) {
    final file = File('$runfilesDir/$workspace/$relativePath');
    if (file.existsSync()) {
      return file.path;
    }
  }
  final local = File(relativePath);
  if (local.existsSync()) {
    return local.path;
  }
  stderr.writeln('Error: $relativePath was not found');
  exit(1);
}

bool _verifyRegistrant({
  required String application,
  required String relativeFile,
  required String expectedPlugin,
  required String expectedClass,
  required String forbiddenPlugin,
  required String forbiddenClass,
}) {
  final fullPath = _resolvePath(relativeFile);
  final content = File(fullPath).readAsStringSync();
  var passed = true;

  if (!content.contains(expectedClass)) {
    stderr.writeln(
      'FAIL: application $application: file $relativeFile does not register $expectedPlugin',
    );
    passed = false;
  }

  if (content.contains(forbiddenClass)) {
    stderr.writeln(
      'FAIL: application $application: file $relativeFile unexpectedly registers $forbiddenPlugin',
    );
    passed = false;
  }

  if (passed) {
    stdout.writeln(
      'ok: application $application correctly registers $expectedPlugin in $relativeFile',
    );
  }

  return passed;
}

void main() {
  final results = [
    _verifyRegistrant(
      application: 'app_sp_wrapper',
      relativeFile: 'app_sp_wrapper_registrant_native_plugin_registrant.cc',
      expectedPlugin: _defaultPlugin,
      expectedClass: _defaultPluginClass,
      forbiddenPlugin: _altPlugin,
      forbiddenClass: _altPluginClass,
    ),
    _verifyRegistrant(
      application: 'app_sp_chain',
      relativeFile: 'app_sp_chain_registrant_native_plugin_registrant.cc',
      expectedPlugin: _defaultPlugin,
      expectedClass: _defaultPluginClass,
      forbiddenPlugin: _altPlugin,
      forbiddenClass: _altPluginClass,
    ),
    _verifyRegistrant(
      application: 'app_sp_alt_linux',
      relativeFile: 'app_sp_alt_linux_registrant_native_plugin_registrant.cc',
      expectedPlugin: _altPlugin,
      expectedClass: _altPluginClass,
      forbiddenPlugin: _defaultPlugin,
      forbiddenClass: _defaultPluginClass,
    ),
  ];

  if (results.contains(false)) {
    exit(1);
  }
}
