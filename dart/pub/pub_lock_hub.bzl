"""Hub repository rule for pubspec.lock packages.

Thin public facade: the implementation lives in `//dart/pub/private:pub_lock_hub.bzl`."""

load(
    "//dart/pub/private:pub_lock_hub.bzl",
    _pub_lock_hub = "pub_lock_hub",
    _pub_lock_hub_content = "pub_lock_hub_content",
)

visibility("public")

pub_lock_hub_content = _pub_lock_hub_content
pub_lock_hub = _pub_lock_hub
