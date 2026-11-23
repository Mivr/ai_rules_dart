// The strict-layering violation text, shared by every tool that reports one:
// the import check of an executable's own sources (`import_check.dart`) and
// the module compiler (`module_compiler.dart`), which reads a module's imports
// from the compiled kernel. It imports nothing, so both can take it.

/// The package a `package:` URI names, or null for any other URI.
String? packageOfUri(String uri) {
  const prefix = 'package:';
  if (!uri.startsWith(prefix)) return null;
  final String rest = uri.substring(prefix.length);
  final int slash = rest.indexOf('/');
  return slash < 0 ? rest : rest.substring(0, slash);
}

/// The violation line for [path] importing [uri] from package [name].
String violationLine(String label, String path, String uri, String name) =>
    "$label: $path imports '$uri', but package '$name' is not a direct "
    'dependency of $label, only of something it depends on. '
    "Add the target that provides package '$name' to $label's deps.";
