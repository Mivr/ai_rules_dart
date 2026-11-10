// Rewrites URI-bearing arguments for `kernel_worker`.

const _kernelWorkerUriFlags = <String>{
  '--dart-sdk-summary',
  '--packages-file',
  '--libraries-file',
  '--multi-root',
  '--input-summary',
  '--input-linked',
  '--source',
  '--native-assets',
};

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

/// True when [s] starts with a Windows drive letter (`C:/...`, `d:\...`, `C:`).
bool isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Converts a Windows drive-letter or UNC file path to a `file://` URI string
/// for `kernel_worker` (`package:frontend_server/compute_kernel.dart`).
String kernelWorkerUri(String pathOrUri) {
  if (isWindowsDrivePath(pathOrUri) || pathOrUri.startsWith(r'\\')) {
    return Uri.file(pathOrUri, windows: true).toString();
  }
  return pathOrUri;
}

/// Converts [pathOrUri] to a local file system path if it is a `file://` URI,
/// or returns it unchanged.
String filePathOf(String pathOrUri) {
  if (pathOrUri.startsWith('file:///')) {
    final String rest = pathOrUri.substring('file:///'.length);
    if (isWindowsDrivePath(rest)) return rest;
  }
  if (pathOrUri.startsWith('file://')) {
    return Uri.parse(pathOrUri).toFilePath(windows: true);
  }
  return pathOrUri;
}

String _rewriteRedirectUri(String value) {
  final int sep = value.indexOf('|');
  if (sep < 0) return kernelWorkerUri(value);
  return '${kernelWorkerUri(value.substring(0, sep))}|'
      '${kernelWorkerUri(value.substring(sep + 1))}';
}

/// Rewrites Windows drive-letter and UNC paths in `kernel_worker` URI-bearing
/// flags to `file:///` URIs while leaving `--output` and other file-system
/// path flags unchanged.
List<String> kernelWorkerArgs(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (_kernelWorkerUriFlags.contains(arg) && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(kernelWorkerUri(args[++i]));
      continue;
    }
    if (arg == '--redirect' && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(_rewriteRedirectUri(args[++i]));
      continue;
    }
    if (arg.startsWith('--redirect=')) {
      final String raw = arg.substring('--redirect='.length);
      out.add('--redirect=${_rewriteRedirectUri(raw)}');
      continue;
    }
    var matchedEq = false;
    for (final String flag in _kernelWorkerUriFlags) {
      final prefix = '$flag=';
      if (arg.startsWith(prefix)) {
        out.add('$flag=${kernelWorkerUri(arg.substring(prefix.length))}');
        matchedEq = true;
        break;
      }
    }
    if (!matchedEq) {
      out.add(arg);
    }
  }
  return out;
}
