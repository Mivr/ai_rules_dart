"""Parameter objects for `flutter_kernel_compile_action` in `flutter_compile.bzl`.

`flutter_kernel_compile_action()` once took twenty-two parameters: every file
the compile reads, every flag it takes, and the tools it runs with, threaded
one by one from each caller. Values that travel together are one struct here
instead, built by a constructor each call site names. A compile input added
here is a field on one constructor, not a parameter on the action and every
caller of it.

The tools are not here: `flutter_kernel_compile_tools()` in
`flutter_compile.bzl` already resolves that struct for this call, and a second
one would let two call sites resolve the same files differently.
"""

visibility(["//flutter/..."])

def flutter_kernel_sources(
        main,
        srcs,
        package_config,
        entrypoint_uri = None,
        filesystem_roots = [],
        native_assets_manifest = None,
        dart_plugin_registrant_uri = None):
    """What a Flutter kernel compile reads and resolves.

    Args:
      main: The entrypoint `.dart` source File. Always an action input and
        used for the progress message; it is *not* automatically the string
        handed to `frontend_server` — see `entrypoint_uri`.
      srcs: List of all source Files (direct + transitive).
      package_config: The `package_config.json` File.
      entrypoint_uri: The string `frontend_server` compiles as the root
        library, which fixes that library's `importUri` in the kernel. When
        None (the default), the entrypoint is `main`'s stable
        `org-dartlang-app:///` URI, so the compiled `.dill` embeds no sandbox
        path and is byte-identical across output bases, machines and runs.
        Pass an explicit `package:` URI (resolved via `package_config`)
        instead when the entrypoint must key under a package name — this is
        required for hot reload, because `reloadSources` only applies a delta
        when the dev tool's incremental dill keys the library by the *same*
        URI as the running program.
      filesystem_roots: Extra exec-root-relative directories mounted under
        `APP_SCHEME` after the generated-only staging root and the exec root
        (`.`), which the compile always mounts: sources are declared as
        themselves and read in place, while only generated inputs are staged.
        Undeclared files are visible through the exec root under local and
        worker strategies, so hermeticity rests on three layers rather than
        invisibility — the directive guard before the compile, the frontend's
        dependency report verified against the declared-inputs manifest after
        it, and the sandbox (or remote execution) exposing only declared
        inputs. Every entry is
        validated at analysis like `extra_roots` — an absolute, empty, or
        `..`-escaping root fails the build naming the target, the parameter
        and the value — and must be single-line. (`"."` entries are dropped:
        the exec root is already mounted.)
      native_assets_manifest: Optional `native_assets.json` File. Passed to
        the `frontend_server` via `--native-assets`. The frontend server
        embeds the manifest into the resulting kernel so the engine can
        resolve `package:` Native Assets at runtime.
      dart_plugin_registrant_uri: Optional `APP_SCHEME` URI of the generated
        plugin registrant (`app_scheme_location`). When set, the registrant is
        compiled into the kernel as an extra source and advertised via
        `-Dflutter.dart_plugin_registrant=` so the engine invokes
        `_PluginRegistrant.register()` before main() on every root-isolate
        launch (including hot restart). The multi-root scheme keeps the
        library's importUri identical to the define regardless of sandbox
        location — the engine matches them by exact string equality.

    Returns:
      A struct with those fields.
    """
    return struct(
        main = main,
        srcs = srcs,
        package_config = package_config,
        entrypoint_uri = entrypoint_uri,
        filesystem_roots = filesystem_roots,
        native_assets_manifest = native_assets_manifest,
        dart_plugin_registrant_uri = dart_plugin_registrant_uri,
    )

