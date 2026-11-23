Regenerate all MODULE.bazel.lock files.

## Instructions

1. Read `docs/CHORES.md` § "Lock File Refresh" for the workspace list.

2. Run `cd tools && bazel run //refresh_locks` (add `-- --check` to only list stale lockfiles) to regenerate the lock files of every workspace of both modules.

3. If any workspace fails, investigate and report the error.

4. Commit with message: `chore: refresh MODULE.bazel.lock files`
