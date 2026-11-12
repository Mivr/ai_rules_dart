---
status: accepted
unenforceable: "No registered gate metric checks which compile modes exist or that kernel builds are modular; the dart_binary and kernel unit tests pin them"
---

# 0005. Compilation modes, modular kernels and the reproducible two-step VM compile

Source: `docs/ARCHITECTURE.md`, Design Decision 3 and Dart Compilation Model;
`ai-docs/performance/decisions.md` ("Modular at library granularity",
"Reproducibility is a hard requirement").

## Context

Dart compiles one program several ways: a native executable, an AOT or app-JIT
snapshot, a kernel, JavaScript and WebAssembly. A test or kernel-mode binary
recompiling its whole closure on every edit is slow, and a compiled program
embeds library URIs, so compiling from a sandbox path makes the output depend
on where it was built.

## Decision

- `dart_binary` compiles with `dart compile exe` by default, or as
  `aot-snapshot`, `kernel` or `jit-snapshot`; `dart_js_binary` and
  `dart_wasm_binary` compile for the web.
- `dart_test` and `dart_binary(compile_mode = "kernel")` compile modularly by
  default (`//dart:modular_kernel = True`, `dart_binary.modular_kernel =
True`): each library's `.kmod`/`.koutline` is built once and only the
  reachable modules are linked. They fall back to a single `gen_kernel`
  action when `modular_kernel = False` or when target-specific flags, defines
  or code assets apply. Modules are compiled against the JIT platform, so
  `exe` and `aot-snapshot` never use them: they take the source path whatever
  `modular_kernel` says. At SDK 3.13.5 a module compile has no AOT target, so
  conditional imports and `dart.library.*` constants would keep the JIT
  answers. Revisit at the next SDK pin.
- The other VM modes compile in two actions: the front end (`gen_kernel`)
  produces a kernel, and `dart compile` turns it into the requested output.
  The front end reads sources through a file system rooted at
  `ctx.bin_dir.path` and the exec root (`--filesystem-scheme
org-dartlang-root`), so no output names the sandbox or output base.

## Alternatives ruled out

- Whole-program compilation for every test, which recompiles the closure on
  every edit.
- Modules at package granularity with drop-and-retry of failing files,
  measured slower and larger in `ai-docs/performance/decisions.md`.
- Passing `dart compile` a source path, which names the entrypoint by its
  absolute `file:///` path and makes the output depend on the build directory.

## Consequences

- A front-end define or flag must reach the front-end action, not the
  `dart compile` step that consumes its kernel.
- The front end passes what `dart compile` would: the product or JIT platform
  dill and the matching `dart.vm.product` (`true` for `kernel`, `exe` and
  `aot-snapshot`; `false` for `jit-snapshot` and for `dart_test`, which runs on
  the non-product VM as `dart test` does).
- Builds must stay reproducible across sandboxes and output bases; a change
  that lets a path leak into compiled output breaks that requirement.
