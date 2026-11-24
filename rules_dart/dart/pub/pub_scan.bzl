"""Runs the AOT header scanner over fetched pub archives, and the post-extraction symlink walk.

Thin public facade: the implementation lives in `//dart/pub/private:pub_scan.bzl`."""

load(
    "//dart/pub/private:pub_scan.bzl",
    _PUB_SCANNER_LABEL = "PUB_SCANNER_LABEL",
    _PUB_SCANNER_WINDOWS_LABEL = "PUB_SCANNER_WINDOWS_LABEL",
    _check_package_symlinks = "check_package_symlinks",
    _run_pub_archive_scan = "run_pub_archive_scan",
    _run_pub_archive_scans = "run_pub_archive_scans",
)

visibility("public")

PUB_SCANNER_LABEL = _PUB_SCANNER_LABEL
PUB_SCANNER_WINDOWS_LABEL = _PUB_SCANNER_WINDOWS_LABEL
check_package_symlinks = _check_package_symlinks
run_pub_archive_scans = _run_pub_archive_scans
run_pub_archive_scan = _run_pub_archive_scan
