"""Repository-rule metadata that lets Bazel share one extraction across output bases.

A repository rule that returns `repo_metadata(reproducible = True)` has its
result stored in the repo contents cache, so a second output base reuses the
extracted tree instead of downloading and extracting again. That is only sound
when the tree holds no link into the workspace or the host: download mode.
Local mode links a user SDK by absolute path and must stay unmarked.
"""

visibility(["//flutter/..."])

def download_mode_metadata(rctx):
    """The `repo_metadata` result for a rule that has a download and a local mode.

    Args:
        rctx: The repository context. Its `local_path` attr, when it has one, selects local mode.

    Returns:
        A `repo_metadata` marked reproducible unless `local_path` is set.
    """
    return rctx.repo_metadata(reproducible = not getattr(rctx.attr, "local_path", ""))
