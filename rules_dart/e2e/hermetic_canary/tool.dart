import 'dart:io';

/// Reads `/usr/bin/env` and writes its byte length to the declared output.
///
/// The hermetic Linux sandbox hides `/usr/bin`, so this tool succeeds with
/// default flags and fails there. When the file is absent the path is
/// printed and the tool exits non-zero so the CI grep finds `/usr/bin/env`.
void main(List<String> args) {
  const String path = '/usr/bin/env';
  final File probed = File(path);
  if (!probed.existsSync()) {
    stderr.writeln('hermetic canary: missing $path');
    exit(1);
  }
  final List<int> bytes = probed.readAsBytesSync();
  File(args[0]).writeAsStringSync('${bytes.length}\n');
}
