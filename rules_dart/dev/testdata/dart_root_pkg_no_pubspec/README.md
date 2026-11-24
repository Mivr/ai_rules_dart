# dart_root_pkg_no_pubspec

Dart sources in the workspace ROOT directory with no `pubspec.yaml` and no
`# gazelle:dart_package_name` directive. `libraryName` falls back to `"lib"`
at the root, and with no pubspec or directive naming the package the library
carries no `package_name`: `dart_library` derives it from the label.

`event.dart` carries `@freezed` and `@JsonSerializable()`. Annotations do not
change what Gazelle emits: the file is an ordinary source of the library.
