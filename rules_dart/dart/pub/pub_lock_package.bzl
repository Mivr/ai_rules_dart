"""Repository rules that download a single package from a pubspec.lock.

Thin public facade: the implementation lives in `//dart/pub/private:pub_lock_package.bzl`."""

load(
    "//dart/pub/private:pub_lock_package.bzl",
    _PUB_LOCK_PACKAGE_ATTRS = "PUB_LOCK_PACKAGE_ATTRS",
    _archive_fetch_error = "archive_fetch_error",
    _derive_language_version = "derive_language_version",
    _fetch_pub_lock_archive = "fetch_pub_lock_archive",
    _make_dart_library_build_content = "make_dart_library_build_content",
    _pub_lock_git_package = "pub_lock_git_package",
    _pub_lock_package = "pub_lock_package",
    _pub_lock_package_sha256_error = "pub_lock_package_sha256_error",
    _run_pub_archive_scan = "run_pub_archive_scan",
    _trim_gzip_trailing_nulls = "trim_gzip_trailing_nulls",
)

visibility("public")

derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content
run_pub_archive_scan = _run_pub_archive_scan
pub_lock_package_sha256_error = _pub_lock_package_sha256_error
trim_gzip_trailing_nulls = _trim_gzip_trailing_nulls
pub_lock_package = _pub_lock_package

# For a rule set that builds its own package repository on the planned shape:
# the same attributes, and the same checked download and extraction.
PUB_LOCK_PACKAGE_ATTRS = _PUB_LOCK_PACKAGE_ATTRS
fetch_pub_lock_archive = _fetch_pub_lock_archive

# The failure of an archive download, naming the package and the credential helper fix.
archive_fetch_error = _archive_fetch_error
pub_lock_git_package = _pub_lock_git_package
