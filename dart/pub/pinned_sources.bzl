"""Single validation entry point for pinned pub sources and the shared two-phase host-git helpers.

Thin public facade: the implementation lives in `//dart/pub/private:pinned_sources.bzl`."""

load(
    "//dart/pub/private:pinned_sources.bzl",
    _git_materialize = "git_materialize",
    _git_transport_fetch = "git_transport_fetch",
    _git_version_error = "git_version_error",
    _parse_git_version = "parse_git_version",
    _pinned_source_error = "pinned_source_error",
)

visibility("public")

pinned_source_error = _pinned_source_error
parse_git_version = _parse_git_version
git_version_error = _git_version_error
git_transport_fetch = _git_transport_fetch
git_materialize = _git_materialize
