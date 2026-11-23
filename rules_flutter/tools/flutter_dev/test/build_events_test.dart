import 'dart:convert';

import 'package:flutter_dev/src/build_events.dart';
import 'package:test/test.dart';

/// Build event lines of the shape Bazel writes: the workspace, nested named file sets, and target
/// completions for the target itself and for an aspect on it.
List<String> _events() => <Map<String, Object?>>[
  <String, Object?>{
    'id': <String, Object?>{'workspace': <String, Object?>{}},
    'workspaceInfo': <String, Object?>{'localExecRoot': '/ob/execroot/_main'},
  },
  <String, Object?>{
    'id': <String, Object?>{
      'namedSet': <String, Object?>{'id': '1'},
    },
    'namedSetOfFiles': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{
          'name': 'app.apk',
          'pathPrefix': <String>['bazel-out', 'k8-dbg', 'bin'],
        },
      ],
    },
  },
  <String, Object?>{
    'id': <String, Object?>{
      'namedSet': <String, Object?>{'id': '2'},
    },
    'namedSetOfFiles': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{
          'name': 'app_flutter.flutter_stock_dev.json',
          'pathPrefix': <String>['bazel-out', 'k8-dbg-ST-1', 'bin'],
        },
      ],
      'fileSets': <Object?>[
        <String, Object?>{'id': '3'},
      ],
    },
  },
  <String, Object?>{
    'id': <String, Object?>{
      'namedSet': <String, Object?>{'id': '3'},
    },
    'namedSetOfFiles': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{
          'name': 'app_flutter.package_config.json',
          'pathPrefix': <String>['bazel-out', 'k8-dbg-ST-1', 'bin'],
        },
      ],
    },
  },
  <String, Object?>{
    'id': <String, Object?>{
      'targetCompleted': <String, Object?>{'label': '@@//:app'},
    },
    'completed': <String, Object?>{
      'success': true,
      'outputGroup': <Object?>[
        <String, Object?>{
          'name': 'default',
          'fileSets': <Object?>[
            <String, Object?>{'id': '1'},
          ],
        },
      ],
    },
  },
  <String, Object?>{
    'id': <String, Object?>{
      'targetCompleted': <String, Object?>{
        'label': '//:app',
        'aspect': '@@rules+//flutter:dev_files.bzl%flutter_dev_files',
      },
    },
    'completed': <String, Object?>{
      'success': true,
      'outputGroup': <Object?>[
        <String, Object?>{
          'name': 'flutter_stock_dev',
          'fileSets': <Object?>[
            <String, Object?>{'id': '2'},
            <String, Object?>{'id': '3'},
          ],
        },
      ],
    },
  },
].map(jsonEncode).toList();

void main() {
  test('files by target and group, nested sets expanded once, aspect groups under the target', () {
    final out = BuildOutputs.parse(_events());
    expect(out.execRoot, '/ob/execroot/_main');
    expect(out.outputBase, '/ob');
    expect(out.files('//:app', 'default'), <String>[
      'bazel-out/k8-dbg/bin/app.apk',
    ]);
    expect(out.files('@@//:app', 'flutter_stock_dev'), <String>[
      'bazel-out/k8-dbg-ST-1/bin/app_flutter.flutter_stock_dev.json',
      'bazel-out/k8-dbg-ST-1/bin/app_flutter.package_config.json',
    ]);
    expect(out.files('//:other', 'default'), isEmpty);
    expect(out.allFiles('default'), <String>['bazel-out/k8-dbg/bin/app.apk']);
    expect(out.absolute('bazel-out/x'), '/ob/execroot/_main/bazel-out/x');
  });

  test('a file without the workspace event is refused', () {
    expect(() => BuildOutputs.parse(_events().skip(1)), throwsFormatException);
  });

  test('labels compare without their repository prefix', () {
    expect(normalizeLabel('@@//:a'), '//:a');
    expect(normalizeLabel('@//p:a'), '//p:a');
    expect(normalizeLabel('@@ext+//p:a'), '@@ext+//p:a');
  });
}
