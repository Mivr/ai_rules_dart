"""`--packages` / `--plugins` handling for `gen_monorepo.py generate`.

`--packages=N` picks the layer count and fanout so that `layers * fanout`
is at least N, over the existing layered DAG builder, and pins the package
count to exactly N. `--plugins=N` asks for N native plugin packages. Both
refuse bad values (and `--packages` beside an explicit `--layers` or
`--fanout`) through the parser, which exits 2 with a message on stderr.
"""

import math

# Lines per file the generator's own package-count estimate assumes.
LINES_PER_FILE_ESTIMATE = 125


def layers_and_fanout(packages):
    """Balanced (layers, fanout) with layers * fanout >= packages."""
    layers = max(2, math.isqrt(packages - 1) + 1)
    fanout = -(-packages // layers)
    return layers, fanout


def resolve_scale_args(parser, args, defaults):
    """Validates the scale flags and fills layers/fanout/target_loc in.

    Returns (packages, plugins); packages is None without `--packages`.
    `defaults` is the (layers, fanout) used without `--packages`. Calls
    `parser.error` (exit 2) on a refused combination.
    """
    if args.plugins < 0:
        parser.error("--plugins must be >= 0, got %d" % args.plugins)
    if args.packages is None:
        args.layers = defaults[0] if args.layers is None else args.layers
        args.fanout = defaults[1] if args.fanout is None else args.fanout
        if args.target_loc is None:
            parser.error("--target-loc is required without --packages")
        return None, args.plugins
    if args.packages < 2:
        parser.error("--packages must be >= 2, got %d" % args.packages)
    if args.layers is not None or args.fanout is not None:
        parser.error("--packages cannot be combined with --layers or "
                     "--fanout: it picks both")
    args.layers, args.fanout = layers_and_fanout(args.packages)
    if args.target_loc is None:
        args.target_loc = (args.packages * args.files_per_package
                           * LINES_PER_FILE_ESTIMATE)
    return args.packages, args.plugins
