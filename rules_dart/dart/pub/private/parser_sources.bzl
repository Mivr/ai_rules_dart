"""Source labels for the pubspec facts digest.

`READER_SOURCE_LABELS` lists the files whose bytes key the pub extension's
cycle-planning facts (see `parser_schema` in `:pub_scc_facts.bzl`): the `yq`
release, its checksums and the conversion (`yq.bzl`) and the checks and
projection over the decoded data (`pubspec_data.bzl`).

A bare `//` label resolves in this extension's own repository, whatever
module name it is known by. It lives here, not in `extensions.bzl`, so that
file stays small; `//dart/pub:pub_scc.bzl` re-exports it for rules_flutter.
"""

visibility(["//dart/..."])

READER_SOURCE_LABELS = [
    Label("//dart/pub/private:yq.bzl"),
    Label("//dart/pub/private:pubspec_data.bzl"),
]
