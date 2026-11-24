import 'dart:convert';

import 'package:conformance/rules_side.dart';
import 'package:test/test.dart';

void main() {
  test('build events name each test target\'s report, cached ones too', () {
    Map<String, Object?> result(String label, String path, bool cached) => {
      'id': {
        'testResult': {'label': label, 'run': 1, 'shard': 1, 'attempt': 1},
      },
      'testResult': {
        'testActionOutput': [
          {'name': 'test.log', 'uri': 'file://$path/test.log'},
          {'name': 'test.xml', 'uri': 'file://$path/test.xml'},
        ],
        'cachedLocally': cached,
        'status': 'PASSED',
      },
    };
    final lines = [
      jsonEncode({
        'id': {
          'targetCompleted': {'label': '//:a_test'},
        },
        'completed': {'success': true},
      }),
      jsonEncode(result('//:a_test', '/t/a_test', false)),
      jsonEncode(result('//dir:b_test', '/t/dir/b_test', true)),
      'not json',
    ];
    // The report path is the host's own spelling of the `file:` URI.
    String native(String path) => Uri.file(path).toFilePath();
    expect(testReportsFromBuildEvents(lines), {
      '//:a_test': native('/t/a_test/test.xml'),
      '//dir:b_test': native('/t/dir/b_test/test.xml'),
    });
  });
}