def flutter_kernel_outputs(output, recorded_uses = None):
    """What a Flutter kernel compile produces.

    Args:
      output: The output `.dill` File to produce.
      recorded_uses: Optional declared File the compiler writes the
        `@RecordUse` uses that survive tree-shaking to (`--recorded-uses`),
        the input of package link hooks. Only an AOT compile records; a JIT
        compile writes an empty file.

    Returns:
      A struct with those fields.
    """
    return struct(
        output = output,
        recorded_uses = recorded_uses,
    )

def flutter_kernel_options(
        aot = False,
        defines = [],
        define_flagfiles = [],
        extra_flags = [],
        target = "flutter",
        vm_flags = []):
    """How a Flutter kernel compile runs.

    Args:
      aot: If True, compile for AOT (adds `--aot` `--tfa` flags).
      defines: Environment declarations; each entry becomes a `-D` flag. Each
        entry must be single-line: a line break would split the worker's param
        file into extra argv elements.
      define_flagfiles: Files of environment declarations, each line an
        already-spelled `-Dname=value` argument. Each `File` is appended to the
        compiler argv as `@<path>` after the `defines` flags and declared as an
        action input; its contents are never read at analysis. `kernel_filter`
        and the incremental worker expand the files recursively and refuse a
        line that is not a `-D` argument.
      extra_flags: Additional `frontend_server` flags: only `--incremental`
        and `--track-widget-creation`, which read no file and cannot change
        which files the compile reads. Each entry must be a bare `--flag`
        from that list; any other flag fails the build at analysis — with a
        more specific message for a flag naming a file the compile does not
        declare (`--packages`, `--platform`, `--filesystem-root`, `--source`,
        `--native-assets`, `--recorded-uses`, `--from-dill`, `--import-dill`,
        `--output-dill` and similar) and for any spelling of
        `--[no-]print-incremental-dependencies` (the compile controls the
        dependency report it verifies). Each entry must be single-line, like
        every other argv-bound string.
      target: Frontend server target model (`"flutter"` or `"dartdevc"` for
        web).
      vm_flags: Optional Dart VM flags placed right after `dartaotruntime`,
        before the `frontend_server` snapshot (e.g.
        `--old-gen-heap-size=1073741824`). Only side-effect-free tuning is
        allowed: heap/GC sizing (`--old-gen-heap-size`,
        `--new-gen-semi-initial-size`, `--new-gen-semi-max-size`,
        `--new-gen-garbage-threshold`, `--new-gen-growth-factor`, each
        `--name=<bytes>`) and bare diagnostics (`--enable-asserts`,
        `--verbose-gc`, `--concurrent-mark`, `--concurrent-sweep`). Every
        entry must be a `--flag` from that list (a bare `--` or anything else
        fails the build); flags naming files or side effects (`--packages`,
        `--*-dill`, `--platform`, `--native-assets`, `--timeline-recorder`,
        `--snapshot*` and similar) fail at analysis. The allow-list is
        enforced here, and `kernel_filter` additionally takes every allowed
        read from its manifest — never from the argv — so a smuggled flag
        cannot widen what the compile may read.

    Returns:
      A struct with those fields.
    """
    return struct(
        aot = aot,
        defines = defines,
        define_flagfiles = define_flagfiles,
        extra_flags = extra_flags,
        target = target,
        vm_flags = vm_flags,
    )

def flutter_kernel_dills(from_dill = None, import_dill = None):
    """The precompiled dills a Flutter kernel compile builds on, if any.

    Args:
      from_dill: Optional pre-linked modular `.dill` File passed via
        `--from-dill` to initialize `frontend_server` without re-parsing
        transitive sources. When set, only `main` is staged as a source; the
        rest arrives through the dill.
      import_dill: Optional pre-compiled summary `.dill` File passed via
        `--import-dill=<path>` and added to the action inputs. Libraries
        arriving through it are compiled, declared inputs — not sources — so
        the read-set check and the directive guard accept them while still
        refusing undeclared source reads beside them.

    Returns:
      A struct with those fields.
    """
    return struct(
        from_dill = from_dill,
        import_dill = import_dill,
    )
