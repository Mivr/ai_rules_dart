#!/usr/bin/env python3
"""Layered Flutter monorepo workspace generator for the iOS perf bench.

Generates a deterministic monorepo-shaped Flutter workspace sized by total
Dart lines of code (``target_loc``), mirroring the manager referee's
``flutter-monorepo`` generator knobs (``target_loc``, ``layers`` default 8,
``fanout`` default 4, ``files_per_package`` default 20, ``seed``):

- Packages spread over ``layers`` (layer 0 holds core/util packages with high
  fan-in, upper layers hold feature packages). Each package above layer 0
  depends on ``fanout`` packages from strictly lower layers (seeded PRNG), so
  the graph is acyclic by construction.
- Every library file is 100-150 lines of realistic Dart (documented enum,
  generic class with chained methods, extension, a widget, imports from the
  own package and from dependencies, ``part`` files in every eighth library).
  The same inputs give a byte-identical tree.
- One ``flutter_library`` per package plus an ``app/`` package with a
  ``flutter_application`` and the Tier-1 iOS, Android and Web app targets
  (``flutter_ios_app`` + an explicit ``flutter_ios_framework_gen``
  App.framework target + simulator build test, ``flutter_android_app`` and
  ``flutter_web_app``). Unlike the referee generator there is no
  ``flutter_test`` target unless ``--test-ratio`` asks for them.
- Reachability (generator v2): each package entry calls its direct
  dependencies' entries and every own file's functions (including the
  value functions the bench edits) and constructs every own file's
  widget; ``main`` calls every top-layer entry. Cross-package calls are
  guarded by a probe main reads from a runtime source the compiler
  cannot fold that is zero at run time, so AOT tree-shaking keeps the
  whole program without running it.
- An edit manifest (``bench-edit-manifest.json``) records the file the
  ``body_edit``/``api_edit`` scenarios edit, and a stats file
  (``bench-workspace-stats.json``) records the workspace statistics.

Only the Python 3 standard library is used. Generation streams files to disk
(one file in memory at a time) so large workspaces stay fast.

Scaffolding (MODULE.bazel, pub files, .bazelrc, the ``ios/Runner/``
scaffold the Tier-1 ``flutter_ios_app`` discovers and the
``android/app/src/main/`` scaffold ``flutter_android_app`` discovers) is
derived from the ``e2e/hello_world`` fixture of the ``--rules-flutter``
checkout, so hermetic pins can never drift from what ``rules_flutter``
main verifies. The Android scaffold itself is written by the generator so
it exists with or without the fixture.

The generated workspace models a consumer's iOS workspace, not this repo's
own checkout: its ``.bazelrc`` carries no ``--lockfile_mode`` flag at all
(Bazel's default applies; any such line the fixture carries is dropped) and
its ``MODULE.bazel`` carries none of the fixture's dev-only dependencies
(top-level ``bazel_dep``, ``register_toolchains`` and
``register_execution_platforms`` calls marked ``dev_dependency = True``
are removed with one following blank line; any other dev-marked call fails
generation, as does any leftover reference to a dropped module).
"""

import argparse
import json
import os
import re
import shutil
import sys
from typing import NamedTuple, Optional

from gen_edits import (
    EDIT_MANIFEST_REL_PATH,
    apply_api_edit,
    apply_app_edit,
    apply_body_edit,
)
from gen_files import write_plain
from gen_plugins import add_plugins
from gen_scale_args import resolve_scale_args
from gen_platform_apps import (
    render_app_main,
    write_android_scaffolding,
    write_app_build,
)
from gen_pub import copy_pub_and_lock_files

MASK64 = (1 << 64) - 1

STATS_REL_PATH = "bench-workspace-stats.json"

DEFAULT_LAYERS = 8
DEFAULT_FANOUT = 4
DEFAULT_FILES_PER_PACKAGE = 20
DEFAULT_TEST_RATIO = 0.0
DEFAULT_EDIT_LAYER = 0
LOC_TOLERANCE = 0.05


# --------------------------------------------------------------------------
# Deterministic PRNG (splitmix64, same stream shape as the referee generator).


class SplitMix64:
    """Small deterministic PRNG. Same seed yields the same stream everywhere."""

    def __init__(self, state):
        self.state = state & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def below(self, n):
        if n <= 0:
            raise ValueError("SplitMix64.below requires n >= 1")
        return self.next() % n


def file_rng(seed, package, file):
    """Per-file PRNG stream derived from the workspace seed (deterministic)."""
    return SplitMix64(seed + package * 1000003 + file * 1000033 + 0xA5A5A5A5)


# --------------------------------------------------------------------------
# Package DAG.


def repair_orphans(deps, layer_vecs, layer_count, seed):
    """Attaches every unreachable package to a higher-layer dependent.

    Generator v2 needs every package below the top layer reachable from
    main through the DAG (each entry calls its dependencies' entries, main
    calls the top layer). The seeded fanout above can leave a package with
    no dependents; such an orphan gains one edge from a package in a
    strictly higher layer, drawn from a fresh seeded stream so the main
    fanout stream is undisturbed. Top-layer packages need no repair: main
    calls them all directly. Edges stay sorted, unique, and downward, so
    the graph remains an acyclic layered DAG.
    """
    if layer_count < 2:
        return
    fan_in = [0] * len(deps)
    for edges in deps:
        for d in edges:
            fan_in[d] += 1
    rng = SplitMix64((seed ^ 0x0B971E) & MASK64)
    for layer in range(layer_count - 1):
        higher = [q for upper in layer_vecs[layer + 1:] for q in upper]
        for pkg in layer_vecs[layer]:
            if fan_in[pkg] > 0:
                continue
            dependent = higher[rng.below(len(higher))]
            deps[dependent].append(pkg)
            deps[dependent].sort()
            fan_in[pkg] += 1


def build_dag(n_packages, layers, fanout, seed):
    """Layered DAG: deps[p] holds the sorted direct deps of package p.

    Packages spread over min(layers, n_packages) layers (extras go to the top
    layers); each package above layer 0 depends on min(fanout, lower_count)
    distinct packages from strictly lower layers. A repair pass then gives
    every package below the top layer at least one dependent (generator v2
    reachability), adding the minimum edges to packages that fanout left
    orphaned.
    """
    if n_packages < 1:
        raise ValueError("build_dag requires n_packages >= 1")
    layer_count = max(1, min(layers, n_packages))
    base = n_packages // layer_count
    rem = n_packages % layer_count

    layer_vecs = []
    layer_of = [0] * n_packages
    next_pkg = 0
    for layer in range(layer_count):
        size = base + (1 if layer >= layer_count - rem else 0)
        members = []
        for _ in range(size):
            layer_of[next_pkg] = layer
            members.append(next_pkg)
            next_pkg += 1
        layer_vecs.append(members)

    rng = SplitMix64((seed ^ 0x51F15EED) & MASK64)
    deps = [[] for _ in range(n_packages)]
    for layer in range(1, layer_count):
        # Candidate pool: every package in a strictly lower layer. Built once
        # per layer; the per-package partial Fisher-Yates mutates it in place
        # through the shared seeded stream.
        candidates = [p for lower in layer_vecs[:layer] for p in lower]
        for pkg in layer_vecs[layer]:
            want = min(fanout, len(candidates))
            for j in range(want):
                k = j + rng.below(len(candidates) - j)
                candidates[j], candidates[k] = candidates[k], candidates[j]
            deps[pkg] = sorted(candidates[:want])

    repair_orphans(deps, layer_vecs, layer_count, seed)

    return {"deps": deps, "layer_of": layer_of, "layers": layer_vecs}


