"""Red workspace for the fail-closed download helpers.

Each case below fetches the committed `fixture.bin` over a local `file://`
URL through `pinned_download`, with a different digest shape. The malformed
shapes fail before any bytes move; the wrong digest fails on the bytes; the
correct digest succeeds. CI builds each repository separately and greps the
exact message, so deleting the helper's check turns its step red instead of
surfacing a neighbouring message. No network is involved. The repository
rule takes the fixture as a label attribute and builds the `file://` URL at
fetch time, so no absolute path ever reaches the module extension or the
lockfile (`file:///C:/...` on Windows, `file:///...` elsewhere).
"""

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/private:download.bzl", "pinned_download")

# The sha256 of `fixture.bin` (`sha256sum fixture.bin`).
_GOOD_DIGEST = "86bea300d6701fb6c1fddc33b21235231d108b44a9793db9dcd48940fa46a6a6"

# Same digest with its last digit changed: well-formed but wrong.
_WRONG_DIGEST = "86bea300d6701fb6c1fddc33b21235231d108b44a9793db9dcd48940fa46a6a7"

def _fixture_url(path):
    # Built at fetch time, inside the repository rule: the module extension
    # never sees an absolute path, so none is recorded in MODULE.bazel.lock.
    # `str` spells paths with forward slashes on every platform; a Windows
    # absolute path starts with a drive letter, a POSIX one with `/`.
    raw = str(path)
    if raw.startswith("/"):
        return "file://" + raw
    return "file:///" + raw

def _digest_case_impl(ctx):
    # The `x if cond else ""` shape: a digest expression that is not a blank
    # literal still fetches unpinned when the condition is false. The helper
    # sees only the resulting blank string and must refuse it like a literal
    # one.
    sha256 = ctx.attr.sha256 if ctx.attr.enforce else ""
    pinned_download(
        ctx,
        url = _fixture_url(ctx.path(ctx.attr.fixture)),
        output = "fixture.bin",
        sha256 = sha256,
    )
    ctx.file("BUILD.bazel", "exports_files([\"fixture.bin\"])\nfilegroup(name = \"fixture\", srcs = [\"fixture.bin\"])\n")

digest_case = repository_rule(
    implementation = _digest_case_impl,
    attrs = {
        "fixture": attr.label(
            doc = "The committed fixture file the case fetches over file://.",
            mandatory = True,
            allow_single_file = True,
        ),
        "sha256": attr.string(
            doc = "The digest the fetch is pinned to.",
            mandatory = True,
        ),
        "enforce": attr.bool(
            doc = "When False, the digest expression evaluates to blank, exercising the conditional shape.",
            default = True,
        ),
    },
    doc = "Fetches the digest-mismatch fixture through `pinned_download`.",
)

_fixture = tag_class(
    attrs = {
        "fixture": attr.label(
            doc = "The committed fixture file the cases fetch over file://.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
)

def _digest_impl(ctx):
    fixtures = []
    for mod in ctx.modules:
        for tag in mod.tags.fixture:
            fixtures.append(tag.fixture)
    if len(fixtures) != 1:
        fail("digest extension wants exactly one fixture tag, got %d." % len(fixtures))
    fixture = fixtures[0]
    digest_case(name = "bad_empty", fixture = fixture, sha256 = "")
    digest_case(name = "bad_short", fixture = fixture, sha256 = _GOOD_DIGEST[:-1])
    digest_case(name = "bad_upper", fixture = fixture, sha256 = _GOOD_DIGEST.upper())
    digest_case(
        name = "bad_sri",
        fixture = fixture,
        sha256 = "sha256-hr6jANZwH7bB/dwzshI1Ix0Qi0SpeT253NSJQPpGpqY=",
    )
    digest_case(
        name = "bad_conditional",
        fixture = fixture,
        sha256 = _GOOD_DIGEST,
        enforce = False,
    )
    digest_case(name = "bad_wrong", fixture = fixture, sha256 = _WRONG_DIGEST)
    digest_case(name = "good", fixture = fixture, sha256 = _GOOD_DIGEST)

digest = module_extension(
    implementation = _digest_impl,
    tag_classes = {"fixture": _fixture},
    doc = "Fetches the digest-mismatch fixture once per digest shape.",
)
