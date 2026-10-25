"""Unit tests for dart/pub/private/yaml_subset.bzl, the pubspec YAML parser.

Expected values match what yaml.bzl returns for the same text, except the
folded (`>`) block scalar cases, whose blank-line folding follows pub
(package:yaml 3.1.4) rather than yaml.bzl. The parity check against
yaml.bzl ran over a corpus of real pubspec files and generated documents;
these cases pin the constructs it covers.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:yaml_subset.bzl", "document_problems", "document_value_and_problems", "parse_document")
load(":small_suite.bzl", "small_unittest_suite")

def _block_mapping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": 1, "b": {"c": "x", "d": {"e": True}}},
        parse_document("a: 1\nb:\n  c: x\n  d:\n    e: true\n"),
    )
    return unittest.end(env)

def _block_sequence_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["x", ["y", "z"], {"k": "v", "n": 3}, "tail"],
        parse_document("- x\n-\n  - y\n  - z\n- k: v\n  n: 3\n- tail\n"),
    )
    return unittest.end(env)

def _same_indent_sequence_test_impl(ctx):
    env = unittest.begin(ctx)

    # A sequence at its key's own column is the key's value (M-12).
    asserts.equals(env, {"a": ["x"], "b": 1}, parse_document("a:\n- x\nb: 1\n"))
    return unittest.end(env)

def _compact_sequence_test_impl(ctx):
    env = unittest.begin(ctx)

    # Compact sequences equal their indented twins at three depths (M-12).
    asserts.equals(
        env,
        parse_document("topics:\n  - a\n  - b\n"),
        parse_document("topics:\n- a\n- b\n"),
    )
    asserts.equals(
        env,
        parse_document("flutter:\n  assets:\n    - a.png\n    - b.png\n"),
        parse_document("flutter:\n  assets:\n  - a.png\n  - b.png\n"),
    )
    asserts.equals(
        env,
        parse_document("fonts:\n  - family: F\n    fonts:\n      - asset: f.ttf\n      - asset: g.ttf\n"),
        parse_document("fonts:\n  - family: F\n    fonts:\n    - asset: f.ttf\n    - asset: g.ttf\n"),
    )

    # Blank and comment lines inside the run change nothing.
    asserts.equals(
        env,
        parse_document("topics:\n  - a\n  - b\n"),
        parse_document("topics:\n\n- a\n# note\n- b\n\n"),
    )
    asserts.equals(env, {"topics": ["a", "b"]}, parse_document("topics:\n- a\n- b\n"))
    return unittest.end(env)

def _folded_scalar_test_impl(ctx):
    env = unittest.begin(ctx)

    # Scalars starting after `key:` fold with single spaces (M-12).
    asserts.equals(env, {"d": "a long description continued"}, parse_document("d:\n  a long description\n  continued\n"))
    asserts.equals(env, {"d": "foo bar"}, parse_document("d: foo\n  bar\n"))
    asserts.equals(env, {"d": "quoted value"}, parse_document("d:\n  'quoted value'\n"))
    asserts.equals(env, {"d": "quoted value"}, parse_document('d:\n  "quoted value"\n'))
    asserts.equals(env, {"d": "next line scalar"}, parse_document("d:\n  next line scalar\n"))
    return unittest.end(env)

def _quoted_multiline_test_impl(ctx):
    env = unittest.begin(ctx)

    # A quoted scalar whose closing quote is on a later, more-indented line
    # folds the break to one space, then unquotes as on one line (M-12).
    asserts.equals(env, {"a": "foo bar"}, parse_document("a: \"foo\n  bar\"\n"))
    asserts.equals(env, {"a": "foo bar"}, parse_document("a: 'foo\n  bar'\n"))
    asserts.equals(env, {"a": "a\tb c"}, parse_document("a: \"a\\tb\n  c\"\n"))
    asserts.equals(env, {"a": "one two three"}, parse_document("a: \"one\n  two\n  three\"\n"))
    asserts.equals(env, {"d": "foo bar"}, parse_document("d:\n  \"foo\n  bar\"\n"))

    # A quoted scalar that is never closed is a problem naming its line.
    value, problems = document_value_and_problems("a: \"foo\n  bar\n", True)
    asserts.equals(env, None, value["a"])
    asserts.true(env, len(problems) == 1 and "line 1" in problems[0])
    return unittest.end(env)

def _comment_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": 1, "b": "x # not", "c": "x#y", "d": "q # r", "e": "plain"},
        parse_document("a: 1 # trailing\n# full line\nb: 'x # not' # yes\nc: x#y\nd: \"q # r\"\ne: plain\n"),
    )
    return unittest.end(env)

def _document_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    # One stream carries one document, as pub reads it: a second `---`
    # fails naming its line, even before any content, and so does any
    # content after a `...` line, naming the content's line.
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("a: 1\n---\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("a: 1\n---\nb: 2\n", False),
    )
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("---\n---\na: 1\n", True),
    )
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("a: 1\n---\n# only a comment\n", True),
    )
    asserts.equals(
        env,
        ["content after document end (...) at line 4"],
        document_problems("---\na: 1\n...\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["content after document end (...) at line 2"],
        document_problems("a: 1\n... text\n", True),
    )
    asserts.equals(
        env,
        ["second document marker (---) at line 3"],
        document_problems("a: 1\n...\n---\nb: 2\n", True),
    )
    value, problems = document_value_and_problems("a: 1\n---\nb: 2\n", True)
    asserts.equals(env, {"a": 1}, value)
    asserts.equals(env, 1, len(problems))

    # A leading `---`, a trailing `...` and inline marker text read as pub
    # reads them (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    asserts.equals(env, {"a": 1}, parse_document("---\na: 1\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n...\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n... # c\n"))
    asserts.equals(env, "foo", parse_document("--- foo\n"))
    asserts.equals(env, "text", parse_document("... text\n"))
    asserts.equals(env, "...text", parse_document("...text\n"))
    asserts.equals(env, "....", parse_document("....\n"))
    asserts.equals(env, "---foo", parse_document("---foo\n"))
    asserts.equals(env, {"a": 1}, parse_document("%YAML 1.2\n---\na: 1\n"))
    asserts.equals(env, None, parse_document(""))
    asserts.equals(env, None, parse_document("# only a comment\n"))
    asserts.equals(env, None, parse_document("...\n"))
    asserts.equals(env, None, parse_document("---\n"))
    asserts.equals(env, [], document_problems("a: 1\n...\n", True))
    return unittest.end(env)

def _plain_scalar_type_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: 1\nb: 1.10\nc: true\nd: True\ne: ~\nf:\ng: null\nh: 0x1F\ni: 0o17\n" +
        "j: 1_000\nk: .inf\nl: -.inf\nm: 1e3\nn: 1.5E-3\no: 1.2.3\np: 007\nq: -1\n",
    )

    asserts.equals(env, 1, parsed["a"])
    asserts.equals(env, "int", type(parsed["a"]))

    # An unquoted decimal is a float, so str() drops the trailing zero.
    asserts.equals(env, "float", type(parsed["b"]))
    asserts.equals(env, "1.1", str(parsed["b"]))

    asserts.equals(env, True, parsed["c"])
    asserts.equals(env, True, parsed["d"])
    asserts.equals(env, None, parsed["e"])
    asserts.equals(env, None, parsed["f"])
    asserts.equals(env, None, parsed["g"])
    asserts.equals(env, 31, parsed["h"])
    asserts.equals(env, 15, parsed["i"])
    asserts.equals(env, 1000, parsed["j"])
    asserts.equals(env, "float", type(parsed["k"]))
    asserts.equals(env, "float", type(parsed["l"]))
    asserts.equals(env, "float", type(parsed["m"]))
    asserts.equals(env, 1000.0, parsed["m"])
    asserts.equals(env, 0.0015, parsed["n"])
    asserts.equals(env, "1.2.3", parsed["o"])
    asserts.equals(env, 7, parsed["p"])
    asserts.equals(env, -1, parsed["q"])
    return unittest.end(env)

def _quoted_scalar_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {
            "a": "it's",
            "b": "x\ty\n\"q\" \\ /",
            "c": "Aé",
            "d": "\\q",
            "e": "1.10",
            "f": "# not a comment",
        },
        parse_document(
            "a: 'it''s'\n" +
            "b: \"x\\ty\\n\\\"q\\\" \\\\ \\/\"\n" +
            "c: \"\\x41\\u00e9\"\n" +
            "d: \"\\q\"\n" +
            "e: '1.10'\n" +
            "f: '# not a comment'\n",
        ),
    )
    return unittest.end(env)

def _flow_collection_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {
            "a": {"path": "../x", "git": {"url": "u", "ref": "main"}},
            "b": [1, [2, 3], {"x": "y"}],
            "c": [],
            "d": {},
            "e": ["a"],
            "f": ["q", "r"],
            "h": 1,
        },
        parse_document(
            "a: {path: ../x, git: {url: 'u', ref: main}}\n" +
            "b: [1, [2, 3], {x: y}]\n" +
            "c: []\n" +
            "d: {}\n" +
            "e: [a,]\n" +
            "f: [\"q\", 'r']\n" +
            "h: 1\n",
        ),
    )

    # An unreadable flow value is a problem naming the line; leniently it
    # reads as None (M-12).
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"[1, 2\""],
        document_problems("a: [1, 2\nb: 2\n", True),
    )
    value, problems = document_value_and_problems("a: [1, 2\nb: 2\n", False)
    asserts.equals(env, {"a": None, "b": 2}, value)
    asserts.equals(env, [], problems)
    return unittest.end(env)

def _flow_quote_start_test_impl(ctx):
    env = unittest.begin(ctx)

    # An apostrophe inside a plain scalar never opens a quote: only a quote
    # where a scalar starts opens one, as pub reads each form below
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    asserts.equals(env, {"don't": 1}, parse_document("don't: 1\n"))
    asserts.equals(env, {"don't": 1}, parse_document("don't: 1 # c\n"))
    asserts.equals(env, ["don't", "stop"], parse_document("key: [don't, stop]\n")["key"])
    asserts.equals(env, ["don't", "x"], parse_document("key: ['don''t', x]\n")["key"])

    # A quoted key glued to its colon is one pair, and a `#` comment past
    # the closing bracket is separation, as pub reads them.
    asserts.equals(env, [{"a": 1}], parse_document("key: [\"a\": 1]\n")["key"])
    asserts.equals(env, ["a"], parse_document("key: [a]#c\n")["key"])
    asserts.equals(env, {"a": 1}, parse_document("key: {a: 1}#c\n")["key"])

    # Text glued after a closing quote and a `%`-leading scalar are
    # unreadable, as pub rejects them.
    problems = document_problems("key: [\"a\" \"b\"]\n", True)
    asserts.equals(env, 1, len(problems))
    asserts.true(env, "unreadable flow value at line 1" in problems[0])
    problems = document_problems("key: [%x]\n", True)
    asserts.equals(env, 1, len(problems))
    asserts.true(env, "unreadable flow value at line 1" in problems[0])

    # A document that starts like a flow collection but reads as none fails
    # naming the line, as pub rejects it.
    asserts.equals(
        env,
        ["flow document ending at line 1 is not supported"],
        document_problems("{name: x\n", True),
    )
    asserts.equals(
        env,
        ["flow document ending at line 2 is not supported"],
        document_problems("{name: x,\n environment: {sdk: ^3.0.0}\n", True),
    )
    return unittest.end(env)

def _block_scalar_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: |\n  one\n  two\n" +
        "b: >\n  folded\n  text\n\n  next\n" +
        "c: |-\n  strip\n" +
        "d: |+\n  keep\n\n" +
        "e: |2\n    indented\n" +
        "f: 1\n",
    )
    asserts.equals(env, "one\ntwo\n", parsed["a"])

    # A blank line in a folded scalar is one break: the break after the
    # content line drops and the blank line adds one, as pub folds it
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    asserts.equals(env, "folded text\nnext\n", parsed["b"])
    asserts.equals(env, "strip", parsed["c"])
    asserts.equals(env, "keep\n\n", parsed["d"])
    asserts.equals(env, "  indented\n", parsed["e"])
    asserts.equals(env, 1, parsed["f"])
    return unittest.end(env)

def _plain_continuation_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        {"a": "one two", "b": "y"},
        parse_document("a: one\n  two\nb: y\n"),
    )

    # A continuation line that looks like a mapping entry ends the scalar and
    # is a problem naming the line (M-12).
    asserts.equals(
        env,
        ["unreadable line 3: \"three: x\""],
        document_problems("a: one\n  two\n  three: x\nb: y\n", True),
    )
    asserts.equals(env, {"a": "plain\ntext"}, parse_document("a: plain\n\n  text\n"))
    return unittest.end(env)

def _anchor_alias_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"base": {"x": 1}, "child": {"x": 1}, "s": "hello", "t": "hello"},
        parse_document("base: &b\n  x: 1\nchild: *b\ns: &v hello\nt: *v\n"),
    )

    # An undefined alias fails naming the line, as pub rejects it, and still
    # reads None so parsing continues past it.
    value, problems = document_value_and_problems("s: &v hello\nt: *v\nu: *none\n", True)
    asserts.equals(env, {"s": "hello", "t": "hello", "u": None}, value)
    asserts.equals(env, ["undefined alias \"none\" at line 3"], problems)

    # An alias after an anchor or tag never reads, as pub rejects it, even
    # when the alias resolves; the anchor still binds None.
    value, problems = document_value_and_problems("s: &v VIC\nk: &x *v\n", True)
    asserts.equals(env, {"s": "VIC", "k": None}, value)
    asserts.equals(env, ["alias after anchor at line 2 is not supported"], problems)
    value, problems = document_value_and_problems("s: &v VIC\nk: !foo *v\n", True)
    asserts.equals(env, {"s": "VIC", "k": None}, value)
    asserts.equals(env, ["alias after tag at line 2 is not supported"], problems)

    # A colon glued to an alias joins the name, as pub scans it, so `*v: 1`
    # never reads as a pair: an unresolvable name reports its alias problem,
    # and a resolvable one is still a problem naming the line.
    value, problems = document_value_and_problems("s: &v VIC\n*v: 1\n", True)
    asserts.equals(env, {"s": "VIC", None: 1}, value)
    asserts.equals(env, ["undefined alias \"v:\" at line 2"], problems)
    value, problems = document_value_and_problems("s: &v: 1\n*v: 1\n", True)
    asserts.equals(env, {"s": 1, None: 1}, value)
    asserts.equals(env, ["glued alias key at line 2 is not supported"], problems)
    return unittest.end(env)

def _flow_affix_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # A glued colon joins an alias name, as pub scans it: `{*v: 1}` fails on
    # the `v:` name, while a spaced colon pairs the resolved alias.
    value, problems = document_value_and_problems("s: &v VIC\nk: {*v: 1}\n", True)
    asserts.equals(env, {"s": "VIC", "k": {None: None}}, value)
    asserts.equals(env, ["undefined alias \"v:\" at line 2"], problems)
    asserts.equals(env, {"s": "VIC", "k": {"VIC": 1}}, parse_document("s: &v VIC\nk: {*v : 1}\n"))

    # An anchor or tag word takes a glued colon into its name, as pub scans
    # it, so the key after it reads plainly and the anchor binds the key.
    asserts.equals(env, {"k": {1: None}}, parse_document("k: {&v: 1}\n"))
    asserts.equals(env, {"k": [{1: None}, 1]}, parse_document("k: [{&v: 1}, *v:]\n"))
    asserts.equals(env, {"k": {1: None}}, parse_document("k: {!foo: 1}\n"))
    asserts.equals(env, {"k": {"bar": None}}, parse_document("k: {!foo: bar}\n"))

    # A `!!` tag with a glued colon has no scalar to convert, as pub reports.
    value, problems = document_value_and_problems("k: {!!int: 1}\n", True)
    asserts.equals(env, {"k": {1: None}}, value)
    asserts.equals(env, ["Undefined tag: tag:yaml.org,2002:int: at line 1"], problems)

    # A bare anchor reads a null key and a bare tag its dropped value, as pub
    # reads them.
    asserts.equals(env, {"k": {None: 1}}, parse_document("k: {&x : 1}\n"))
    asserts.equals(env, {"k": {"": 1}}, parse_document("k: {!foo : 1}\n"))
    asserts.equals(env, {"k": {"": 1}}, parse_document("k: {&x !foo : 1}\n"))

    # A key with no pair colon at all reads with a null value, as pub reads it.
    asserts.equals(env, {"k": {"a": None}}, parse_document("k: {a}\n"))
    return unittest.end(env)

def _flow_affix_item_test_impl(ctx):
    env = unittest.begin(ctx)

    # A colon where the value starts pairs the anchor or tag on its own with
    # the value, as pub reads it.
    asserts.equals(env, {"k": [{"": 1}]}, parse_document("k: [!foo : 1]\n"))
    asserts.equals(env, {"k": [{None: 1}]}, parse_document("k: [&x : 1]\n"))
    asserts.equals(env, {"k": [{None: 1}]}, parse_document("k: [: 1]\n"))

    # A glued colon joins an alias name in items too; a spaced colon pairs it.
    value, problems = document_value_and_problems("s: &v VIC\nk: [*v: 1]\n", True)
    asserts.equals(env, {"s": "VIC", "k": [None]}, value)
    asserts.equals(env, ["undefined alias \"v:\" at line 2"], problems)
    asserts.equals(env, {"s": "VIC", "k": [{"VIC": 1}]}, parse_document("s: &v VIC\nk: [*v : 1]\n"))

    # An anchor word takes a glued colon into its name and binds the value.
    asserts.equals(env, {"k": [[1], 1]}, parse_document("k: [[&v: 1], *v:]\n"))
    asserts.equals(env, {"k": ["bar"]}, parse_document("k: [!foo: bar]\n"))

    # An alias after an anchor or tag never reads, as pub rejects it.
    value, problems = document_value_and_problems("s: &v VIC\nk: [&x *v]\n", True)
    asserts.equals(env, {"s": "VIC", "k": [None]}, value)
    asserts.equals(env, ["alias after anchor at line 2 is not supported"], problems)

    # A bare anchor reads null, and an alias to it reads back, as pub reads them.
    asserts.equals(env, {"k": [None, None]}, parse_document("k: [&x, *x]\n"))
    return unittest.end(env)

def _flow_self_anchor_test_impl(ctx):
    env = unittest.begin(ctx)

    # An anchor marks its collection open, so an alias inside it fails closed
    # as a self-reference, as pub rejects it; after the close it reads back.
    value, problems = document_value_and_problems("k: &x [*x]\n", True)
    asserts.equals(env, {"k": [None]}, value)
    asserts.equals(env, ["self-referential alias \"x\" at line 1 is not supported"], problems)
    asserts.equals(env, {"k": [[1], [1]]}, parse_document("k: [&x [1], *x]\n"))

    # An anchor on a pair binds the key, as pub reads it.
    asserts.equals(env, {"k": [{"k": "v"}, "k"]}, parse_document("k: [&x k: v, *x]\n"))

    # A repeated anchor or tag fails naming the line, as pub rejects it.
    value, problems = document_value_and_problems("k: &x &y 1\n", True)
    asserts.equals(env, {"k": 1}, value)
    asserts.equals(env, ["repeated anchor at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("k: !a !b 1\n", True)
    asserts.equals(env, {"k": 1}, value)
    asserts.equals(env, ["repeated tag at line 1 is not supported"], problems)

    # A tab ends an anchor word, as pub reads it.
    asserts.equals(env, {"k": "v"}, parse_document("k: &x\tv\n"))
    return unittest.end(env)

def _tag_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: !!str 1.10\nb: !!int '12'\nc: !!float 3\nd: !!bool yes\n" +
        "e: !!null x\nf: !!int 1.5\ng: !!bool maybe\n" +
        "h: !<tag:yaml.org,2002:str> 2.0\ni: !str 3.0\n",
    )
    asserts.equals(env, "1.10", parsed["a"])
    asserts.equals(env, 12, parsed["b"])

    # yaml.bzl reads `!!float 3` as 0.0: its float reader wants a decimal point.
    asserts.equals(env, 0.0, parsed["c"])
    asserts.equals(env, True, parsed["d"])
    asserts.equals(env, None, parsed["e"])
    asserts.equals(env, 0, parsed["f"])
    asserts.equals(env, False, parsed["g"])
    asserts.equals(env, "2.0", parsed["h"])
    asserts.equals(env, "3.0", parsed["i"])
    return unittest.end(env)

def _collection_tag_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": [1, 2], "b": {"x": 1}, "c": [], "d": {}},
        parse_document("a: !!seq [1, 2]\nb: !!map {x: 1}\nc: !!seq 3\nd: !!map []\n"),
    )
    return unittest.end(env)

def _json_document_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": [1, 2], "b": {"c": None, "d": "é"}},
        parse_document('{\n  "a": [1,\n    2],\n  "b": {"c": null, "d": "\\u00e9"}\n}\n'),
    )
    return unittest.end(env)

def _duplicate_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # Duplicate keys fail instead of resolving silently, naming key and line.
    asserts.equals(env, ["duplicate key \"a\" at line 2"], document_problems("a: 1\na: 2\n"))
    asserts.equals(env, ["duplicate key \"a\" at line 3"], document_problems("a:\n  b: 1\na:\n  c: 2\n"))
    asserts.equals(env, ["duplicate key \"b\" at line 3"], document_problems("a:\n  b: 1\n  b: 2\n"))
    asserts.equals(env, [], document_problems("a: 1\nb: 2\n"))
    return unittest.end(env)

def _duplicate_flow_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # Flow mappings fail on duplicates too, naming the line (M-12).
    asserts.equals(env, ["duplicate key \"x\" in flow mapping at line 1"], document_problems("a: {x: 1, x: 2}\n"))
    asserts.equals(env, ["duplicate key \"y\" in flow mapping at line 1"], document_problems("a: {x: {y: 1, y: 2}}\n"))
    asserts.equals(env, ["duplicate key \"a\" in flow mapping at line 1"], document_problems("{\"a\": 1, \"a\": 2}"))
    asserts.equals(env, [], document_problems("a: {x: 1, y: 2}\n"))
    return unittest.end(env)

def _duplicate_sequence_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # A `- key: value` item is a mapping, so its later entries check dups.
    asserts.equals(env, ["duplicate key \"k\" at line 2"], document_problems("- k: 1\n  k: 2\n"))
    asserts.equals(env, [], document_problems("- k: 1\n  n: 2\n"))
    return unittest.end(env)

def _bom_test_impl(ctx):
    env = unittest.begin(ctx)

    # A leading byte-order mark is stripped, as pub accepts it.
    asserts.equals(env, {"a": 1}, parse_document("\357\273\277a: 1\n"))
    asserts.equals(env, [], document_problems("\357\273\277a: 1\n"))
    asserts.equals(env, [], document_problems("\357\273\277a: 1\n", True))
    asserts.equals(
        env,
        ["duplicate key \"a\" at line 2"],
        document_problems("\357\273\277a: 1\na: 2\n"),
    )

    # A byte-order mark and CRLF line ends keep working (M-12).
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("\357\273\277a: 1\r\nb: 2\r\n"))
    asserts.equals(env, [], document_problems("\357\273\277a: 1\r\nb: 2\r\n", True))
    asserts.equals(env, {"t": ["a", "b"]}, parse_document("\357\273\277t:\r\n- a\r\n- b\r\n"))

    # Every leading mark strips, as pub accepts them at the stream start.
    asserts.equals(env, {"a": 1}, parse_document("\357\273\277\357\273\277a: 1\n"))

    # A bare mark line at column 0 is blank-like and skipped, as pub skips
    # it (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("a: 1\n\357\273\277\nb: 2\n"))
    asserts.equals(env, [], document_problems("a: 1\n\357\273\277\nb: 2\n", True))
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("a: 1\n\357\273\277# c\nb: 2\n"))
    asserts.equals(env, [], document_problems("a: 1\n\357\273\277# c\nb: 2\n", True))

    # A mark anywhere else is a problem naming its line, in strict and
    # lenient modes alike, as pub rejects it.
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a: 1\n  \357\273\277\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a: 1\n  \357\273\277\nb: 2\n", False),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a: 1\n  \357\273\277# c\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a: 1\n\357\273\277b: 2\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 1 is not supported"],
        document_problems("a: \357\273\2771\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 1 is not supported"],
        document_problems("a: 1\357\273\277\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("name: x\na\357\273\277b: 1\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 1 is not supported"],
        document_problems("a: [\357\273\277b]\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 1 is not supported"],
        document_problems("a: {\357\273\277k: v}\n", True),
    )

    # A folded continuation names its own line, not the head line.
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a: b\n  c\357\273\277d\n", True),
    )
    asserts.equals(
        env,
        ["byte-order mark at line 2 is not supported"],
        document_problems("a:\n  \357\273\277\nb: 2\n", True),
    )
    value, problems = document_value_and_problems("a: 1\n  \357\273\277\nb: 2\n", True)
    asserts.equals(env, {"a": None, "b": 2}, value)
    asserts.equals(env, 1, len(problems))

    # A spanning flow whose continuation carries a mark fails at the head
    # line, as the folded text parses as the head value; pub names the
    # continuation line instead, but either line fails closed.
    asserts.equals(
        env,
        ["byte-order mark at line 3 is not supported"],
        document_problems("name: x\ntags:\n  [a,\n    \357\273\277b]\n", True),
    )

    # Quoted, block-scalar and comment marks stay content, as pub reads them.
    asserts.equals(env, {"a": "x\357\273\277y"}, parse_document("a: \"x\357\273\277y\"\n"))
    asserts.equals(env, {"a": "x\357\273\277y"}, parse_document("a: 'x\357\273\277y'\n"))
    asserts.equals(env, {"a": "x\357\273\277y\n"}, parse_document("a: |\n  x\357\273\277y\n"))
    asserts.equals(env, {"a": "x \357\273\277y"}, parse_document("a: \"x\n  \357\273\277y\"\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1 # \357\273\277c\n"))
    asserts.equals(env, [], document_problems("a: 1 # \357\273\277c\n", True))
    return unittest.end(env)

def _strict_lines_test_impl(ctx):
    env = unittest.begin(ctx)

    # Lenient parsing skips what it cannot place; strict lines report it.
    asserts.equals(env, [], document_problems("a:\n    b: 1\n  c: 2\n"))
    asserts.equals(env, ["unreadable line 3: \"c: 2\""], document_problems("a:\n    b: 1\n  c: 2\n", True))
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported: \"? a\"", "explicit key at line 2 is not supported: \": 1\""],
        document_problems("? a\n: 1\nb: 2\n"),
    )
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported: \"? a\"", "explicit key at line 2 is not supported: \": 1\""],
        document_problems("? a\n: 1\nb: 2\n", True),
    )
    asserts.equals(env, [], document_problems("a: 1\nno colon here\n"))
    asserts.equals(env, ["unreadable line 2: \"no colon here\""], document_problems("a: 1\nno colon here\n", True))
    asserts.equals(env, [], document_problems("a: {x: 1}\nb: 2\n", True))
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"[1, 2\""],
        document_problems("a: [1, 2\nb: 2\n", True),
    )

    # Blank lines, comments, directives and markers are never problems.
    asserts.equals(
        env,
        [],
        document_problems("# lead\n---\na: 1\n\n# tail\n", True),
    )
    return unittest.end(env)

def _indentation_test_impl(ctx):
    env = unittest.begin(ctx)

    # Entries at a different indent from the first entry are problems (M-12).
    asserts.equals(
        env,
        ["unreadable line 3: \"c: 2\""],
        document_problems("a:\n    b: 1\n  c: 2\n", True),
    )
    value, problems = document_value_and_problems("a:\n    b: 1\n  c: 2\n", False)
    asserts.equals(env, {"a": {"b": 1}}, value)
    asserts.equals(env, [], problems)
    asserts.equals(env, {"a": {"b": 1}}, parse_document("a:\n\tb: 1\n"))
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("a: 1\r\nb: 2\r\n"))
    return unittest.end(env)

def _explicit_key_and_merge_test_impl(ctx):
    env = unittest.begin(ctx)

    # Explicit keys are not supported: they fail naming the line instead of
    # resolving silently, in strict and lenient modes alike.
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported: \"? a\"", "explicit key at line 2 is not supported: \": 1\""],
        document_problems("? a\n: 1\nb: 2\n", True),
    )
    value, problems = document_value_and_problems("? a\n: 1\nb: 2\n", False)
    asserts.equals(env, {"b": 2}, value)
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported: \"? a\"", "explicit key at line 2 is not supported: \": 1\""],
        problems,
    )
    asserts.equals(
        env,
        {"base": {"x": 1}, "child": {"<<": {"x": 1}, "y": 2}},
        parse_document("base: &b\n  x: 1\nchild:\n  <<: *b\n  y: 2\n"),
    )
    return unittest.end(env)

def _malformed_input_test_impl(ctx):
    env = unittest.begin(ctx)

    # Malformed input never crashes the build; problems carry the line (M-12).
    for text in [
        "[",
        "{",
        "a: [",
        "- :",
        "&",
        "*",
        "!",
        "a: !<",
        "a: 'unterminated",
        "a: \"\\u12\"",
        "a: \"\\U00110000\"",
        "a:\n\t- x",
        "- - -",
        "---\n---\n",
        "...",
        "%",
        "a: {b: }",
        "a: [1,,2]",
        "[1, 2] trailing",
        "{\"a\": 1",
    ]:
        document_value_and_problems(text, True)
        document_problems(text, True)
    asserts.true(env, True)
    return unittest.end(env)

def _unreadable_lines_test_impl(ctx):
    env = unittest.begin(ctx)

    # Every unreadable line is a problem naming its line; a dash in mapping
    # position is never a key (M-12).
    asserts.equals(
        env,
        ["duplicate key \"a\" at line 3"],
        document_problems("name: x\na: 1\na: 2\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 2: \"no colon here\""],
        document_problems("name: x\nno colon here\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 2: \"- stray\""],
        document_problems("name: x\n- stray\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 2: \"- key: v\""],
        document_problems("name: x\n- key: v\n", True),
    )
    value, problems = document_value_and_problems("name: x\n- stray\n", True)
    asserts.equals(env, {"name": "x"}, value)
    asserts.true(env, len(problems) == 1 and "line 2" in problems[0])
    return unittest.end(env)

def _docmarker_scalar_test_impl(ctx):
    env = unittest.begin(ctx)

    # An indented `---` inside a `|` block scalar is content, not a document
    # marker: only a column-0 `---` ends the document. The keys after the
    # scalar read exactly as in the marker-free twin.
    bad = "name: docmark\ndescription: |\n  line one\n  ---\n  line two\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  bar:\n    path: ../stubbar\n"
    good = "name: docmark\ndescription: |\n  line one\n  continued\n  line two\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  bar:\n    path: ../stubbar\n"
    bad_doc = parse_document(bad)
    good_doc = parse_document(good)
    asserts.equals(env, sorted(good_doc.keys()), sorted(bad_doc.keys()))
    asserts.equals(env, good_doc["environment"], bad_doc.get("environment"))
    asserts.equals(env, good_doc["dependencies"], bad_doc.get("dependencies"))
    asserts.equals(env, "line one\n---\nline two\n", bad_doc.get("description"))
    asserts.equals(env, [], document_problems(bad, True))

    # The same holds for a `>` scalar and for an indented `...`.
    folded_bad = parse_document("name: x\ndescription: >\n  line one\n  ---\n  line two\nenvironment:\n  sdk: ^3.0.0\n")
    asserts.equals(env, "line one --- line two\n", folded_bad.get("description"))
    asserts.equals(env, {"sdk": "^3.0.0"}, folded_bad.get("environment"))
    dots_bad = parse_document("name: x\ndescription: |\n  line one\n  ...\n  line two\nenvironment:\n  sdk: ^3.0.0\n")
    asserts.equals(env, "line one\n...\nline two\n", dots_bad.get("description"))
    asserts.equals(env, {"sdk": "^3.0.0"}, dots_bad.get("environment"))
    dots_folded = parse_document("name: x\ndescription: >\n  line one\n  ...\n  line two\nenvironment:\n  sdk: ^3.0.0\n")
    asserts.equals(env, "line one ... line two\n", dots_folded.get("description"))
    asserts.equals(env, {"sdk": "^3.0.0"}, dots_folded.get("environment"))
    return unittest.end(env)

def _indented_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    # An indented marker after a scalar is a continuation line, as pub folds
    # it (package:yaml 3.1.4 with the pinned SDK 3.13.5): `a: 1` with `  ---`
    # reads `1 ---`, leniently too.
    asserts.equals(env, {"a": "1 ---", "b": 2}, parse_document("a: 1\n  ---\nb: 2\n"))
    asserts.equals(env, [], document_problems("a: 1\n  ---\nb: 2\n", True))
    value, problems = document_value_and_problems("a: 1\n  ---\nb: 2\n", False)
    asserts.equals(env, {"a": "1 ---", "b": 2}, value)
    asserts.equals(env, [], problems)
    asserts.equals(env, {"a": "1 ...", "b": 2}, parse_document("a: 1\n  ...\nb: 2\n"))
    asserts.equals(env, [], document_problems("a: 1\n  ...\nb: 2\n", True))
    value, problems = document_value_and_problems("a: 1\n  ...\nb: 2\n", False)
    asserts.equals(env, {"a": "1 ...", "b": 2}, value)
    asserts.equals(env, [], problems)

    # The column-0 controls end the single document instead: a second `---`
    # and content after `...` fail naming the line, as pub rejects them.
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("a: 1\n---\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["content after document end (...) at line 3"],
        document_problems("a: 1\n...\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["second document marker (---) at line 2"],
        document_problems("a: 1\n---   \nb: 2\n", True),
    )
    return unittest.end(env)

def _multiline_flow_test_impl(ctx):
    env = unittest.begin(ctx)

    # A flow collection that starts on its key's line folds its deeper lines
    # and reads as one value when the folded text parses, as pub reads it.
    text = "name: multiflow\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  bar:\n    path: ../stubbar\nflutter:\n  assets:\n    - path: assets/x.png\n      flavors: [premium,\n        free]\n"
    value, problems = document_value_and_problems(text, True)
    asserts.equals(env, "multiflow", value["name"])
    asserts.equals(env, ["premium", "free"], value["flutter"]["assets"][0]["flavors"])
    asserts.equals(env, [], problems)
    value, problems = document_value_and_problems(text, False)
    asserts.equals(env, "multiflow", value["name"])
    asserts.equals(env, ["premium", "free"], value["flutter"]["assets"][0]["flavors"])
    asserts.equals(env, [], problems)

    # A flow value broken on one line stays an unreadable flow value.
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"[1, 2\""],
        document_problems("a: [1, 2\nb: 2\n", True),
    )
    return unittest.end(env)

def _explicit_key_error_test_impl(ctx):
    env = unittest.begin(ctx)

    # The finding's explicit-key form fails naming the `?` line and the form.
    text = "name: expl\nenvironment:\n  sdk: ^3.0.0\n? dependencies\n: {}\n"
    value, problems = document_value_and_problems(text, True)
    asserts.equals(env, "expl", value["name"])
    asserts.true(env, len(problems) >= 1)
    asserts.true(env, "line 4" in problems[0] and "not supported" in problems[0] and "explicit" in problems[0])
    value, problems = document_value_and_problems(text, False)
    asserts.equals(env, "expl", value["name"])
    asserts.true(env, len(problems) >= 1 and "not supported" in problems[0])
    return unittest.end(env)

def _block_fold_test_impl(ctx):
    env = unittest.begin(ctx)

    # A quoted scalar closes at any indent, even column 0, as pub reads it.
    asserts.equals(env, {"a": "foo bar"}, parse_document("a: \"foo\nbar\"\n"))
    asserts.equals(env, {"a": "foo bar"}, parse_document("a: 'foo\nbar'\n"))

    # A pending value that is only a marker reads the marker, as pub does.
    asserts.equals(env, {"a": "---"}, parse_document("a:\n  ---\n"))
    asserts.equals(env, [], document_problems("a:\n  ---\n", True))

    # Typed heads fold their continuations into strings, as pub reads them.
    asserts.equals(env, {"a": "1 two"}, parse_document("a: 1\n  two\n"))
    asserts.equals(env, [], document_problems("a: 1\n  two\n", True))
    asserts.equals(env, {"a": "true North"}, parse_document("a: true\n  North\n"))

    # A `- ` line without a colon folds into an open scalar at any depth, as
    # pub reads it, while one with a colon ends the scalar and fails.
    asserts.equals(env, {"a": "one - two"}, parse_document("a: one\n  - two\n"))
    asserts.equals(env, {"tags": ["alpha - beta - gamma"]}, parse_document("tags:\n  - alpha\n    - beta\n    - gamma\n"))
    asserts.equals(env, ["alpha - beta"], parse_document("- alpha\n  - beta\n"))
    asserts.equals(
        env,
        ["unreadable line 2: \"- 'k: v'\""],
        document_problems("notes: alpha\n  - 'k: v'\n", True),
    )

    # A `?` line without a colon folds into an open scalar outside a nested
    # mapping, as pub reads it; in a nested mapping it opens an explicit
    # key, which fails naming the line.
    asserts.equals(env, {"a": "one ? x"}, parse_document("a: one\n  ? x\n"))
    asserts.equals(env, {"a": "one ?"}, parse_document("a: one\n  ?\n"))
    asserts.equals(env, ["alpha ? x"], parse_document("- alpha\n  ? x\n"))
    value, problems = document_value_and_problems("outer:\n  b: 1\n  ? c\n", True)
    asserts.equals(env, {"outer": {"b": 1}}, value)
    asserts.equals(env, ["explicit key at line 3 is not supported: \"? c\""], problems)
    asserts.equals(
        env,
        ["unreadable line 3: \"?x\""],
        document_problems("outer:\n  b: alpha\n  ?x\n", True),
    )

    # An indented `%` line is content once the scalar is open, as pub folds
    # it, and a problem where pub rejects it.
    asserts.equals(env, {"a": "one %x"}, parse_document("a: one\n  %x\n"))
    asserts.equals(env, {"a": "1 %x"}, parse_document("a: 1\n  %x\n"))
    asserts.equals(env, ["unreadable line 2: \"%x\""], document_problems("a:\n  %x\n", True))
    asserts.equals(env, ["unreadable line 1: \"a: %x\""], document_problems("a: %x\n", True))
    value, problems = document_value_and_problems("a:\n%x\nb: 2\n", True)
    asserts.equals(env, {"a": None, "b": 2}, value)
    asserts.equals(env, ["unreadable line 2: \"%x\""], problems)

    # A comment-only or trailing-comment line ends a plain scalar, as pub
    # ends it; what follows is placed downstream.
    value, problems = document_value_and_problems("a: one\n  # c\n  two\nb: y\n", True)
    asserts.equals(env, {"a": "one", "b": "y"}, value)
    asserts.equals(env, ["unreadable line 3: \"two\""], problems)
    value, problems = document_value_and_problems("a: one\n  two # c\n  three\nb: y\n", True)
    asserts.equals(env, {"a": "one", "b": "y"}, value)
    asserts.equals(env, ["unreadable line 3: \"three\""], problems)
    asserts.equals(env, {"a": "one", "b": 2}, parse_document("a: \"one\"\n  # c\nb: 2\n"))
    asserts.equals(env, [], document_problems("a: \"one\"\n  # c\nb: 2\n", True))

    # Text after a same-line closing quote and a second quoted scalar fail
    # naming the head line, as pub rejects them.
    value, problems = document_value_and_problems("a: \"one\"\n  two\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 1: \"a: \\\"one\\\"\""], problems)
    value, problems = document_value_and_problems("a: \"x\"\"y\"\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 1: \"a: \\\"x\\\"\\\"y\\\"\""], problems)

    # A tab-indented continuation is a problem naming its line.
    asserts.equals(env, ["unreadable line 2: \"beta\""], document_problems("a:\n\tbeta\n", True))

    # An anchor spreads over the folded scalar, as pub reads it.
    asserts.equals(
        env,
        {"a": "one two", "b": "one two"},
        parse_document("a: &v one\n  two\nb: *v\n"),
    )

    # Inside quotes every deeper line is content, as pub reads it.
    asserts.equals(env, {"a": "foo %x bar"}, parse_document("a:\n  \"foo\n  %x\n  bar\"\n"))
    asserts.equals(env, ["foo # c bar"], parse_document("- \n  \"foo\n  # c\n  bar\"\n"))

    # A comment between a pending key and its sibling changes nothing.
    asserts.equals(env, {"a": None, "b": 2}, parse_document("a:\n# c\nb: 2\n"))
    return unittest.end(env)

def _float_overflow_test_impl(ctx):
    env = unittest.begin(ctx)

    # Floats past the double range read as infinity, as pub reads them
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5); finite values convert
    # exactly as before, and tiny values round to zero.
    parsed = parse_document(
        "a: 1e999\nb: -1e999\nc: 1e309\nd: 1e308\ne: 1e-400\nf: 0.0e999\n" +
        "g: 17976931348623158e292\nh: 17976931348623156e292\n" +
        "i: 1.7976931348623158e308\nj: !!float 1e999\n",
    )
    asserts.equals(env, float("inf"), parsed["a"])
    asserts.equals(env, float("-inf"), parsed["b"])
    asserts.equals(env, float("inf"), parsed["c"])
    asserts.equals(env, 1e308, parsed["d"])
    asserts.equals(env, 0.0, parsed["e"])
    asserts.equals(env, 0.0, parsed["f"])
    asserts.equals(env, float("inf"), parsed["g"])
    asserts.equals(env, 17976931348623156e292, parsed["h"])
    asserts.equals(env, float("inf"), parsed["i"])
    asserts.equals(env, float("inf"), parsed["j"])
    asserts.equals(env, [], document_problems("a: 1e999\n", True))
    return unittest.end(env)

_t0_test = unittest.make(_block_mapping_test_impl)
_t1_test = unittest.make(_block_sequence_test_impl)
_t2_test = unittest.make(_same_indent_sequence_test_impl)
_t3_test = unittest.make(_comment_test_impl)
_t4_test = unittest.make(_document_marker_test_impl)
_t5_test = unittest.make(_plain_scalar_type_test_impl)
_t6_test = unittest.make(_quoted_scalar_test_impl)
_t7_test = unittest.make(_flow_collection_test_impl)
_t8_test = unittest.make(_block_scalar_test_impl)
_t9_test = unittest.make(_plain_continuation_test_impl)
_t10_test = unittest.make(_anchor_alias_test_impl)
_t11_test = unittest.make(_tag_test_impl)
_t12_test = unittest.make(_collection_tag_test_impl)
_t13_test = unittest.make(_json_document_test_impl)
_t14_test = unittest.make(_duplicate_key_test_impl)
_t15_test = unittest.make(_indentation_test_impl)
_t16_test = unittest.make(_explicit_key_and_merge_test_impl)
_t17_test = unittest.make(_malformed_input_test_impl)
_t18_test = unittest.make(_duplicate_flow_key_test_impl)
_t19_test = unittest.make(_duplicate_sequence_key_test_impl)
_t20_test = unittest.make(_bom_test_impl)
_t21_test = unittest.make(_strict_lines_test_impl)
_t22_test = unittest.make(_compact_sequence_test_impl)
_t23_test = unittest.make(_folded_scalar_test_impl)
_t24_test = unittest.make(_unreadable_lines_test_impl)
_t25_test = unittest.make(_quoted_multiline_test_impl)
_t26_test = unittest.make(_docmarker_scalar_test_impl)
_t27_test = unittest.make(_indented_marker_test_impl)
_t28_test = unittest.make(_multiline_flow_test_impl)
_t29_test = unittest.make(_explicit_key_error_test_impl)
_t30_test = unittest.make(_flow_quote_start_test_impl)
_t31_test = unittest.make(_block_fold_test_impl)
_t32_test = unittest.make(_float_overflow_test_impl)
_t33_test = unittest.make(_flow_affix_key_test_impl)
_t34_test = unittest.make(_flow_affix_item_test_impl)
_t35_test = unittest.make(_flow_self_anchor_test_impl)

def yaml_subset_test_suite(name):
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
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
        _t18_test,
        _t19_test,
        _t20_test,
        _t21_test,
        _t22_test,
        _t23_test,
        _t24_test,
        _t25_test,
        _t26_test,
        _t27_test,
        _t28_test,
        _t29_test,
        _t30_test,
        _t31_test,
        _t32_test,
        _t33_test,
        _t34_test,
        _t35_test,
    )
