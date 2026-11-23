---
status: accepted
unenforceable: "Checksums are checked in download.bzl; hermetic.missing_obligations counts rollout obligations."
---

# 0006. The Flutter SDK is a pinned download; no host SDK is searched for

## Decision

The Flutter SDK for a toolchain is a versioned download. Its tag, engine
revision and digests are listed in `flutter/private/versions.bzl`
(`FLUTTER_VERSIONS` at `:48`, `ARTIFACT_CHECKSUMS` at `:282`). Every fetch goes
through `pinned_download` or `pinned_download_and_extract`
(`flutter/private/download.bzl:50-92`), which refuse a digest that is not 64
lowercase hex characters. No `.bzl` file under `flutter/` reads `PATH` or
`FLUTTER_ROOT` from the environment.

One exception is allowed. A root module may set `local_path` to a pre-extracted
SDK on disk. The repository rules read that tree and never download
(`flutter/private/local_sdk.bzl:1-16`). A non-root module may not set it
(`flutter/extensions.bzl:295-296`).

## Alternatives ruled out

- **Discovering a host SDK from `PATH` or `FLUTTER_ROOT`.** A build would depend
  on whatever is installed, and nothing in the build would pin it.
- **Downloading a moving channel.** The digest would not be fixed.
- **`local_path` in a dependency module.** A library would decide which SDK
  every consumer builds with. The root module decides instead.

## Consequence

A new Flutter release is added to `FLUTTER_VERSIONS` and `ARTIFACT_CHECKSUMS`
with its digests. A build that uses `local_path` makes that choice in its root
`MODULE.bazel`. The rule set's own Maven artifacts are not checksum-locked; ADR
0007 records that gap.
