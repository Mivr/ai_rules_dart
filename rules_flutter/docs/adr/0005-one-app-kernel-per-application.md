---
status: accepted
unenforceable: "No registered metric counts application kernel compile call sites."
---

# 0005. One application kernel; packaging stays in the platform rules

## Decision

Every application kernel comes from one function, `flutter_compile_kernel`
(`flutter/private/common.bzl:979`). `flutter_application`
(`flutter/private/flutter_application.bzl:555`) calls it, and so do the
standalone `flutter_kernel_target` and `flutter_aot_target`. The application
rule returns its outputs as `FlutterApplicationInfo`
(`flutter/providers.bzl:345`). Each platform rule packages those outputs through
an `application` attribute. Platform rules own the host bundle layout, the
manifests and the runner (`docs/ARCHITECTURE.md` section 4).

Web is the exception. dart2wasm and dart2js take Dart source, not a kernel
(`flutter/private/flutter_web_compile.bzl:1-8`), so `flutter_web_bundle` does
not read `FlutterApplicationInfo`.

## Alternatives ruled out

- **Each platform compiling its own kernel.** The kernel would differ by host,
  and every platform would repeat the same gates.
- **Packaging inside the application rule.** One application's kernel would then
  carry each host's bundle layout. The platform rules keep each host's manifests
  and runner in one file each.

## Consequence

A new kernel input goes into the inputs of `flutter_compile_kernel`. A new
host-specific concern goes into the platform rule. `flutter_library` compiles
nothing (`flutter/private/flutter_library.bzl:720`).
