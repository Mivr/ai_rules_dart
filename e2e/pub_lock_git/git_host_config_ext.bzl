"""Materializes a git pub package pinned by full commit, from a git bundle in the workspace (no network).

The bundle holds one commit whose `lib/fmtpkg.dart` carries a literal
`$Format:%H$` placeholder and a multi-line string. `host_config_test.dart`
asserts the placeholder reaches the compiler unexpanded and the newlines
stay LF: a host git configuration with `core.autocrlf=true` (the Git for
Windows default, so this fails without host-independent materialization on
Windows CI) or with an attributes file adding `export-subst` / `eol=crlf`
would change both.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_lock_git_package")

def _impl(mctx):
    pub_lock_git_package(
        name = "fmtpkg",
        package_name = "fmtpkg",
        version = "1.0.0",
        # An absolute host path, resolved fresh on every machine: the
        # extension is marked reproducible below, so this generated
        # repository is recomputed from the workspace and never stored in
        # MODULE.bazel.lock (a locked absolute path would replay this
        # workstation's path on CI).
        url = str(mctx.path(Label("//:fmtpkg.bundle"))),
        resolved_ref = "08da52a5f5ee8530fcffaa7b4a6aecdc09a0e9cc",
        path = ".",
        hub_name = "hub",
        lock_packages = ["fmtpkg"],
    )
    return mctx.extension_metadata(reproducible = True)

gitpkg = module_extension(implementation = _impl)
