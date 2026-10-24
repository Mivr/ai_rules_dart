"""Creates the shared AOT-compiled pub archive header scanner repository.

Public entrypoint for the `dart` module extension (`//dart:extensions.bzl`),
which instantiates `pub_scanner_repo` once beside `dart_register_toolchains`
for the default toolchain's SDK. The compile implementation stays private
(`//dart/pub/private:pub_scanner_repo.bzl`); the rule object lives here
because a repository rule cannot be imported across files under a private
name. Every `pub.from_lock` hub fetch in every consumer build runs the
executable this repository holds, so the end-to-end header-scan coverage in
`//e2e/pub_symlink` exercises this rule on every hostile hub.
"""

load("//dart/pub/private:pub_scanner_repo.bzl", "pub_scanner_repo_impl")

pub_scanner_repo = repository_rule(
    implementation = pub_scanner_repo_impl,
    doc = "Compiles pub_scan.dart to the native scanner executable run over every fetched pub archive before extraction.",
    attrs = {
        "scanner_src": attr.string(
            doc = "The pub_scan.dart source text. Passed as text so editing the scanner recompiles it.",
            mandatory = True,
        ),
        "dart_version": attr.string(
            doc = "The SDK version the scanner compiles from. A toolchain change recompiles it.",
            mandatory = True,
        ),
    },
)
