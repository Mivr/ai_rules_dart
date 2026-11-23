/// Runs the documentation checker over every public Starlark extract.
///
/// `//docs:doc_check_test` runs this with the runfiles paths of the
/// extracts as arguments. A missing extract or source is a failure that names
/// it, never a skip, and the allowlists are the checked-in files.
library;

import 'dart:io';

import 'package:doc_check/checker.dart';
import 'package:doc_check/runfiles_paths.dart';
import 'package:test/test.dart';

String _required(String path) {
  final String? located = locateRunfile(path);
  if (located == null) fail('missing input: $path');
  return located;
}

void main(List<String> extracts) {
  test('the extract list is not empty', () {
    expect(
      extracts,
      isNotEmpty,
      reason: 'no extracts were passed as arguments',
    );
  });

  test('every public extract and its load closure is documented', () {
    final CheckReport report = runCheck(
      CheckInputs(
        extracts: [
          for (final e in extracts) File(_required(e)).readAsBytesSync(),
        ],
        readSource: sourceReader(locateRunfile),
        allowlist: File(_required('_main/tool/doc_check/allowlist.txt'))
            .readAsStringSync(),
        sharedPhrasings: File(
          _required('_main/tool/doc_check/shared_phrasings.txt'),
        ).readAsStringSync(),
      ),
    );
    final Iterable<String> warnings = report.lines.where(
      (l) => l.startsWith('warning: '),
    );
    warnings.forEach(stderr.writeln);
    final Iterable<String> blocking = report.lines.where(
      (l) => !l.startsWith('warning: '),
    );
    blocking.forEach(stderr.writeln);
    expect(blocking.length, 0, reason: 'documentation gaps remain; see above');
  });
}
