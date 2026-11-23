"""Tests for the shared pub spoke walk bound.

Every pub spoke directory walk (asset listing, plugin source detection,
path-package linking) shares `PUB_WALK_BOUND` and fails loudly at it, and
the overlay heredoc rewrite fails loudly when blocks are left over. Each
walk is driven here with a small bound and a fake directory listing:
exactly the bound passes, the bound plus one fails with the message naming
the package, the directory or template, and the bound.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_assets.bzl",
    "PUB_ASSET_LIST_BOUND",
    "list_files_recursive",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "link_scoped_tree_bounded",
    "rewrite_cat_genrules_bounded",
)
load(
    "//flutter/private:flutter_pub_walk.bzl",
    "PUB_WALK_BOUND",
    "has_files_bound_error",
    "has_files_under_walk",
    "heredoc_blocks_bound_error",
    "scoped_tree_bound_error",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

# -- shared bound ---------------------------------------------------------------------

def _shared_bound_covers_monorepos_test_impl(ctx):
    """One bound of at least a million directories for every pub spoke walk."""
    env = unittest.begin(ctx)
    asserts.true(env, PUB_WALK_BOUND >= 1000000, "PUB_WALK_BOUND is %d" % PUB_WALK_BOUND)
    asserts.equals(env, PUB_WALK_BOUND, PUB_ASSET_LIST_BOUND)
    return unittest.end(env)

# -- asset listing ---------------------------------------------------------------------

# A linear chain needing exactly 3 directory pops to drain: bound 3 passes,
# bound 2 leaves c1/c2/c3 unvisited.
_ASSET_PASS_TREE = {
    "pics": [struct(name = "c1", is_dir = True)],
    "pics/c1": [struct(name = "c2", is_dir = True)],
    "pics/c1/c2": [struct(name = "logo.png", is_dir = False)],
}

_ASSET_FAIL_TREE = {
    "pics": [struct(name = "c1", is_dir = True)],
    "pics/c1": [struct(name = "c2", is_dir = True)],
    "pics/c1/c2": [struct(name = "c3", is_dir = True)],
    "pics/c1/c2/c3": [struct(name = "logo.png", is_dir = False)],
}

def _tree_readdir(tree):
    """A `readdir` callable over a dict tree; a missing directory reads as empty."""

    def readdir(directory):
        return tree.get(directory, [])

    return readdir

def _asset_bound_passes_at_the_bound_test_impl(ctx):
    """A walk needing exactly the bound pops lists every file, no error."""
    env = unittest.begin(ctx)
    result = list_files_recursive(_tree_readdir(_ASSET_PASS_TREE), "pics", "walk_pkg", 3)
    asserts.equals(env, "", result.error)
    asserts.equals(env, ["pics/c1/c2/logo.png"], result.files)
    return unittest.end(env)

def _asset_bound_fails_past_the_bound_test_impl(ctx):
    """A walk needing one pop more fails naming package, directory, bound."""
    env = unittest.begin(ctx)
    result = list_files_recursive(_tree_readdir(_ASSET_FAIL_TREE), "pics", "walk_pkg", 3)
    asserts.equals(env, [], result.files)
    for want in ["walk_pkg", "pics", "3"]:
        asserts.true(env, want in result.error, result.error)
    return unittest.end(env)

# -- plugin source detection ------------------------------------------------------------
#
# The wanted file sits behind five empty sibling directories (pushed before
# them, so every empty dir is popped first): 7 pops to find it. Bound 7
# still finds it; bound 6 reports the bound instead of "no files".

_SCAN_EXTENSIONS = ("m", "mm", "swift", "h")

def _scan_tree(empty_count):
    tree = {"ios": [struct(name = "target", is_dir = True)] + [
        struct(name = "e%d" % i, is_dir = True)
        for i in range(empty_count)
    ]}
    tree["ios/target"] = [struct(name = "Plugin.m", is_dir = False)]
    return tree

def _source_scan_finds_file_after_empty_dirs_test_impl(ctx):
    """A file reachable only after many empty dirs is still found at the bound."""
    env = unittest.begin(ctx)
    result = has_files_under_walk(_tree_readdir(_scan_tree(5)), "ios", "scan_pkg", _SCAN_EXTENSIONS, 7)
    asserts.equals(env, "", result.error)
    asserts.true(env, result.found)
    return unittest.end(env)

def _source_scan_bound_reports_loudly_test_impl(ctx):
    """One pop short of the file reports the bound, never "no files"."""
    env = unittest.begin(ctx)
    result = has_files_under_walk(_tree_readdir(_scan_tree(5)), "ios", "scan_pkg", _SCAN_EXTENSIONS, 6)
    asserts.false(env, result.found)
    for want in ["scan_pkg", "ios", "6"]:
        asserts.true(env, want in result.error, result.error)
    message = has_files_bound_error("scan_pkg", "ios", 6)
    asserts.equals(env, message, result.error)
    return unittest.end(env)

def _source_scan_without_match_walks_clean_test_impl(ctx):
    """A walked tree with no matching file answers no-files with no error."""
    env = unittest.begin(ctx)
    tree = {
        "ios": [struct(name = "docs", is_dir = True)],
        "ios/docs": [struct(name = "notes.txt", is_dir = False)],
    }
    result = has_files_under_walk(_tree_readdir(tree), "ios", "scan_pkg", _SCAN_EXTENSIONS, 7)
    asserts.equals(env, "", result.error)
    asserts.false(env, result.found)
    return unittest.end(env)

# -- path-package linking ------------------------------------------------------------------
#
# A chain needing exactly 3 pops to mirror (the root plus two subdirs):
# bound 3 links every file, bound 2 leaves directories unvisited.

def _link_dir_node(package_realpath, repo_rel, children):
    """A fake source directory node with the `readdir` / `realpath` shape the link walk reads."""
    return struct(
        basename = repo_rel.split("/")[-1],
        is_dir = True,
        realpath = package_realpath + "/" + repo_rel,
        readdir = lambda: children,
    )

def _link_file_node(package_realpath, repo_rel):
    """A fake source file node with the `realpath` shape the link walk reads."""
    return struct(
        basename = repo_rel.split("/")[-1],
        is_dir = False,
        realpath = package_realpath + "/" + repo_rel,
    )

def _make_link_ctx():
    """A fake repository context recording watches and symlinks by real path."""
    watched = []
    symlinked = []
    fake = struct(
        watch = lambda node: watched.append(node.realpath),
        symlink = lambda target, name: symlinked.append(struct(name = name, target = target.realpath)),
    )
    return struct(ctx = fake, watched = watched, symlinked = symlinked)

def _link_chain_root():
    """The chain `assets/d1/d2/f.txt` plus a skipped `assets/build/` subtree, built bottom-up."""
    leaf = _link_file_node("/pkg", "assets/d1/d2/f.txt")
    inner = _link_dir_node("/pkg", "assets/d1/d2", [leaf])
    outer = _link_dir_node("/pkg", "assets/d1", [inner])
    skipped = _link_dir_node("/pkg", "assets/build", [_link_file_node("/pkg", "assets/build/out.txt")])
    return _link_dir_node("/pkg", "assets", [outer, skipped])

def _link_walk_passes_at_the_bound_test_impl(ctx):
    """A tree needing exactly the bound pops links every file, none skipped wrongly.

    The `build/` subtree stays unlinked and unwatched, like every skipped
    directory; everything else links one file at a time.
    """
    env = unittest.begin(ctx)
    mock = _make_link_ctx()
    linked = {}
    leftover = link_scoped_tree_bounded(
        mock.ctx,
        _link_chain_root(),
        "assets",
        "mypkg",
        "/pkg",
        "/",
        linked,
        3,
    )
    asserts.false(env, leftover)
    asserts.equals(env, ["/pkg/assets/d1/d2/f.txt"], sorted([link.target for link in mock.symlinked]))
    asserts.equals(env, ["assets/d1/d2/f.txt"], sorted([link.name for link in mock.symlinked]))
    for seen in mock.watched + [link.target for link in mock.symlinked]:
        asserts.false(env, "build" in seen, "skipped build/ must stay out, saw {}".format(seen))
    return unittest.end(env)

def _link_walk_reports_leftover_past_the_bound_test_impl(ctx):
    """One pop more than the bound leaves directories behind for the caller to refuse."""
    env = unittest.begin(ctx)
    mock = _make_link_ctx()
    leftover = link_scoped_tree_bounded(
        mock.ctx,
        _link_chain_root(),
        "assets",
        "mypkg",
        "/pkg",
        "/",
        {},
        2,
    )
    asserts.true(env, leftover)
    message = scoped_tree_bound_error("mypkg", 2)
    for want in ["mypkg", "holds more than 2 directories", "Refusing it rather than fetching part of the tree"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

# -- overlay heredoc rewrite ------------------------------------------------------------------
#
# Each case below holds exactly as many convertible blocks as stated: the
# bound rewrites them all, one fewer leaves a convertible block behind.

def _heredoc_block(i):
    return ("genrule(\n    name = \"file%d\",\n    outs = [\"out%d.txt\"],\n" +
            "    cmd = \"cat > $@ <<'EOF'\\nline%d\\nEOF\\n\",\n)\n") % (i, i, i)

def _heredoc_template(block_count):
    return "load(\"x\")\n\n" + "".join([_heredoc_block(i) for i in range(block_count)])

def _heredoc_rewrite_passes_at_the_bound_test_impl(ctx):
    """Exactly the bound blocks all rewrite to `write_file`, none left over."""
    env = unittest.begin(ctx)
    result = rewrite_cat_genrules_bounded(_heredoc_template(2), "audiopkg", "BUILD.bazel.tpl", 2)
    asserts.false(env, result.leftover)
    asserts.false(env, "genrule(" in result.text, result.text)
    asserts.equals(env, 2, len(result.text.split("write_file(")) - 1)
    return unittest.end(env)

def _heredoc_rewrite_reports_leftover_past_the_bound_test_impl(ctx):
    """One block more than the bound leaves a convertible block behind to refuse."""
    env = unittest.begin(ctx)
    result = rewrite_cat_genrules_bounded(_heredoc_template(3), "audiopkg", "BUILD.bazel.tpl", 2)
    asserts.true(env, result.leftover)
    message = heredoc_blocks_bound_error("audiopkg", "BUILD.bazel.tpl", 2)
    for want in ["audiopkg", "BUILD.bazel.tpl", "2"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

_t0_test = unittest.make(_shared_bound_covers_monorepos_test_impl)
_t1_test = unittest.make(_asset_bound_passes_at_the_bound_test_impl)
_t2_test = unittest.make(_asset_bound_fails_past_the_bound_test_impl)
_t3_test = unittest.make(_source_scan_finds_file_after_empty_dirs_test_impl)
_t4_test = unittest.make(_source_scan_bound_reports_loudly_test_impl)
_t5_test = unittest.make(_source_scan_without_match_walks_clean_test_impl)
_t6_test = unittest.make(_link_walk_passes_at_the_bound_test_impl)
_t7_test = unittest.make(_link_walk_reports_leftover_past_the_bound_test_impl)
_t8_test = unittest.make(_heredoc_rewrite_passes_at_the_bound_test_impl)
_t9_test = unittest.make(_heredoc_rewrite_reports_leftover_past_the_bound_test_impl)

def pub_walk_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
    )
