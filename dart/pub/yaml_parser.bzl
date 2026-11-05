"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Thin public facade: the implementation lives in `//dart/pub/private:yaml_parser.bzl`."""

load(
    "//dart/pub/private:yaml_parser.bzl",
    _is_valid_commit_sha = "is_valid_commit_sha",
    _is_valid_git_ref = "is_valid_git_ref",
    _is_valid_resolved_ref = "is_valid_resolved_ref",
    _is_valid_sdk_constraint = "is_valid_sdk_constraint",
    _is_valid_sha256 = "is_valid_sha256",
    _lock_package_error = "lock_package_error",
    _parse_pubspec_deps = "parse_pubspec_deps",
    _parse_pubspec_document = "parse_pubspec_document",
    _parse_pubspec_document_error = "parse_pubspec_document_error",
    _parse_pubspec_lock = "parse_pubspec_lock",
    _parse_pubspec_sdk_constraint = "parse_pubspec_sdk_constraint",
    _pubspec_lock_error = "pubspec_lock_error",
    _pubspec_sdk_constraint_error = "pubspec_sdk_constraint_error",
)

visibility("public")

parse_pubspec_document_error = _parse_pubspec_document_error
parse_pubspec_document = _parse_pubspec_document
pubspec_lock_error = _pubspec_lock_error
parse_pubspec_lock = _parse_pubspec_lock
is_valid_sha256 = _is_valid_sha256
is_valid_git_ref = _is_valid_git_ref
is_valid_resolved_ref = _is_valid_resolved_ref
is_valid_commit_sha = _is_valid_commit_sha
lock_package_error = _lock_package_error
parse_pubspec_deps = _parse_pubspec_deps
parse_pubspec_sdk_constraint = _parse_pubspec_sdk_constraint
is_valid_sdk_constraint = _is_valid_sdk_constraint
pubspec_sdk_constraint_error = _pubspec_sdk_constraint_error