def fan_in_counts(dag):
    fan_in = [0] * len(dag["deps"])
    for deps in dag["deps"]:
        for d in deps:
            fan_in[d] += 1
    return fan_in


def fan_stats(values):
    if not values:
        return {"max": 0, "mean": 0.0, "min": 0}
    return {
        "max": max(values),
        "mean": sum(values) / len(values),
        "min": min(values),
    }


def pick_test_packages(n_packages, test_ratio, seed):
    """Seeded shuffle picking round(n * test_ratio) packages for flutter_test."""
    selected = [False] * n_packages
    k = min(int(round(n_packages * test_ratio)), n_packages)
    if k == 0:
        return selected
    rng = SplitMix64((seed ^ 0x7E57) & MASK64)
    order = list(range(n_packages))
    for j in range(k):
        swap = j + rng.below(n_packages - j)
        order[j], order[swap] = order[swap], order[j]
        selected[order[j]] = True
    return selected


# --------------------------------------------------------------------------
# File sizing.


def method_count_range(skeleton_lines):
    """Admissible method-count range keeping the file total in [100, 150]."""
    under = max(0, 100 - skeleton_lines)
    min_m = max(1, (under + 7) // 8)
    over = max(0, 150 - skeleton_lines)
    max_m = max(min_m, over // 8)
    return (min_m, max_m)


def method_count_for(rng, skeleton_lines):
    min_m, max_m = method_count_range(skeleton_lines)
    if max_m <= min_m:
        return min_m
    return min_m + rng.below(max_m - min_m + 1)


def pad_file(files_per_package, file):
    width = max(1, len(str(files_per_package - 1)))
    return str(file).zfill(width)


def lib_skeleton_lines(has_sibling, dep_count, has_part, odd_file):
    """Exact non-method line count of render_lib_file for the given shape.

    Must stay in lockstep with the template; unit tests cross-check it.
    """
    # Base: material import (1) + blank (1) + file doc (1) + enum
    # (header + 4 documented values + close = 10) + blank (1) + extension
    # (16) + blank (1) + class (19) + close (1) + blank (1) + stateless
    # widget (13) + blank (1) + value function (7) + helper (6).
    lines = 79
    if has_sibling:
        lines += 1  # sibling package: import
        lines += 1  # sibling call in fn
    if dep_count > 0:
        lines += dep_count  # dep imports
        lines += 2 * dep_count + 1  # per-dep doc + typedef + blank
    if has_part:
        lines += 1  # part directive
    if odd_file:
        lines += 21  # stateful widget block is 21 lines larger
    return lines


# --------------------------------------------------------------------------
# Dart rendering.


class _LibSpec(NamedTuple):
    """Shape of one generated library file: identity plus dependencies."""

    package: int
    file: int
    files_per_package: int
    deps: tuple
    method_count: int

    @property
    def has_sibling(self):
        return self.file > 0

    @property
    def has_part(self):
        return self.file % 8 == 0

    @property
    def odd_file(self):
        return self.file % 2 == 1

    @property
    def factor(self):
        return self.file + 2

    @property
    def pad(self):
        return pad_file(self.files_per_package, self.file)


def _lib_import_lines(spec):
    """Import block plus the dependency typedefs of one library file."""
    package = spec.package
    file = spec.file
    imports = ["import 'package:flutter/material.dart';"]
    for d in spec.deps:
        imports.append("import 'package:pkg%d/pkg%d.dart';" % (d, d))
    if spec.has_sibling:
        imports.append(
            "import 'package:pkg%d/src/f%s.dart';"
            % (package, pad_file(spec.files_per_package, file - 1))
        )
    imports.sort()

    out = []
    out.extend(imports)
    out.append("")
    if spec.has_part:
        out.append("part 'f%s.part.dart';" % spec.pad)
    if spec.deps:
        dep_lines = sorted(
            "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in spec.deps
        )
        for line in dep_lines:
            d = int(line.split("pkg")[1].split("/")[0])
            out.append("/// Dependency API of package pkg%d used here." % d)
            out.append("typedef D%dx%dA%d = C%dx0<int>;" % (package, file, d, d))
        out.append("")
    return out


def _lib_class_lines(spec):
    """Value-holder class header, fields and small members."""
    package, file = spec.package, spec.file
    out = []
    out.append("/// Boxed value %d of package %d." % (file, package))
    if spec.has_part:
        out.append("class C%dx%d<T> with M%dx%d {" % (package, file, package, file))
    else:
        out.append("class C%dx%d<T> {" % (package, file))
    out.append("  /// Creates the value holder.")
    out.append("  C%dx%d(this.value, [this.tag, this.payload]);" % (package, file))
    out.append("")
    out.append("  /// The value.")
    out.append("  final int value;")
    out.append("")
    out.append("  /// The tag.")
    out.append("  final E%dx%d? tag;" % (package, file))
    out.append("")
    out.append("  /// The extra payload.")
    out.append("  final T? payload;")
    out.append("")
    out.append("  /// Describe this holder.")
    out.append("  String describe() => 'C%dx%d($value)';" % (package, file))
    out.append("")
    out.append("  /// Pick an item.")
    out.append("  T? pick(List<T> items) => items.isEmpty ? null : items.first;")
    return out


def _lib_method_lines(spec):
    """The chained m0.. methods of the value holder."""
    out = []
    for m in range(spec.method_count):
        tail = " + m%d(x)" % (m + 1) if m + 1 < spec.method_count else ""
        out.append("  /// Method %d of C%dx%d." % (m, spec.package, spec.file))
        out.append("  int m%d(int x) {" % m)
        out.append("    var total = x + value;")
        out.append("    for (var i = 0; i < x; i++) {")
        out.append("      total += i * %d;" % spec.factor)
        out.append("    }")
        out.append("    return total%s;" % tail)
        out.append("  }")
    return out


def render_lib_file(package, file, files_per_package, deps, method_count):
    """One library file: package: imports only, enum, extension, generic class.

    Layout (100-150 lines): a documented enum, a generic class with
    method_count chained methods, one widget (stateless on even files,
    stateful on odd files), a public value function and a local helper. The
    class carries the api_edit marker ("  /// The value.") and the value
    function the body_edit marker ("  var total = 1;").
    """
    spec = _LibSpec(package, file, files_per_package, tuple(deps),
                    method_count)

    out = []
    out.extend(_lib_import_lines(spec))
    out.append("/// File %d of package %d." % (file, package))
    out.append("enum E%dx%d {" % (package, file))
    for value, kind in [
        ("alpha", "First"),
        ("beta", "Second"),
        ("gamma", "Third"),
        ("delta", "Fourth"),
    ]:
        out.append("  /// %s kind." % kind)
        out.append("  %s," % value)
    out.append("}")
    out.append("")
    out.append("/// Extension on [E%dx%d]." % (package, file))
    out.append("extension E%dx%dExt on E%dx%d {" % (package, file, package, file))
    out.append("  /// Describe this value.")
    out.append("  String describe() {")
    out.append("    switch (this) {")
    for value in ["alpha", "beta", "gamma", "delta"]:
        out.append("      case E%dx%d.%s:" % (package, file, value))
        out.append("        return 'p%df%d:%s';" % (package, file, value))
    out.append("    }")
    out.append("  }")
    out.append("}")
    out.append("")
    out.extend(_lib_class_lines(spec))
    out.extend(_lib_method_lines(spec))
    out.append("}")
    out.append("")
    if spec.odd_file:
        out.extend(render_stateful_widget(package, file))
    else:
        out.append("/// Widget %d of package %d." % (file, package))
        out.append("class W%dx%d extends StatelessWidget {" % (package, file))
        out.append("  /// Creates the widget.")
        out.append("  const W%dx%d({super.key, this.value = 0});" % (package, file))
        out.append("")
        out.append("  /// The number shown.")
        out.append("  final int value;")
        out.append("")
        out.append("  @override")
        out.append("  Widget build(BuildContext context) {")
        out.append(
            "    return Text('pkg%d f%d: $value ${value%dx%d()}');"
            % (package, file, package, file)
        )
        out.append("  }")
        out.append("}")
    out.append("")
    out.append("/// Plain value of file %d of package %d." % (file, package))
    out.append("int value%dx%d() {" % (package, file))
    out.append("  var total = 1;")
    out.append("  total += fn%dx%d(%d);" % (package, file, file + 1))
    out.append("  return total % 1000003;")
    out.append("}")
    out.append("")
    out.append("/// Local helper of file %d of package %d." % (file, package))
    out.append("int fn%dx%d(int x) {" % (package, file))
    out.append("  var total = x + 1;")
    out.append(
        "  total += C%dx%d<int>(total).m0(total %% 7);" % (package, file)
    )
    if spec.has_sibling:
        out.append("  total += fn%dx%d(x);" % (package, file - 1))
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_stateful_widget(package, file):
    """Stateful widget block of a library file (odd files only)."""
    p, f = package, file
    return [
        "/// Stateful widget %d of package %d." % (f, p),
        "class S%dx%d extends StatefulWidget {" % (p, f),
        "  /// Creates the widget.",
        "  const S%dx%d({super.key, this.value = 0});" % (p, f),
        "",
        "  /// The number shown.",
        "  final int value;",
        "",
        "  @override",
        "  State<S%dx%d> createState() => _S%dx%dState();" % (p, f, p, f),
        "}",
        "",
        "/// State of [S%dx%d]." % (p, f),
        "class _S%dx%dState extends State<S%dx%d> {" % (p, f, p, f),
        "  int _counter = 0;",
        "",
        "  /// Increments the counter.",
        "  void incrementCounter() {",
        "    setState(() {",
        "      _counter++;",
        "    });",
        "  }",
        "",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return Column(",
        "      mainAxisSize: MainAxisSize.min,",
        "      children: [",
        "        Text('pkg%d f%d: ${widget.value} ${value%dx%d()} $_counter'),"
        % (p, f, p, f),
        "        TextButton(onPressed: incrementCounter, child: const Text('+')),",
        "      ],",
        "    );",
        "  }",
        "}",
    ]


def render_part_file(package, file, files_per_package):
    pad = pad_file(files_per_package, file)
    return "\n".join(
        [
            "part of 'f%s.dart';" % pad,
            "",
            "/// Mixin for [C%dx%d]." % (package, file),
            "mixin M%dx%d {" % (package, file),
            "  /// Adjust a value.",
            "  int adjust(int x) => x + 1;",
            "}",
        ]
    ) + "\n"


def render_entrypoint(package, files_per_package, deps):
    """Package entry point: own files' functions plus dependencies' entries.

    Calls every own file's helper and value functions (including the value
    functions the bench edits) and constructs every own file's widget, all
    unconditionally, so any body_edit in the package changes the AOT
    program. Cross-package calls to the direct dependencies' entries are
    guarded by [probe]: main passes a value from a runtime source the
    compiler cannot fold that is zero at run time, so the whole transitive
    closure stays reachable for AOT tree-shaking without running.
    """
    imports = [
        "import 'package:pkg%d/src/f%s.dart';"
        % (package, pad_file(files_per_package, f))
        for f in range(files_per_package)
    ]
    imports.extend(
        "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in deps
    )
    imports.sort()
    out = ["/// Public API of package pkg%d." % package]
    out.extend(imports)
    for f in range(files_per_package):
        out.append("export 'src/f%s.dart';" % pad_file(files_per_package, f))
    out.append("")
    out.append("/// Entry point of package %d." % package)
    out.append("///")
    out.append("/// Calls every own file's functions and — guarded by [probe]")
    out.append("/// — the direct dependencies' entries.")
    out.append("int entry%d(int x, int probe) {" % package)
    out.append("  var total = x;")
    for f in range(files_per_package):
        out.append("  total += fn%dx%d(x);" % (package, f))
    for f in range(files_per_package):
        out.append("  total += value%dx%d();" % (package, f))
    for f in range(files_per_package):
        widget = "W" if f % 2 == 0 else "S"
        out.append(
            "  total += const %s%dx%d(value: 1).value;" % (widget, package, f)
        )
    if deps:
        out.append("  if (probe != 0) {")
        for d in deps:
            out.append("    total += entry%d(x, probe);" % d)
        out.append("  }")
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_test_file(package):
    return "\n".join(
        [
            "import 'package:flutter/material.dart';",
            "import 'package:flutter_test/flutter_test.dart';",
            "import 'package:pkg%d/pkg%d.dart';" % (package, package),
            "",
            "void main() {",
            "  testWidgets('W%dx0 renders in a MaterialApp', (tester) async {"
            % package,
            "    await tester.pumpWidget(",
            "      const MaterialApp(home: Scaffold(body: W%dx0(value: 1))),"
            % package,
            "    );",
            "    expect(find.byType(W%dx0), findsOneWidget);" % package,
            "    expect(value%dx0(), greaterThan(0));" % package,
            "  });",
            "}",
        ]
    ) + "\n"


# --------------------------------------------------------------------------
# Plan, tuning, rendering to disk.


class Options:
    # Exact package count (`--packages`); None derives it from target_loc.
    packages = None
    # `--track-widget-creation`: the generated application tracks widgets.
    track_widget_creation = False

    def __init__(
        self,
        target_loc,
        layers=DEFAULT_LAYERS,
        fanout=DEFAULT_FANOUT,
        files_per_package=DEFAULT_FILES_PER_PACKAGE,
        seed=1,
        test_ratio=DEFAULT_TEST_RATIO,
        edit_layer=DEFAULT_EDIT_LAYER,
    ):
        if target_loc < 1:
            raise ValueError("target_loc must be >= 1")
        if layers < 1:
            raise ValueError("layers must be >= 1")
        if files_per_package < 1:
            raise ValueError("files_per_package must be >= 1")
        if not 0.0 <= test_ratio <= 1.0:
            raise ValueError("test_ratio must be in [0.0, 1.0]")
        if edit_layer >= layers:
            raise ValueError("edit_layer must be < layers")
        self.target_loc = target_loc
        self.layers = layers
        self.fanout = fanout
        self.files_per_package = files_per_package
        self.seed = seed
        self.test_ratio = test_ratio
        self.edit_layer = edit_layer


class MonorepoPlan:
    def __init__(self, opts, n_packages):
        self.dag = build_dag(n_packages, opts.layers, opts.fanout, opts.seed)
        self.track_widget_creation = opts.track_widget_creation
        self.has_test = pick_test_packages(
            n_packages, opts.test_ratio, opts.seed
        )
        self.method_counts = []
        for p in range(n_packages):
            counts = []
            for f in range(opts.files_per_package):
                rng = file_rng(opts.seed, p, f)
                skeleton = lib_skeleton_lines(
                    f > 0, len(self.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                counts.append(method_count_for(rng, skeleton))
            self.method_counts.append(counts)

        edit_layer = min(opts.edit_layer, len(self.dag["layers"]) - 1)
        fan_in = fan_in_counts(self.dag)
        edit_pkg = self.dag["layers"][edit_layer][0]
        for pkg in self.dag["layers"][edit_layer]:
            if fan_in[pkg] > fan_in[edit_pkg]:
                edit_pkg = pkg
        self.edit_rel_path = "packages/pkg%d/lib/src/f%s.dart" % (
            edit_pkg,
            pad_file(opts.files_per_package, 0),
        )

    def top_layer(self):
        return self.dag["layers"][-1]


def count_lines(text):
    return text.count("\n")


def render_all_dart(opts, plan, render_one):
    """Renders every Dart file, passing (rel_path, content) to render_one."""
    lines = 0
    n = len(plan.dag["deps"])
    for p in range(n):
        for f in range(opts.files_per_package):
            content = render_lib_file(
                p, f, opts.files_per_package,
                plan.dag["deps"][p], plan.method_counts[p][f],
            )
            lines += count_lines(content)
            rel = "packages/pkg%d/lib/src/f%s.dart" % (
                p, pad_file(opts.files_per_package, f))
            render_one(rel, content)
            if f % 8 == 0:
                content = render_part_file(p, f, opts.files_per_package)
                lines += count_lines(content)
                rel = "packages/pkg%d/lib/src/f%s.part.dart" % (
                    p, pad_file(opts.files_per_package, f))
                render_one(rel, content)
        content = render_entrypoint(
            p, opts.files_per_package, plan.dag["deps"][p])
        lines += count_lines(content)
        render_one("packages/pkg%d/lib/pkg%d.dart" % (p, p), content)
        if plan.has_test[p]:
            content = render_test_file(p)
            lines += count_lines(content)
            render_one("packages/pkg%d/test/pkg%d_test.dart" % (p, p), content)
    content = render_app_main(plan.top_layer())
    lines += count_lines(content)
    render_one("app/lib/main.dart", content)
    return lines


def plan_total_lines(opts, plan):
    total = [0]

    def count_only(rel, content):
        total[0] += count_lines(content)

    render_all_dart(opts, plan, count_only)
    return total[0]


def tune_plan_to_target(opts, plan):
    """Adjusts method counts one method at a time toward target_loc."""
    total = plan_total_lines(opts, plan)
    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    n = len(plan.dag["deps"])
    for _ in range(16):
        if lo <= total <= hi:
            break
        moved = False
        for p in range(n):
            for f in range(opts.files_per_package):
                if lo <= total <= hi:
                    break
                skeleton = lib_skeleton_lines(
                    f > 0, len(plan.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                min_m, max_m = method_count_range(skeleton)
                current = plan.method_counts[p][f]
                if total < opts.target_loc and current < max_m:
                    plan.method_counts[p][f] = current + 1
                    total += 8
                    moved = True
                elif total > opts.target_loc and current > min_m:
                    plan.method_counts[p][f] = current - 1
                    total -= 8
                    moved = True
        if not moved:
            break
    return total


def select_package_count(opts):
    if opts.packages is not None:
        plan = MonorepoPlan(opts, opts.packages)
        return (plan, tune_plan_to_target(opts, plan))
    n = max(1, opts.target_loc // (opts.files_per_package * 125))
    seen = set()
    for _ in range(10):
        if n in seen:
            break
        seen.add(n)
        plan = MonorepoPlan(opts, n)
        total = tune_plan_to_target(opts, plan)
        lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
        hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
        if lo <= total <= hi:
            return (plan, total)
        per_pkg = max(total, 1) // max(n, 1)
        nxt = min(1000000, max(1, opts.target_loc // max(per_pkg, 1)))
        if nxt == n:
            n = n + 1 if total < opts.target_loc else max(1, n - 1)
        else:
            n = nxt
    raise ValueError(
        "flutter-monorepo could not reach target_loc %d within +/-%d%% "
        "(last tried %d packages)"
        % (opts.target_loc, int(LOC_TOLERANCE * 100), n)
    )


# --------------------------------------------------------------------------
# Scaffolding.


def read_bazel_version_or(rules_flutter_dir, fallback="9.3.0"):
    try:
        with open(os.path.join(rules_flutter_dir, ".bazelversion"),
                  encoding="utf-8") as fh:
            trimmed = fh.read().strip()
            if trimmed:
                return trimmed
    except OSError:
        pass
    return fallback


# Module names the trees may carry (BCR rename): rules_dart is published
# as ai_rules_dart (repo_name "rules_dart") and rules_flutter as
# ai_rules_flutter (repo_name "rules_flutter"). Labels keep the repo
# names (@rules_dart, @rules_flutter); overrides use module names.
FLUTTER_MODULE_NAMES = ("rules_flutter", "ai_rules_flutter")
DART_MODULE_NAMES = ("rules_dart", "ai_rules_dart")
HELLO_MODULE_NAME = "rules_flutter_hello_world"
BENCH_MODULE_NAME = "bench_monorepo"
OVERRIDE_KINDS = ("git_override", "archive_override",
                  "single_version_override", "local_path_override")


def _strip_comments(text):
    """MODULE.bazel text with # comments removed, strings intact."""
    out = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            out.append(ch)
        elif ch == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def _call_spans(text, kind):
    """(start, end) spans of each top-level kind(...) call in text."""
    spans = []
    for match in re.finditer(r"%s\(" % kind, text):
        depth = 0
        for i in range(match.end() - 1, len(text)):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    spans.append((match.start(), i + 1))
                    break
    return spans


def _call_bodies(text, kind):
    """The argument bodies of each top-level kind(...) call in text."""
    bodies = []
    for (start, end) in _call_spans(text, kind):
        open_paren = text.index("(", start)
        bodies.append(text[open_paren + 1:end - 1])
    return bodies


def _string_attrs(body):
    """{attribute: value} for the name = "value" attributes in a body."""
    return dict(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]*)\"",
                           body))


def extract_pin_block(module_bazel_text, module_name):
    """The git/archive/single_version override block for module_name.

    Matches the module_name attribute inside the call, so neither
    "ai_rules_dart" nor a repo_name fools the comparison. Returns the
    block's original text, or None when the module has no pin block.
    """
    for kind in OVERRIDE_KINDS:
        for (start, end) in _call_spans(module_bazel_text, kind):
            attrs = _string_attrs(module_bazel_text[start:end])
            if attrs.get("module_name") == module_name:
                if module_bazel_text[end:end + 1] == "\n":
                    end += 1
                return module_bazel_text[start:end]
    return None


def extract_rules_dart_git_override(module_bazel_text):
    return extract_pin_block(module_bazel_text, "rules_dart")


def parse_module_name(module_bazel_text):
    """The module(name = ...) of a MODULE.bazel, or None when absent."""
    match = re.search(r'module\(\s*name\s*=\s*"([^"]+)"',
                      module_bazel_text)
    return match.group(1) if match else None


def read_tree_modules(rules_flutter_dir):
    """(flutter_name, dart_name, dart_pin) the rules_flutter tree declares.

    The flutter name comes from the tree MODULE.bazel's module(name =
    ...); the dart name is the name attribute of the bazel_dep call whose
    repo is rules_dart (repo_name when present, else the name itself),
    so a repo_name = "rules_dart" is never mistaken for the module name;
    the pin is that module's override block in the same file. Without a
    tree MODULE.bazel (unit tests) the names stay None and the caller
    falls back to the fixture's names; every name written otherwise
    comes from the trees, never from a constant.
    """
    try:
        with open(os.path.join(rules_flutter_dir, "MODULE.bazel"),
                  encoding="utf-8") as fh:
            root = _strip_comments(fh.read())
    except OSError:
        return (None, None, None)
    dart_name = None
    for body in _call_bodies(root, "bazel_dep"):
        attrs = _string_attrs(body)
        if attrs.get("repo_name", attrs.get("name")) == "rules_dart":
            dart_name = attrs.get("name")
            break
    pin = extract_pin_block(root, dart_name) if dart_name else None
    return (parse_module_name(root), dart_name,
            _absolute_path_pin(pin, rules_flutter_dir))


def _absolute_path_pin(pin, base_dir):
    """pin with a relative local_path_override path resolved against base_dir.

    The tree pins rules_dart by a path relative to its own root (the
    sibling directory in the merged repository); the generated workspace
    lives elsewhere, so it gets the absolute path. Any other pin is
    returned unchanged.
    """
    if pin is None or not pin.startswith("local_path_override"):
        return pin
    attrs = _string_attrs(pin)
    path = attrs.get("path")
    if path is None or os.path.isabs(path):
        return pin
    return local_path_override(
        attrs["module_name"],
        os.path.normpath(os.path.join(os.path.abspath(base_dir), path)))


def read_fixture_modules(fixture_text):
    """(flutter_name, dart_name, dart_pin) the hello_world fixture declares.

    The flutter name is the module_name of the local_path_override
    pointing at "../.."; the dart name and pin come from the fixture's
    own override block, in either naming scheme.
    """
    flutter_name = None
    stripped = _strip_comments(fixture_text)
    for body in _call_bodies(stripped, "local_path_override"):
        attrs = _string_attrs(body)
        if attrs.get("path") == "../.." and "module_name" in attrs:
            flutter_name = attrs["module_name"]
    dart_name = None
    dart_pin = None
    for candidate in DART_MODULE_NAMES:
        dart_pin = extract_pin_block(stripped, candidate)
        if dart_pin is not None:
            dart_name = candidate
            break
    return (flutter_name, dart_name, dart_pin)


def local_path_override(module_name, path):
    """A local_path_override block for module_name pointing at path."""
    return (
        "local_path_override(\n"
        '    module_name = "%s",\n'
        '    path = "%s",\n)\n' % (module_name, path)
    )


def split_overrides(overrides, rules_flutter_dir):
    """(flutter_path, dart_path, extra) of --override NAME=PATH flags.

    NAME accepts the module name or the repo name of either rule set;
    anything else becomes a verbatim extra local_path_override.
    """
    flutter_path = rules_flutter_dir
    dart_path = None
    extra_overrides = ""
    for mod_name, mod_dir in overrides:
        if mod_name in FLUTTER_MODULE_NAMES:
            flutter_path = mod_dir
        elif mod_name in DART_MODULE_NAMES:
            dart_path = mod_dir
        else:
            extra_overrides += local_path_override(mod_name, mod_dir)
    return (flutter_path, dart_path, extra_overrides)


DEV_DROPPABLE_KINDS = ("bazel_dep", "register_toolchains",
                       "register_execution_platforms")


def _scan_code(text):
    """Per-char code mask and paren depth of MODULE.bazel text.

    Returns (is_code, depth_before): is_code[i] is False inside strings
    and # comments, depth_before[i] is the paren depth before text[i].
    Only double-quoted strings exist in these files.
    """
    is_code = [True] * len(text)
    depth_before = [0] * len(text)
    depth = 0
    in_str = False
    in_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_comment:
            is_code[i] = False
            if ch == "\n":
                in_comment = False
        elif in_str:
            is_code[i] = False
            if ch == "\\" and i + 1 < len(text):
                is_code[i + 1] = False
                depth_before[i + 1] = depth
                i += 1
            elif ch == '"':
                in_str = False
        elif ch == "#":
            is_code[i] = False
            in_comment = True
        elif ch == '"':
            is_code[i] = False
            in_str = True
        elif ch == "(":
            depth_before[i] = depth
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
            depth_before[i] = depth
        else:
            depth_before[i] = depth
        i += 1
    return (is_code, depth_before)


def _find_matching_paren(text, open_idx):
    """Index of the close paren matching the open paren at open_idx."""
    depth = 0
    i = open_idx
    in_str = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif ch == '"':
            in_str = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced parentheses in MODULE.bazel text")


def _top_level_calls(text):
    """(kind, start, close, body) of each top-level kind(...) call.

    Only calls at paren depth zero in real code: comments, strings and
    method calls (`.download(`, `.install(`) never match.
    """
    is_code, depth_before = _scan_code(text)
    calls = []
    for match in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(", text):
        kind = match.group(1)
        open_idx = match.end() - 1
        if not all(is_code[k] for k in range(match.start(), match.end())):
            continue
        if depth_before[open_idx] != 0:
            continue
        prev = match.start() - 1
        while prev >= 0 and text[prev] in " \t":
            prev -= 1
        if prev >= 0 and (text[prev] == "." or text[prev] == "_"
                          or text[prev].isalnum()):
            continue
        close_idx = _find_matching_paren(text, open_idx)
        calls.append((kind, match.start(), close_idx,
                      text[open_idx + 1:close_idx]))
    return calls


def _has_dev_dependency(body):
    """Whether a call body sets dev_dependency = True (comments ignored)."""
    stripped = _strip_comments(body)
    return re.search(r"\bdev_dependency\s*=\s*True\b", stripped) is not None


def _dropped_module_names(calls):
    """Module/repo names a dropped dev call provided."""
    names = set()
    for (kind, _, _, body) in calls:
        if kind == "bazel_dep":
            attrs = _string_attrs(body)
            if "name" in attrs:
                names.add(attrs["name"])
            if "repo_name" in attrs:
                names.add(attrs["repo_name"])
        else:
            names.update(re.findall(r'"@([^"/\s]+)//', body))
    return names


def drop_dev_dependency_blocks(text, label):
    """(text, names): fixture MODULE.bazel without dev-only dependencies.

    Removes every top-level bazel_dep, register_toolchains and
    register_execution_platforms call marked dev_dependency = True: each
    call's full text (first line through closing-paren line) plus exactly
    one directly following blank line, if there is one. Any other call
    kind marked dev_dependency = True fails with an error naming the
    call. The attribute is read from the call itself, so a comment that
    mentions dev_dependency drops nothing.
    """
    dev_calls = [c for c in _top_level_calls(text) if _has_dev_dependency(c[3])]
    for (kind, _, _, _) in dev_calls:
        if kind not in DEV_DROPPABLE_KINDS:
            raise ValueError(
                "fixture '%s' marks '%s' dev_dependency = True, which the "
                "bench workspace cannot drop" % (label, kind))
    names = _dropped_module_names(dev_calls)
    trailing = text.endswith("\n")
    lines = text.split("\n")
    if trailing:
        lines.pop()
    spans = []
    for (_, start, close, _) in dev_calls:
        spans.append((text.count("\n", 0, start), text.count("\n", 0, close)))
    for (first, last) in sorted(spans, reverse=True):
        del lines[first:last + 1]
        if first < len(lines) and lines[first].strip() == "":
            del lines[first]
    out = "\n".join(lines)
    if trailing:
        out += "\n"
    return (out, names)


def check_dropped_names_absent(out, names, label):
    """Fails when the generated text still names a dropped module."""
    for name in sorted(names):
        if ("@%s//" % name in out
                or re.search(r'module_name\s*=\s*"%s"' % re.escape(name),
                             out)
                or re.search(r'repo_name\s*=\s*"%s"' % re.escape(name), out)):
            raise ValueError(
                "fixture '%s' still references dropped dev dependency '%s'"
                % (label, name))


def fallback_module_text(flutter_name, dart_name, flutter_path,
                         dart_override, extra_overrides):
    """Embedded minimal MODULE.bazel when the fixture is absent.

    Names come from the tree (defaults for unit tests without one);
    the extension keeps the repo name, as labels do.
    """
    return (
        "module(name = \"%s\")\n" % BENCH_MODULE_NAME
        + "\n"
        + "bazel_dep(name = \"%s\", version = \"0.0.0\")\n" % flutter_name
        + "bazel_dep(name = \"%s\", version = \"0.7.3\")\n" % dart_name
        + "bazel_dep(name = \"bazel_skylib\", version = \"1.9.2\")\n"
        + "bazel_dep(name = \"apple_support\", version = \"2.9.1\")\n"
        + "bazel_dep(name = \"rules_apple\", version = \"5.2.0\")\n"
        + "bazel_dep(name = \"rules_swift\", version = \"4.1.2\")\n"
        + "bazel_dep(name = \"platforms\", version = \"1.1.0\")\n"
        + "bazel_dep(name = \"rules_android\", version = \"0.8.0\")\n"
        + "bazel_dep(name = \"rules_android_ndk\", version = \"0.1.5\")\n"
        + "bazel_dep(name = \"rules_kotlin\", version = \"2.4.20\")\n"
        + "bazel_dep(name = \"rules_java\", version = \"9.9.0\")\n"
        + "bazel_dep(name = \"rules_jvm_external\", version = \"7.1\")\n"
        + "\n"
        + local_path_override(flutter_name, flutter_path)
        + (dart_override or "")
        + extra_overrides
        + "remote_android_extensions = use_extension(\n"
        "    \"@rules_android//bzlmod_extensions:android_extensions.bzl\",\n"
        "    \"remote_android_tools_extensions\",\n"
        ")\n"
        "use_repo(remote_android_extensions, \"android_tools\")\n"
        "\n"
        "android_sdk_repository_extension = use_extension(\n"
        "    \"@rules_android//rules/android_sdk_repository:rule.bzl\",\n"
        "    \"android_sdk_repository_extension\",\n"
        ")\n"
        "android_sdk_repository_extension.configure(api_level = 35)\n"
        "use_repo(android_sdk_repository_extension, \"androidsdk\")\n"
        "register_toolchains(\n"
        "    \"@androidsdk//:sdk-toolchain\",\n"
        "    \"@androidsdk//:all\",\n"
        ")\n"
        "\n"
        "android_ndk_repository_extension = use_extension(\n"
        "    \"@rules_android_ndk//:extension.bzl\",\n"
        "    \"android_ndk_repository_extension\",\n"
        ")\n"
        "use_repo(android_ndk_repository_extension, \"androidndk\")\n"
        "register_toolchains(\"@androidndk//:all\")\n"
        "\n"
        "flutter = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n"
        "flutter.toolchain(flutter_version = \"3.47.7\")\n"
        "flutter.pub(\n"
        "    name = \"deps\",\n"
        "    lock = \"//:pubspec.lock\",\n)\n"
        "use_repo(flutter, \"deps\", \"flutter_android_engine_arm64\", \"flutter_ios_engine\", \"flutter_toolchains\", \"flutter_web_sdk\")\n"
        "\n"
        "register_toolchains(\"@flutter_toolchains//:all\")\n"
    )


class _PinReplacement(NamedTuple):
    """Dart override choice for the generated MODULE.bazel."""

    dart_name: str
    dart_path: Optional[str]
    fixture_pin: Optional[str]
    tree_pin: Optional[str]


class _PinResult(NamedTuple):
    """Generated MODULE.bazel text plus the appended extra overrides."""

    out: str
    extra: str


def _check_fixture_text(fixture, text):
    """Fails when the hello_world fixture lost its expected shape."""
    if "module(name = \"%s\")" % HELLO_MODULE_NAME not in text:
        raise ValueError(
            "fixture '%s' is not the hello_world module" % fixture)
    if text.count("path = \"../..\",") != 1:
        raise ValueError(
            "fixture '%s' lacks the single rules_flutter path override"
            % fixture)


def _apply_pin_replacement(out, extra_overrides, pin):
    """Swaps the fixture's dart pin for the override or the tree's pin."""
    if pin.dart_path is not None:
        dart_override = local_path_override(pin.dart_name, pin.dart_path)
        if pin.fixture_pin is not None and pin.fixture_pin in out:
            out = out.replace(pin.fixture_pin, dart_override, 1)
        else:
            # No pin block to swap (minimal fixture): append instead
            # so the override is never silently dropped.
            extra_overrides += dart_override
    elif pin.tree_pin is not None and pin.fixture_pin != pin.tree_pin:
        # The tree's own pin is the source of truth: without a user
        # override the generated workspace pins what the tree pins.
        if pin.fixture_pin is not None and pin.fixture_pin in out:
            out = out.replace(pin.fixture_pin, pin.tree_pin, 1)
        else:
            extra_overrides += pin.tree_pin
    return _PinResult(out, extra_overrides)


def module_bazel_text(rules_flutter_dir, overrides):
    """MODULE.bazel derived from the hello_world fixture.

    Every module name written comes from the trees, never from a
    constant: rules_flutter's own name from its MODULE.bazel
    module(name = ...), the rules_dart dependency's name and pin from
    the same file, and the fixture's names as the fixture declares
    them (both schemes: rules_* and ai_rules_*). An --override
    NAME=PATH accepts the module name or the repo name and is written
    under the module name the tree declares; without one the dart pin
    is the tree's own pin block. Labels keep the repo names
    (@rules_dart, @rules_flutter). Everything else stays
    byte-identical to the fixture. Falls back to an embedded minimal
    module when the fixture is absent (unit tests).
    """
    tree_flutter, tree_dart, tree_pin = read_tree_modules(rules_flutter_dir)
    flutter_path, dart_path, extra_overrides = split_overrides(
        overrides, rules_flutter_dir)

    fixture = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", "MODULE.bazel")
    if os.path.isfile(fixture):
        with open(fixture, encoding="utf-8") as fh:
            text = fh.read()
        _check_fixture_text(fixture, text)
        text, dropped = drop_dev_dependency_blocks(text, fixture)
        fixture_flutter, fixture_dart, fixture_pin = read_fixture_modules(
            text)
        if (tree_flutter is not None and fixture_flutter is not None
                and tree_flutter != fixture_flutter):
            raise ValueError(
                "fixture '%s' overrides %s but the tree is %s"
                % (fixture, fixture_flutter, tree_flutter))
        if (tree_dart is not None and fixture_dart is not None
                and tree_dart != fixture_dart):
            raise ValueError(
                "fixture '%s' pins %s but the tree depends on %s"
                % (fixture, fixture_dart, tree_dart))
        dart_name = tree_dart or fixture_dart or "rules_dart"
        out = text.replace(
            "module(name = \"%s\")" % HELLO_MODULE_NAME,
            "module(name = \"%s\")" % BENCH_MODULE_NAME,
        )
        out = out.replace(
            "path = \"../..\",",
            "path = \"%s\"," % flutter_path,
        )
        result = _apply_pin_replacement(
            out, extra_overrides,
            _PinReplacement(dart_name, dart_path, fixture_pin, tree_pin))
        out = result.out
        extra_overrides = result.extra
        out += extra_overrides
        check_dropped_names_absent(out, dropped, fixture)
        return out

    dart_override = None
    if dart_path is not None:
        dart_override = local_path_override(tree_dart or "rules_dart",
                                            dart_path)
    return fallback_module_text(tree_flutter or "rules_flutter",
                                tree_dart or "rules_dart", flutter_path,
                                dart_override, extra_overrides)


def copy_pub_file(out_dir, rules_flutter_dir, file_name, fallback):
    src = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", file_name)
    if os.path.isfile(src):
        with open(src, "rb") as fin:
            content = fin.read()
        with open(os.path.join(out_dir, file_name), "wb") as fout:
            fout.write(content)
    else:
        write_plain(out_dir, file_name, fallback)


def bazelrc_text(rules_flutter_dir):
    """Generated .bazelrc: the fixture's without extra defines or lockfile.

    The bench workspace models a consumer workspace, so the generated
    file carries no --lockfile_mode flag at all and Bazel's default
    applies: any such line the fixture carries is dropped, and none is
    ever inserted. Every other line stays byte-identical to the fixture.
    """
    fallback = (
        "test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze\n"
        "test --output_groups=+dart_analyze\n"
        "test --output_groups=+dart_format\n"
        "common --@rules_dart//dart:analysis_config=//:analysis_config\n"
        "try-import %workspace%/.bazelrc.user\n"
    )
    src = os.path.join(rules_flutter_dir, "e2e", "hello_world", ".bazelrc")
    try:
        with open(src, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return fallback
    kept = [
        line for line in raw.split("\n")
        if not line.startswith("@rules_flutter//flutter:extra_dart_defines")
        and not line.startswith(
            "common --@rules_flutter//flutter:extra_dart_defines")
        and "--lockfile_mode" not in line
    ]
    return "\n".join(kept) + "\n"


def copy_dir_sorted(src, dest):
    entries = sorted(os.listdir(src))
    os.makedirs(dest, exist_ok=True)
    for name in entries:
        s = os.path.join(src, name)
        d = os.path.join(dest, name)
        if os.path.isdir(s) and not os.path.islink(s):
            copy_dir_sorted(s, d)
        else:
            shutil.copy2(s, d)


def copy_fixture_dir(out_dir, rules_flutter_dir, fixture_rel, dest_rel):
    src = os.path.join(rules_flutter_dir, *fixture_rel)
    if not os.path.isdir(src):
        if os.path.isfile(os.path.join(rules_flutter_dir, "MODULE.bazel")):
            raise ValueError(
                "rules_flutter fixture '%s' is missing "
                "(required for the iOS app)" % src)
        return
    copy_dir_sorted(src, os.path.join(out_dir, dest_rel))


class _ScaffoldFiles(NamedTuple):
    """Workspace locations the scaffolding files are written to."""

    out_dir: str
    rules_flutter_dir: str
    overrides: list


def _write_root_files(files):
    """MODULE, pub files, bazelrc, analysis config and platform scaffolds."""
    out_dir = files.out_dir
    rules_flutter_dir = files.rules_flutter_dir
    bazel_version = read_bazel_version_or(rules_flutter_dir)
    module_text = module_bazel_text(rules_flutter_dir, files.overrides)
    write_plain(out_dir, "MODULE.bazel", module_text)
    copy_pub_and_lock_files(out_dir, rules_flutter_dir, module_text)
    write_plain(out_dir, ".bazelversion", bazel_version + "\n")
    write_plain(out_dir, ".bazelrc", bazelrc_text(rules_flutter_dir))
    copy_pub_file(
        out_dir, rules_flutter_dir, "analysis_options.yaml",
        "analyzer:\n  language:\n    strict-casts: true\n")
    write_plain(
        out_dir, "BUILD.bazel",
        "load(\"@rules_dart//dart:defs.bzl\", \"dart_analysis_config\", \"dart_analysis_options\")\n"
        "\n"
        "exports_files([\"pubspec.lock\"])\n"
        "\n"
        "dart_analysis_options(\n"
        "    name = \"options\",\n"
        "    src = \"analysis_options.yaml\",\n"
        "    deps = [\"@deps//:very_good_analysis\"],\n"
        ")\n"
        "\n"
        "dart_analysis_config(\n"
        "    name = \"analysis_config\",\n"
        "    options = [\":options\"],\n"
        ")\n")
    copy_fixture_dir(
        out_dir, rules_flutter_dir, ["e2e", "hello_world", "ios"], "app/ios")
    write_android_scaffolding(out_dir)


def _package_build_text(package, deps):
    """One leaf package BUILD.bazel (library over its direct deps)."""
    dep_lines = "".join(
        "        \"//packages/pkg%d\",\n" % d for d in deps)
    return (
        "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_library\", \"flutter_test\")\n"
        "\n"
        "_HOST_COMPATIBLE = select({\n"
        "    \"@platforms//os:linux\": [],\n"
        "    \"@platforms//os:macos\": [],\n"
        "    \"@platforms//os:windows\": [],\n"
        "    \"//conditions:default\": [\"@platforms//:incompatible\"],\n"
        "})\n"
        "\n"
        "flutter_library(\n"
        "    name = \"pkg%d\",\n" % package
        + "    package_name = \"pkg%d\",\n" % package
        + "    srcs = glob([\"lib/**/*.dart\"]),\n"
        + "    visibility = [\"//visibility:public\"],\n"
        + "    deps = [\n"
        + "%s" % dep_lines
        + "        \"@deps//:flutter\",\n"
        + "    ],\n"
        + ")\n"
    )


def _package_test_build_text(package, deps):
    """The flutter_test block appended for packages with tests."""
    dep_lines = "".join(
        "        \"//packages/pkg%d\",\n" % d for d in deps)
    return (
        "\nflutter_test(\n"
        "    name = \"pkg%d_test\",\n" % package
        + "    package_name = \"pkg%d\",\n" % package
        + "    main = \"test/pkg%d_test.dart\",\n" % package
        + "    srcs = glob([\"lib/**/*.dart\"]),\n"
        + "    target_compatible_with = _HOST_COMPATIBLE,\n"
        + "    deps = [\n"
        + "%s" % dep_lines
        + "        \"@deps//:flutter\",\n"
        + "        \"@deps//:flutter_test\",\n"
        + "    ],\n"
        + ")\n"
    )


def _write_package_builds(out_dir, plan):
    """Per-package BUILD.bazel files; returns the targets added."""
    targets = 0
    n = len(plan.dag["deps"])
    for p in range(n):
        write_plain(out_dir, "packages/pkg%d/BUILD.bazel" % p,
                    _package_build_text(p, plan.dag["deps"][p]))
        targets += 1
        if plan.has_test[p]:
            path = os.path.join(out_dir, "packages/pkg%d/BUILD.bazel" % p)
            with open(path, encoding="utf-8") as fh:
                existing = fh.read()
            write_plain(
                out_dir, "packages/pkg%d/BUILD.bazel" % p,
                existing + _package_test_build_text(p, plan.dag["deps"][p]))
            targets += 1
    return targets


def write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally):
    _write_root_files(_ScaffoldFiles(out_dir, rules_flutter_dir, overrides))
    tally["targets"] += _write_package_builds(out_dir, plan)
    tally["targets"] += write_app_build(
        out_dir, plan.top_layer(), plan.track_widget_creation)


def generate_flutter_monorepo(out_dir, rules_flutter_dir, overrides, opts):
    if not os.path.isdir(rules_flutter_dir):
        raise ValueError(
            "rules_flutter directory '%s' does not exist" % rules_flutter_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    plan, _ = select_package_count(opts)

    tally = {"files": 0, "lines": 0, "targets": 0}
    write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally)

    def write_dart(rel, content):
        write_plain(out_dir, rel, content)
        tally["files"] += 1
        tally["lines"] += count_lines(content)

    render_all_dart(opts, plan, write_dart)

    n = len(plan.dag["deps"])
    fan_in = fan_in_counts(plan.dag)
    fan_out = [len(d) for d in plan.dag["deps"]]
    stats = {
        "edit_layer": opts.edit_layer,
        "fan_in": fan_stats(fan_in),
        "fan_out": fan_stats(fan_out),
        "files": tally["files"],
        "generator": "flutter-monorepo",
        # Shape version: 2 = reachable program (entries call dep entries
        # and own functions under an unfoldable guard, main calls top-layer
        # entries). v1 numbers are never comparable with v2 numbers.
        "generator_version": 2,
        "layers": opts.layers,
        "lines": tally["lines"],
        "packages": n,
        "seed": opts.seed,
        "target_loc": opts.target_loc,
        "targets": tally["targets"],
        "test_ratio": opts.test_ratio,
    }

    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    if opts.packages is None and not lo <= tally["lines"] <= hi:
        raise ValueError(
            "flutter-monorepo generated %d lines for target_loc %d "
            "(outside +/-%d%%)"
            % (tally["lines"], opts.target_loc, int(LOC_TOLERANCE * 100)))

    manifest = {
        "api_edit": plan.edit_rel_path,
        "body_edit": plan.edit_rel_path,
        "app_main": "app/lib/main.dart",
    }
    write_plain(
        out_dir, EDIT_MANIFEST_REL_PATH,
        json.dumps(manifest, indent=2) + "\n")
    write_plain(
        out_dir, STATS_REL_PATH, json.dumps(stats, indent=2) + "\n")
    return stats


# --------------------------------------------------------------------------
# CLI.


def build_parser():
    parser = argparse.ArgumentParser(
        description="Generate a layered Flutter monorepo for the iOS bench.")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="generate a workspace")
    gen.add_argument("--target-loc", type=int, default=None,
                     help="required unless --packages derives it")
    gen.add_argument("--layers", type=int, default=None,
                     help="layer count (default %d)" % DEFAULT_LAYERS)
    gen.add_argument("--fanout", type=int, default=None,
                     help="direct deps per package (default %d)"
                     % DEFAULT_FANOUT)
    gen.add_argument("--packages", type=int, default=None,
                     help="exact package count; picks layers and fanout")
    gen.add_argument("--plugins", type=int, default=0,
                     help="native plugin packages (all three kinds)")
    gen.add_argument("--files-per-package", type=int,
                     default=DEFAULT_FILES_PER_PACKAGE)
    gen.add_argument("--seed", type=int, default=1)
    gen.add_argument("--test-ratio", type=float, default=DEFAULT_TEST_RATIO)
    gen.add_argument("--edit-layer", type=int, default=DEFAULT_EDIT_LAYER)
    gen.add_argument("--track-widget-creation", action="store_true",
                     help="set track_widget_creation on the application")
    gen.add_argument("--rules-flutter", required=True)
    gen.add_argument("--out", required=True)
    gen.add_argument("--override", action="append", default=[],
                     metavar="NAME=PATH",
                     help="extra local_path_override (repeatable)")

    for name in ["apply-body-edit", "apply-api-edit", "apply-app-edit"]:
        p = sub.add_parser(name, help="%s in a generated workspace" % name)
        p.add_argument("--workspace", required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "generate":
        overrides = []
        for item in args.override:
            name, _, path = item.partition("=")
            if not name or not path:
                raise ValueError(
                    "--override must be NAME=PATH, got '%s'" % item)
            overrides.append((name, path))
        packages, plugins = resolve_scale_args(
            parser, args, (DEFAULT_LAYERS, DEFAULT_FANOUT))
        opts = Options(
            target_loc=args.target_loc,
            layers=args.layers,
            fanout=args.fanout,
            files_per_package=args.files_per_package,
            seed=args.seed,
            test_ratio=args.test_ratio,
            edit_layer=args.edit_layer,
        )
        opts.packages = packages
        opts.track_widget_creation = args.track_widget_creation
        stats = generate_flutter_monorepo(
            args.out, args.rules_flutter, overrides, opts)
        if plugins:
            stats.update(add_plugins(
                args.out, plugins, SplitMix64((args.seed ^ 0xB1A57) & MASK64)))
            write_plain(args.out, STATS_REL_PATH,
                        json.dumps(stats, indent=2) + "\n")
        print(json.dumps(stats, indent=2))
    elif args.command == "apply-body-edit":
        apply_body_edit(args.workspace)
    elif args.command == "apply-api-edit":
        apply_api_edit(args.workspace)
    elif args.command == "apply-app-edit":
        apply_app_edit(args.workspace)
    else:  # pragma: no cover
        parser.error("unknown command '%s'" % args.command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
