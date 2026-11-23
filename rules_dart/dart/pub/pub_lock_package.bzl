"""Repository rules that download a single package from a pubspec.lock.

Thin public facade: the implementation lives in `//dart/pub/private:pub_lock_package.bzl`."""

load(
    "//dart/pub/private:pub_lock_package.bzl",
    _derive_language_version = "derive_language_version",
    _make_dart_library_build_content = "make_dart_library_build_content",
    _pub_lock_git_package = "pub_lock_git_package",
    _pub_lock_package = "pub_lock_package",
    _pub_lock_package_sha256_error = "pub_lock_package_sha256_error",
    _pub_lock_spoke_dep_labels = "pub_lock_spoke_dep_labels",
    _run_pub_archive_scan = "run_pub_archive_scan",
    _trim_gzip_trailing_nulls = "trim_gzip_trailing_nulls",
)

visibility("public")

derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content
run_pub_archive_scan = _run_pub_archive_scan
pub_lock_package_sha256_error = _pub_lock_package_sha256_error
trim_gzip_trailing_nulls = _trim_gzip_trailing_nulls
pub_lock_spoke_dep_labels = _pub_lock_spoke_dep_labels
pub_lock_package = _pub_lock_package
pub_lock_git_package = _pub_lock_git_package
