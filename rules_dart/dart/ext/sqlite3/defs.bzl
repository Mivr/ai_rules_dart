"""Convenience accessor for the sqlite3 code asset.

Usage in a `dart_test` / `dart_binary` that uses `package:sqlite3` (directly
or transitively, e.g. via `drift`'s `NativeDatabase`):

    load("@rules_dart//dart/ext/sqlite3:defs.bzl", "sqlite3_code_asset")

    dart_test(
        name = "db_test",
        main = "test/db_test.dart",   # plain NativeDatabase.memory(), no FFI ceremony
        code_assets = [sqlite3_code_asset()],
        deps = [...],
    )
"""

visibility("public")

def sqlite3_code_asset():
    """Names the sqlite3 code asset that rules_dart ships.

    Pass the result in `code_assets` of a `dart_test` or `dart_binary` whose code uses
    `package:sqlite3`, so the native library is bundled for the target.

    Returns:
      The label string `@rules_dart//dart/ext/sqlite3:code_asset`.
    """
    return "@rules_dart//dart/ext/sqlite3:code_asset"
