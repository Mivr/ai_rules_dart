# dart_package_decl_vs_directive

A `# gazelle:dart_package_name` directive and a `dart_package_metadata` in the same
directory naming different packages. Gazelle says so on stderr rather than
resolving it quietly; the `dart_library` it emits still takes its name and
`package_name` from the directive. Pinned here because a diagnostic nobody
asserts is a diagnostic that stops being emitted.
