"""Maven artifacts whose addresses refuse, built with the rule that fetches the artifacts of a pin.

Nothing here reaches the network. `127.0.0.1:1` and `127.0.0.1:2` have no listener, so a download
from them fails at once, as one from a server that refuses it does; the address that answers is a
`file://` URL of a committed fixture. Bazel's downloader tries the addresses in order, and the sha256
decides what is accepted.
"""

# The rule that fetches one Maven artifact of a pin is private: this is the one place that builds it
# with addresses of its own.
# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private/android_model:extension.bzl", "maven_artifact")

_FIXTURE_SHA256 = "182590ef9d476abe8557b7decd67a9c2d888102f1b38cf32c324a31187ac5586"

def _mirror_impl(mctx):
    answers = "file://" + str(mctx.path(Label("//mirror:ok-1.0.jar")))
    refuses = "http://127.0.0.1:1/maven2/fixture/ok/1.0/ok-1.0.jar"
    refuses_too = "http://127.0.0.1:2/maven2/fixture/ok/1.0/ok-1.0.jar"

    # The first address refuses, the second has the file.
    maven_artifact(
        name = "second_address_answers",
        urls = [refuses, answers],
        sha256 = _FIXTURE_SHA256,
        coordinate = "fixture:ok:1.0",
        file = "ok-1.0.jar",
    )

    # Every address refuses.
    maven_artifact(
        name = "every_address_refuses",
        urls = [refuses, refuses_too],
        sha256 = "1" * 64,
        coordinate = "fixture:never:1.0",
        file = "never-1.0.jar",
    )

    # The only address answers with other bytes than the pin has.
    maven_artifact(
        name = "other_bytes",
        urls = [refuses, answers],
        sha256 = "0" * 64,
        coordinate = "fixture:other:1.0",
        file = "other-1.0.jar",
    )
    return mctx.extension_metadata(reproducible = True)

mirror = module_extension(
    doc = "Maven artifacts of a pin, one per way an address can fail.",
    implementation = _mirror_impl,
)
