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

    # Text glued to a marker is an ordinary line, not a marker, as pub
    # reads `---x: 1` as a key: only `---` plus a space, a tab or the end
    # of the line marks, and glued `...` text fails once content came first.
    asserts.equals(env, {"a": 1, "---x": 1}, parse_document("a: 1\n---x: 1\n"))
    asserts.equals(env, {"a": 1, "---x": 1}, parse_document("---x: 1\na: 1\n"))
    asserts.equals(
        env,
        ["content after document end (...) at line 2"],
        document_problems("a: 1\n...x\n", True),
    )

    # Block content on the `---` line fails naming the line, while a scalar
    # or a flow collection there reads, as pub reads them (package:yaml
    # 3.1.4 with the pinned SDK 3.13.5).
    value, problems = document_value_and_problems("--- &x a: 1\n", True)
    asserts.equals(env, {"a": 1}, value)
    asserts.equals(env, ["Mapping values are not allowed here at line 1"], problems)
    asserts.equals(
        env,
        ["Mapping values are not allowed here at line 1"],
        document_problems("--- a: 1\n", True),
    )
    asserts.equals(
        env,
        ["Mapping values are not allowed here at line 1"],
        document_problems("--- a:\n", True),
    )
    asserts.equals(
        env,
        ["Mapping values are not allowed here at line 1"],
        document_problems("--- a: 1 # c\n", True),
    )
    asserts.equals(
        env,
        ["Block sequence entries are not allowed here at line 1"],
        document_problems("--- - a\n", True),
    )
    asserts.equals(
        env,
        ["Block sequence entries are not allowed here at line 1"],
        document_problems("--- -\n", True),
    )
    # An explicit key on the marker line fails twice, naming the line both
    # times: once for the marker position and once for the key itself.
    asserts.equals(
        env,
        ["Mapping keys are not allowed here at line 1", "explicit key at line 1 is not supported: \"? a\""],
        document_problems("--- ? a\n", True),
    )
    asserts.equals(
        env,
        ["Mapping values are not allowed here at line 2"],
        document_problems("%TAG !e! tag:a/\n--- a: 1\n", True),
    )
    asserts.equals(
        env,
        ["Block sequence entries are not allowed here at line 2"],
        document_problems("%TAG !e! tag:a/\n--- - a\n", True),
    )
    asserts.equals(env, "-foo", parse_document("--- -foo\n"))
    asserts.equals(env, "?foo", parse_document("--- ?foo\n"))
    asserts.equals(env, "a: 1", parse_document("--- 'a: 1'\n"))
    asserts.equals(env, [1, 2], parse_document("--- [1, 2]\n"))
    asserts.equals(env, {"a": "b"}, parse_document("--- {a: b}\n"))
    asserts.equals(env, "x", parse_document("--- !!str x\n"))
    asserts.equals(env, [1], parse_document("--- &x [1]\n"))
    asserts.equals(env, "a", parse_document("--- a # b: c\n"))
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
            "e": "1.10",
            "f": "# not a comment",
        },
        parse_document(
            "a: 'it''s'\n" +
            "b: \"x\\ty\\n\\\"q\\\" \\\\ \\/\"\n" +
            "c: \"\\x41\\u00e9\"\n" +
            "e: '1.10'\n" +
            "f: '# not a comment'\n",
        ),
    )

    # An unknown escape fails naming the line: pub rejects `d: "\q"`, which
    # an older revision read with the backslash kept.
    asserts.equals(
        env,
        ["unknown escape at line 1 is not supported"],
        document_problems("d: \"\\q\"\n", True),
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

    # A flow mapping value that is itself a pair fails, while a pair as a
    # sequence item and a quoted or glued colon read, as pub reads them
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    value, problems = document_value_and_problems("a: {x: y, p: q: r}\n", True)
    asserts.equals(env, {"a": {"x": "y", "p": None}}, value)
    asserts.equals(env, ["While parsing a flow mapping, expected ',' or '}' at line 1"], problems)
    asserts.equals(
        env,
        ["While parsing a flow mapping, expected ',' or '}' at line 1"],
        document_problems("a: {p: q: r}\n", True),
    )
    asserts.equals(
        env,
        ["While parsing a flow mapping, expected ',' or '}' at line 1"],
        document_problems("a: {p : q : r}\n", True),
    )
    asserts.equals(
        env,
        ["While parsing a flow mapping, expected ',' or '}' at line 1"],
        document_problems("a: {p: \"a\":1}\n", True),
    )
    asserts.equals(
        env,
        ["While parsing a flow mapping, expected ',' or '}' at line 1"],
        document_problems("a: {p: &x q: r}\n", True),
    )
    asserts.equals(
        env,
        ["While parsing a flow mapping, expected ',' or '}' at line 1"],
        document_problems("{p: q: r}\n", True),
    )
    asserts.equals(env, {"a": [{"p": "q"}]}, parse_document("a: [{p: q}]\n"))
    asserts.equals(env, {"a": {"p": "q:r"}}, parse_document("a: {p: q:r}\n"))
    asserts.equals(env, {"a": {"p": "q :r"}}, parse_document("a: {p: q :r}\n"))
    asserts.equals(env, {"a": {"p": "q: r"}}, parse_document("a: {p: \"q: r\"}\n"))
    asserts.equals(env, {"a": [{"b": "c"}]}, parse_document("a: [b: c]\n"))

    # A `#` where a flow token starts is a comment to the end of the line,
    # even glued to an opener or a comma, so the flow left open fails; a
    # `#` glued into a token stays content, as pub scans them (package:yaml
    # 3.1.4 with the pinned SDK 3.13.5). An unclosed flow names its opening
    # line, as every other unclosed flow does.
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"[x,#y]\""],
        document_problems("a: [x,#y]\n", True),
    )
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"{k: v,#c}\""],
        document_problems("a: {k: v,#c}\n", True),
    )
    asserts.equals(
        env,
        ["unreadable flow value at line 1: \"[#]\""],
        document_problems("a: [#]\n", True),
    )
    asserts.equals(env, {"a": ["x"]}, parse_document("a: [x, #y\n  ]\n"))
    asserts.equals(env, {"a": ["x"]}, parse_document("a: [#c\n  x]\n"))
    asserts.equals(env, {"a": ["x"]}, parse_document("a: [x]#c\n"))
    asserts.equals(env, {"a": ["#y"]}, parse_document("a: [\"#y\"]\n"))
    asserts.equals(env, {"a": ["x#y"]}, parse_document("a: [x#y]\n"))
    asserts.equals(env, {"a": {"k": "v#w"}}, parse_document("a: {k: v#w}\n"))
    asserts.equals(env, {"a": {"k:#v": None}}, parse_document("a: {k:#v}\n"))

    # A colon glued into a plain flow key stays content: the key runs to a
    # separating colon, a comma or the close, as pub scans them; a quoted
    # key still pairs at its glued colon, as pub reads it.
    asserts.equals(env, {"a": {"b:c": None}}, parse_document("a: {b:c}\n"))
    asserts.equals(env, {"a": {"k:v": "w"}}, parse_document("a: {k:v: w}\n"))
    asserts.equals(env, {"a": {"a": 1}}, parse_document("a: {\"a\":1}\n"))
    asserts.equals(env, {"a": {"http://x": 1}}, parse_document("a: {http://x: 1}\n"))
    asserts.equals(env, {"a": {}}, parse_document("a: { #c\n  }\n"))
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

    # A block scalar header never reads as a key, as pub rejects a block
    # scalar there: any key starting with `|` or `>` fails naming the line,
    # with any chomping or indentation indicators, glued text, or an anchor
    # prefix, in mappings, dash mappings and flows alike.
    value, problems = document_value_and_problems("| : v\n", True)
    asserts.equals(env, {None: "v"}, value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("| foo: bar\n", True)
    asserts.equals(env, {None: "bar"}, value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems(">+- : v\n", True)
    asserts.equals(env, {None: "v"}, value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("|x: v\n", True)
    asserts.equals(env, {None: "v"}, value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("&a | : v\n", True)
    asserts.equals(env, {None: "v"}, value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("- | : v\n", True)
    asserts.equals(env, [{None: "v"}], value)
    asserts.equals(env, ["block scalar as key at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("a: b\n| : v\n", True)
    asserts.equals(env, {"a": "b", None: "v"}, value)
    asserts.equals(env, ["block scalar as key at line 2 is not supported"], problems)
    value, problems = document_value_and_problems("a: {| : v}\n", True)
    asserts.equals(env, {None: "v"}, value["a"])
    asserts.equals(env, ["block scalar inside flow at line 1 is not supported"], problems)

    # A block scalar stays a value after `key:` and `- `, and a quoted `|`
    # stays a key, as pub reads them.
    asserts.equals(env, {"a": "foo\n"}, parse_document("a: |\n  foo\n"))
    asserts.equals(env, ["foo\n"], parse_document("- |\n  foo\n"))
    asserts.equals(env, {"|": "v"}, parse_document("'|': v\n"))
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
    # it. An anchor binds the key after it, which reads plainly; a tag word
    # reads the key after it as its string, as pub reads them.
    asserts.equals(env, {"k": {1: None}}, parse_document("k: {&v: 1}\n"))
    asserts.equals(env, {"k": [{1: None}, 1]}, parse_document("k: [{&v: 1}, *v:]\n"))
    asserts.equals(env, {"k": {"1": None}}, parse_document("k: {!foo: 1}\n"))
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
    asserts.equals(env, {"k": "1"}, value)
    asserts.equals(env, ["repeated tag at line 1 is not supported"], problems)

    # A tab ends an anchor word, as pub reads it.
    asserts.equals(env, {"k": "v"}, parse_document("k: &x\tv\n"))
    return unittest.end(env)

def _double_escape_test_impl(ctx):
    env = unittest.begin(ctx)

    # Double-quoted escapes decode as pub decodes them (package:yaml 3.1.4
    # with the pinned SDK 3.13.5): the YAML line and paragraph escapes, a
    # backslash with a space or tab, and hex and astral escapes.
    asserts.equals(env, {"d": json.decode('"\\u0085"')}, parse_document("d: \"\\N\"\n"))
    asserts.equals(env, {"d": json.decode('"\\u00a0"')}, parse_document("d: \"\\_\"\n"))
    asserts.equals(env, {"d": json.decode('"\\u2028"')}, parse_document("d: \"\\L\"\n"))
    asserts.equals(env, {"d": json.decode('"\\u2029"')}, parse_document("d: \"\\P\"\n"))
    asserts.equals(env, {"d": "a b"}, parse_document("d: \"a\\ b\"\n"))
    asserts.equals(env, {"d": "a\tb"}, parse_document("d: \"a\\\tb\"\n"))
    asserts.equals(env, {"d": "a" + json.decode('"\\u001b"') + "b"}, parse_document("d: \"a\\eb\"\n"))
    asserts.equals(env, {"d": "a\0b"}, parse_document("d: \"a\\0b\"\n"))
    asserts.equals(env, {"d": "AAA"}, parse_document("d: \"\\x41\\u0041\\U00000041\"\n"))
    asserts.equals(env, {"d": json.decode('"\\ud83d\\ude00"')}, parse_document("d: \"\\U0001F600\"\n"))
    asserts.equals(env, {"d": "abcdef"}, parse_document("d: \"abc\\\n   def\"\n"))
    asserts.equals(env, {"d": ["a\tb", json.decode('"\\u0085"')]}, parse_document("d: [\"a\\tb\", \"\\N\"]\n"))

    # An unknown escape fails naming the line, as pub rejects it.
    value, problems = document_value_and_problems("d: \"a\\qb\"\n", True)
    asserts.equals(env, {"d": None}, value)
    asserts.equals(env, ["unknown escape at line 1 is not supported"], problems)
    asserts.equals(
        env,
        ["unknown escape at line 1 is not supported"],
        document_problems("d: \"a\\X41\"\n", True),
    )
    asserts.equals(
        env,
        ["unknown escape at line 1 is not supported"],
        document_problems("d: \"a\\\302\240b\"\n", True),
    )
    asserts.equals(
        env,
        ["unknown escape at line 1 is not supported"],
        document_problems("d: [\"a\\qb\"]\n", True),
    )

    # A short or non-hex escape fails naming the line, as pub rejects it.
    asserts.equals(
        env,
        ["short x escape at line 1 is not supported"],
        document_problems("d: \"a\\x4\"\n", True),
    )
    asserts.equals(
        env,
        ["bad x escape at line 1 is not supported"],
        document_problems("d: \"a\\x4z\"\n", True),
    )
    asserts.equals(
        env,
        ["short u escape at line 1 is not supported"],
        document_problems("d: \"a\\u123\"\n", True),
    )
    asserts.equals(
        env,
        ["bad u escape at line 1 is not supported"],
        document_problems("d: \"a\\u00zz\"\n", True),
    )

    # A surrogate fails even in a well-formed pair, and a code point past
    # U+10FFFF fails, as pub rejects them.
    asserts.equals(
        env,
        ["bad u escape at line 1 is not supported"],
        document_problems("d: \"a\\ud800b\"\n", True),
    )
    asserts.equals(
        env,
        ["bad u escape at line 1 is not supported"],
        document_problems("d: \"a\\ud800\\udc00b\"\n", True),
    )
    asserts.equals(
        env,
        ["bad U escape at line 1 is not supported"],
        document_problems("d: \"a\\U0011FFFF\"\n", True),
    )
    asserts.equals(
        env,
        ["bad U escape at line 1 is not supported"],
        document_problems("d: \"a\\U0000D800\"\n", True),
    )
    return unittest.end(env)

def _tab_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    # A tab never indents: a line starting with a tab, and a content line
    # with a tab in its leading whitespace, fail naming the line, in strict
    # and lenient modes alike, as pub rejects them (package:yaml 3.1.4 with
    # the pinned SDK 3.13.5).
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("dependencies:\n\tbar: any\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a: 1\n\t\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a: 1\n\t# c\nb: 2\n"),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a: 1\n \t b: 2\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a:\n\t- x\n", True),
    )

    # After a tab-indented line fails, the orphaned content stays unreadable;
    # the tab problem comes first, so it names the failure.
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported", "unreadable line 3: \"x\""],
        document_problems("description: >\n\t\n  x\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 3 is not supported", "unreadable line 4: \"y\""],
        document_problems("description: |\n  x\n\t\n  y\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("d: foo\n\tbar\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("description: >\n\tx\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported", "unreadable line 3: \"bar\""],
        document_problems("d: foo\n\t\n  bar\n", True),
    )

    # Everywhere else a tab reads as pub reads it: after a dash or a colon,
    # inside a plain scalar, at a line's end, and in a key before its colon.
    asserts.equals(env, {"tags": ["x"]}, parse_document("tags:\n  -\tx\n"))
    asserts.equals(env, {"tags": ["a", "b"]}, parse_document("tags:\n-\ta\n-\tb\n"))
    asserts.equals(env, {"tags": ["x"]}, parse_document("tags:\n  - \tx\n"))
    asserts.equals(env, {"a": "x\ty"}, parse_document("a: x\ty\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\t\n"))
    asserts.equals(env, {"a": "b"}, parse_document("a:\tb\n"))
    asserts.equals(env, {"a": "b"}, parse_document("a\t: b\n"))
    asserts.equals(env, {"a": "b"}, parse_document("a :\tb\n"))
    asserts.equals(env, {"a": [1, 2]}, parse_document("a: [1,\n\t2]\n"))
    asserts.equals(env, {"a": [1, 2]}, parse_document("a: [1,\n\t\n  2]\n"))

    # A whitespace-only line starting with spaces stays blank, a deeper line
    # with spaces before its tab folds, and inside quotes every line stays
    # content, as pub reads them.
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("a: 1\n  \t\nb: 2\n"))
    asserts.equals(env, {"d": "foo bar"}, parse_document("d: foo\n  \tbar\n"))
    asserts.equals(env, {"d": "foo\nbar"}, parse_document("d: foo\n  \t\n  bar\n"))
    asserts.equals(env, {"d": "foo\nbar"}, parse_document("d: \"foo\n\t\n  bar\"\n"))
    asserts.equals(env, {"d": "foo bar"}, parse_document("d: \"foo\n\tbar\"\n"))
    asserts.equals(env, {"d": "foo bar"}, parse_document("d: \"foo\n  \tbar\"\n"))
    asserts.equals(env, {"description": "\t\nx\n"}, parse_document("description: >\n  \t\n  x\n"))
    asserts.equals(env, {"a": "x\n\t\ny\n"}, parse_document("a: |\n  x\n  \t\n  y\n"))
    asserts.equals(env, {"a": "x\n\t\ny\n"}, parse_document("a: >\n  x\n  \t\n  y\n"))
    asserts.equals(env, {"a": "x\n\n\t\ny\n"}, parse_document("a: >\n  x\n\n  \t\n  y\n"))

    # On the file's first line tabs and spaces before the first token are
    # separation, not indentation, as pub reads them (package:yaml 3.1.4
    # with the pinned SDK 3.13.5). A tab-indented first line still sets
    # the indent, so a column-0 second line ends the document there, and a
    # consumed `---`, a blank line or a comment first line keeps later tabs
    # failing, as pub rejects them.
    asserts.equals(env, {"a": "b"}, parse_document("\t# c\na: b\n"))
    asserts.equals(env, {"a": "b"}, parse_document("\ta: b\n"))
    asserts.equals(env, {"a": "b"}, parse_document(" \ta: b\n"))
    asserts.equals(env, {"a": "b"}, parse_document("\t\ta: b\n"))
    asserts.equals(env, ["x"], parse_document("\t- x\n"))
    asserts.equals(env, {"a": "b"}, parse_document("\t{a: b}\n"))
    asserts.equals(
        env,
        ["unreadable line 2: \"c: d\""],
        document_problems("\ta: b\nc: d\n", True),
    )
    asserts.equals(
        env,
        # A consumed `---` shifts later lines up one in block problems:
        # that numbering predates this change, as the marker line never
        # reaches the parser. This names the branch's line 1, physical 2.
        ["tab indentation at line 1 is not supported"],
        document_problems("---\n\ta: b\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("\n\ta: b\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("# c\n\ta: b\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("\ta: b\n\tc: d\n", True),
    )

    # A leading blank line with spaces past the content still fails, as pub
    # rejects it; only spaces count, so the tab past them is content.
    value, problems = document_value_and_problems("description: >\n   \t\n  x\n", True)
    asserts.equals(env, None, value["description"])
    asserts.true(env, len(problems) >= 1 and "line 3" in problems[0])
    return unittest.end(env)

def _tag_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: !!str 1.10\nb: !!int '12'\nc: !!float 3.5\nd: !!bool TRUE\n" +
        "e: !!null ~\nf: !!int '0o17'\ng: !!float '3e5'\n" +
        "h: !!null \"\"\ni: !str 3.0\nj: ! x\n",
    )
    asserts.equals(env, "1.10", parsed["a"])
    asserts.equals(env, 12, parsed["b"])
    asserts.equals(env, 3.5, parsed["c"])
    asserts.equals(env, True, parsed["d"])
    asserts.equals(env, None, parsed["e"])
    asserts.equals(env, 15, parsed["f"])
    asserts.equals(env, 300000.0, parsed["g"])
    asserts.equals(env, None, parsed["h"])
    asserts.equals(env, "3.0", parsed["i"])
    asserts.equals(env, "x", parsed["j"])

    # A local or non-specific tag reads a scalar as its string, as pub reads
    # it (package:yaml 3.1.4 with the pinned SDK 3.13.5): an older revision
    # resolved the scalar instead.
    asserts.equals(env, {"d": "3"}, parse_document("d: !foo 3\n"))
    asserts.equals(env, {"d": "3.0"}, parse_document("d: !foo 3.0\n"))
    asserts.equals(env, {"d": "+12"}, parse_document("d: !foo +12\n"))
    asserts.equals(env, {"d": "007"}, parse_document("d: !foo 007\n"))
    asserts.equals(env, {"d": "true"}, parse_document("d: !bar true\n"))
    asserts.equals(env, {"d": "null"}, parse_document("d: !foo null\n"))
    asserts.equals(env, {"d": "1"}, parse_document("d: ! 1\n"))
    asserts.equals(env, {"d": "a'b"}, parse_document("d: !foo 'a''b'\n"))
    asserts.equals(env, {"d": ["", "bar"]}, parse_document("d: [!foo,bar]\n"))
    asserts.equals(env, {"d": ["12"]}, parse_document("d: [!foo 12]\n"))
    asserts.equals(env, {"d": "12"}, parse_document("d: !foo\n  12\n"))
    asserts.equals(env, {"d": "12"}, parse_document("d: !foo 12 # c\n"))
    asserts.equals(env, {"d": {"1": "v"}}, parse_document("d: {!foo 1: v}\n"))
    asserts.equals(env, {"d": {"1": None}}, parse_document("d: {!foo: 1}\n"))
    asserts.equals(env, {"d": {"": None}}, parse_document("d: {!foo:1}\n"))
    asserts.equals(env, {"d": {"": 1}}, parse_document("d: {!foo : 1}\n"))
    asserts.equals(env, {"d": {"1": "v"}}, parse_document("d: {!!str 1: v}\n"))
    asserts.equals(env, {"d": {12: "v"}}, parse_document("d: {!!int '12': v}\n"))

    # A local tag rides a collection, as pub reads it.
    asserts.equals(env, {"d": [1, 2]}, parse_document("d: !foo [1, 2]\n"))
    asserts.equals(env, {"d": {"a": "b"}}, parse_document("d: !foo {a: b}\n"))
    asserts.equals(env, {"d": {"a": "b"}}, parse_document("d: !foo\n  a: b\n"))
    asserts.equals(env, {"d": [1]}, parse_document("d: !foo\n  - 1\n"))

    # A core-schema tag whose value does not resolve fails naming the line,
    # as pub rejects it (package:yaml 3.1.4 with the pinned SDK 3.13.5):
    # an older revision read the type's empty value instead.
    asserts.equals(
        env,
        ["Invalid int scalar at line 1"],
        document_problems("d: !!int abc\n", True),
    )
    value, problems = document_value_and_problems("d: !!int 1.5\n", True)
    asserts.equals(env, {"d": None}, value)
    asserts.equals(env, ["Invalid int scalar at line 1"], problems)
    asserts.equals(
        env,
        ["Invalid bool scalar at line 1"],
        document_problems("d: !!bool maybe\n", True),
    )
    asserts.equals(
        env,
        ["Invalid bool scalar at line 1"],
        document_problems("d: !!bool tRuE\n", True),
    )
    asserts.equals(env, {"d": True}, parse_document("d: !!bool 'TRUE'\n"))
    asserts.equals(
        env,
        ["Invalid bool scalar at line 1"],
        document_problems("d: !!bool yes\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float 3\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float abc\n", True),
    )
    asserts.equals(
        env,
        ["Invalid null scalar at line 1"],
        document_problems("d: !!null x\n", True),
    )

    # A scalar type tag on a collection fails naming the kind, and a `!!seq`
    # or `!!map` tag off its kind fails as an undefined tag, as pub reports
    # them; any other `!!` tag is an undefined tag too. The value still reads
    # untagged, so parsing continues past it.
    value, problems = document_value_and_problems("d: !!str [a]\n", True)
    asserts.equals(env, {"d": ["a"]}, value)
    asserts.equals(env, ["Invalid tag for sequence at line 1"], problems)
    asserts.equals(
        env,
        ["Invalid tag for mapping at line 1"],
        document_problems("d: !!str {a: b}\n", True),
    )
    value, problems = document_value_and_problems("d: !!seq 3\n", True)
    asserts.equals(env, {"d": 3}, value)
    asserts.equals(env, ["Undefined tag: tag:yaml.org,2002:seq at line 1"], problems)
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002:map at line 1"],
        document_problems("d: !!map x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002:binary at line 1"],
        document_problems("d: !!binary x\n", True),
    )

    # A named handle and a verbatim tag fail as undefined handles, as pub
    # rejects them: an older revision resolved known verbatim tags instead.
    value, problems = document_value_and_problems("d: !e!foo x\n", True)
    asserts.equals(env, {"d": "x"}, value)
    asserts.equals(env, ["Undefined tag handle at line 1"], problems)
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<tag:yaml.org,2002:str> x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<tag:yaml.org,2002:foo> x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<tag:yaml.org,2002:str\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<foo\n", True),
    )
    return unittest.end(env)

def _tag_remainder_test_impl(ctx):
    env = unittest.begin(ctx)

    # A one-character text under `!!float` fails naming the line: pub
    # crashes on it (a RangeError), so it rejects the document, while two
    # characters read (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    value, problems = document_value_and_problems("d: !!float 1\n", True)
    asserts.equals(env, {"d": None}, value)
    asserts.equals(env, ["Invalid float scalar at line 1"], problems)
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float 0\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float 9\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float \"1\"\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("k: !!float\n  1\n", True),
    )
    asserts.equals(
        env,
        ["Invalid float scalar at line 1"],
        document_problems("d: !!float 1\n", False),
    )
    asserts.equals(env, {"d": 0.0}, parse_document("d: !!float 00\n"))
    asserts.equals(env, {"d": 12.0}, parse_document("d: !!float 12\n"))

    # `!!timestamp` on a scalar fails as an undefined tag, as pub reports
    # it; any other `!!` tag already behaved this way.
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002:timestamp at line 1"],
        document_problems("d: !!timestamp x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002:timestamp at line 1"],
        document_problems("d: !!timestamp 2001-02-03\n", True),
    )

    # A verbatim tag with a space inside fails, an empty named handle fails,
    # and dropped named-handle, verbatim and `!!float` tags fail, as pub
    # rejects them all.
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<a b> x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !e! x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !e!foo\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<foo>\n", True),
    )
    asserts.equals(
        env,
        ["tag !!float with no value at line 1 is not supported"],
        document_problems("d: !!float\n", True),
    )

    # A mid-word handle and a `>` inside a verbatim tag fail as undefined
    # handles, while a dropped local or non-specific tag reads an empty
    # scalar, as pub reads them.
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !foo!bar x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("d: !<a>b> x\n", True),
    )
    asserts.equals(env, {"d": ""}, parse_document("d: !foo\n"))
    asserts.equals(env, {"d": ""}, parse_document("d: !\n"))

    # A `%TAG`-remapped `!!` or `!name!` handle fails at its use, even for
    # the standard prefix, while a `!` remap changes no local tag and an
    # unremapped `!!` still reads, as pub reads them (package:yaml 3.1.4
    # with the pinned SDK 3.13.5).
    value, problems = document_value_and_problems("%TAG !! tag:example.com/\n--- !!str x\n", True)
    asserts.equals(env, "x", value)
    asserts.equals(env, ["Undefined tag: tag:example.com/str at line 2"], problems)
    asserts.equals(
        env,
        ["Undefined tag: tag:a/foo at line 2"],
        document_problems("%TAG !e! tag:a/\n--- !e!foo bar\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002/str at line 2"],
        document_problems("%TAG !e! tag:yaml.org,2002/\n--- !e!str x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002/str at line 2"],
        document_problems("%TAG !! tag:yaml.org,2002/\n--- !!str x\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:x/str at line 2"],
        document_problems("%TAG !! tag:x/\n--- [!!str a]\n", True),
    )
    asserts.equals(
        env,
        ["Undefined tag: tag:x/str at line 2"],
        document_problems("%TAG !! tag:x/\n--- !!str\n", True),
    )
    asserts.equals(env, "x", parse_document("%TAG !e! tag:a/\n--- !!str x\n"))
    asserts.equals(env, "bar", parse_document("%TAG ! tag:x/\n--- !foo bar\n"))

    # A colon prefix resolves through the handle: a standard resolution
    # reads as its `!!` tag, while any other fails at the use line, as pub
    # reads them.
    value, problems = document_value_and_problems("%TAG !! tag:example.com:\n---\na: !!int 1\n", True)
    asserts.equals(env, {"a": 1}, value)
    asserts.equals(env, ["Undefined tag: tag:example.com:int at line 3"], problems)
    asserts.equals(env, {"a": "1"}, parse_document("%TAG !y! tag:yaml.org,2002:\n---\na: !y!str 1\n"))
    return unittest.end(env)

def _collection_tag_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": [1, 2], "b": {"x": 1}},
        parse_document("a: !!seq [1, 2]\nb: !!map {x: 1}\n"),
    )

    # A `!!seq` or `!!map` tag off its kind fails as an undefined tag, as pub
    # reports it; an older revision read an empty collection instead.
    value, problems = document_value_and_problems("c: !!seq 3\nd: !!map []\n", True)
    asserts.equals(env, {"c": 3, "d": []}, value)
    asserts.equals(
        env,
        ["Undefined tag: tag:yaml.org,2002:seq at line 1", "Invalid tag for sequence at line 2"],
        problems,
    )

    # A pending `!!` tag converts a next-line scalar, and a pending verbatim
    # tag fails, as pub reads them; a pending local tag reads the scalar as
    # its string and rides a collection.
    asserts.equals(env, {"k": 12}, parse_document("k: !!int\n  12\n"))
    asserts.equals(env, {"k": "12"}, parse_document("k: !foo\n  12\n"))
    asserts.equals(env, {"k": [1]}, parse_document("k: !foo\n  - 1\n"))
    asserts.equals(
        env,
        ["Undefined tag handle at line 1"],
        document_problems("k: !<tag:yaml.org,2002:int>\n  12\n", True),
    )
    asserts.equals(
        env,
        ["Invalid bool scalar at line 1"],
        document_problems("k: !!bool\n  yes\n", True),
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

    # A tab-indented key fails naming the line, in strict and lenient modes
    # alike: pub rejects the tab, which an older revision counted as one
    # column of indentation.
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a:\n\tb: 1\n", True),
    )
    asserts.equals(
        env,
        ["tab indentation at line 2 is not supported"],
        document_problems("a:\n\tb: 1\n"),
    )
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

    # A `- key: value` item's later keys sit at the key's own column, and
    # its same-line value folds only past that column, as pub ends it
    # there: a `- ` or plain continuation at the key's column or shallower
    # fails naming its line, as pub rejects it.
    value, problems = document_value_and_problems("- a: 1\n  - x\n", True)
    asserts.equals(env, [{"a": 1}], value)
    asserts.equals(env, ["unreadable line 2: \"- x\""], problems)
    value, problems = document_value_and_problems("- a: 1\n - x\n", True)
    asserts.equals(env, [{"a": 1}], value)
    asserts.equals(env, ["unreadable line 2: \"- x\""], problems)
    value, problems = document_value_and_problems("- a: 1\n b\n", True)
    asserts.equals(env, [{"a": 1}], value)
    asserts.equals(env, ["unreadable line 2: \"b\""], problems)
    value, problems = document_value_and_problems("- a: 1\n  b\n", True)
    asserts.equals(env, [{"a": 1}], value)
    asserts.equals(env, ["unreadable line 2: \"b\""], problems)
    value, problems = document_value_and_problems("- a: 1\n   b: 2\n", True)
    asserts.equals(env, [{"a": 1}], value)
    asserts.equals(env, ["unreadable line 2: \"b: 2\""], problems)
    value, problems = document_value_and_problems("key:\n- a: 1\n  - x\n", True)
    asserts.equals(env, {"key": [{"a": 1}]}, value)
    asserts.equals(env, ["unreadable line 3: \"- x\""], problems)

    # Deeper continuations without a colon still fold into the value, and
    # keys at the key's column still read, as pub reads them.
    asserts.equals(env, [{"a": 1, "b": 2}], parse_document("- a: 1\n  b: 2\n"))
    asserts.equals(env, [{"a": "1 - x"}], parse_document("- a: 1\n   - x\n"))
    asserts.equals(env, [{"a": "1 b"}], parse_document("- a: 1\n   b\n"))
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

    # Text glued after a quoted scalar's closing quote fails naming the
    # line, as pub rejects it: the scalar ends at its first closing quote,
    # with `''` and `\"` as escapes, and only the quote itself may end it.
    value, problems = document_value_and_problems("a: 'x'y'\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["trailing text after quoted scalar at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("a: \"x\"y\"\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["trailing text after quoted scalar at line 1 is not supported"], problems)
    value, problems = document_value_and_problems("a: 'x' y\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 1: \"a: 'x' y\""], problems)
    value, problems = document_value_and_problems("a: 'x': y\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 1: \"a: 'x': y\""], problems)
    value, problems = document_value_and_problems("a: 'x'\ty\n", True)
    asserts.equals(env, None, value["a"])
    asserts.true(env, len(problems) == 1 and "line 1" in problems[0])
    value, problems = document_value_and_problems("a: 'x' 'y'\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 1: \"a: 'x' 'y'\""], problems)

    # The same trailer after a multi-line closing quote fails naming the
    # closing line, as pub rejects it there.
    value, problems = document_value_and_problems("a: 'x\n  y' z\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y' z\""], problems)
    value, problems = document_value_and_problems("a: \"x\n  y\"z\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y\\\"z\""], problems)
    value, problems = document_value_and_problems("a: 'x\n  y': z\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y': z\""], problems)
    value, problems = document_value_and_problems("a: 'x\n  y'z'\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y'z'\""], problems)
    value, problems = document_value_and_problems("a: 'x\n  y' %x\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y' %x\""], problems)
    value, problems = document_value_and_problems("a: 'x\n  y' 'z'\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable line 2: \"y' 'z'\""], problems)

    # A quoted key with glued text fails naming the line, as pub rejects
    # it, while a spaced colon still pairs the key, as pub reads it.
    value, problems = document_value_and_problems("'k'x: v\n", True)
    asserts.equals(env, {None: "v"}, value)
    asserts.equals(env, ["trailing text after quoted scalar at line 1 is not supported"], problems)
    asserts.equals(env, {"k": "v"}, parse_document("'k': v\n"))
    asserts.equals(env, {"k": "v"}, parse_document("'k' : v\n"))

    # A flow value glued after a closing quote fails naming the line, as
    # pub rejects it.
    value, problems = document_value_and_problems("a: ['x'y']\n", True)
    asserts.equals(env, None, value["a"])
    asserts.equals(env, ["unreadable flow value at line 1: \"['x'y']\""], problems)

    # What pub reads around a closing quote keeps reading: a comment after
    # it, an escaped quote inside it, and a multi-line close with a comment
    # or nothing after it.
    asserts.equals(env, {"a": "x"}, parse_document("a: 'x' # c\n"))
    asserts.equals(env, {"a": "x"}, parse_document("a: \"x\" # c\n"))
    asserts.equals(env, {"a": "x'y"}, parse_document("a: 'x''y'\n"))
    asserts.equals(env, {"a": "x\"y"}, parse_document("a: \"x\\\"y\"\n"))
    asserts.equals(env, {"a": "x y"}, parse_document("a: 'x\n  y'\n"))
    asserts.equals(env, {"a": "x y"}, parse_document("a: 'x\n  y' # c\n"))

    # A tab-indented continuation is a problem naming its line, in strict
    # and lenient modes alike, as pub rejects it.
    asserts.equals(env, ["tab indentation at line 2 is not supported"], document_problems("a:\n\tbeta\n", True))
    asserts.equals(env, ["tab indentation at line 2 is not supported"], document_problems("a:\n\tbeta\n"))

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

def _refused_character_test_impl(ctx):
    env = unittest.begin(ctx)

    # A plain scalar starting with `@` or a backtick fails naming the line:
    # pub rejects `d: @x`, which an older revision read as "@x"
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    asserts.equals(
        env,
        ["reserved indicator at line 1 is not supported"],
        document_problems("d: @x\n", True),
    )
    asserts.equals(
        env,
        ["reserved indicator at line 1 is not supported"],
        document_problems("d: `x\n", True),
    )
    asserts.equals(
        env,
        ["reserved indicator at line 1 is not supported"],
        document_problems("d: @\n", True),
    )
    asserts.equals(
        env,
        ["reserved indicator at line 1 is not supported"],
        document_problems("@k: 1\n", True),
    )
    asserts.equals(
        env,
        ["reserved indicator at line 2 is not supported"],
        document_problems("tags:\n  - @x\n", True),
    )
    asserts.equals(
        env,
        ["reserved indicator at line 1 is not supported"],
        document_problems("d: [@x]\n", True),
    )

    # A control character or DEL anywhere in a plain scalar fails naming the
    # line, as pub refuses them; a tab inside one stays content, as pub
    # reads it.
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: a\0b\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: a\013b\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: a\014b\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: a\177b\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("a\0b: 1\n", True),
    )
    asserts.equals(env, {"d": "a\tb"}, parse_document("d: a\tb\n"))

    # Quoted scalars keep `@`, backticks, tabs and control characters as
    # content, as pub reads them.
    asserts.equals(env, {"d": "@x"}, parse_document("d: \"@x\"\n"))
    asserts.equals(env, {"d": "@x"}, parse_document("d: '@x'\n"))
    asserts.equals(env, {"d": "`x"}, parse_document("d: '`x'\n"))
    asserts.equals(env, {"d": "a\0b"}, parse_document("d: \"a\0b\"\n"))
    asserts.equals(env, {"d": "a\0b"}, parse_document("d: 'a\0b'\n"))
    asserts.equals(env, {"d": "a\013b"}, parse_document("d: \"a\013b\"\n"))

    # An `@` or backtick past the start, and a bare `&` or `*` aside, read
    # or fail as pub reads them: mid-scalar marks stay content while a bare
    # anchor or alias fails naming the line.
    asserts.equals(env, {"d": "a@b"}, parse_document("d: a@b\n"))
    asserts.equals(env, {"d": "a`b"}, parse_document("d: a`b\n"))
    asserts.equals(
        env,
        ["empty anchor at line 1 is not supported"],
        document_problems("d: &\n", True),
    )
    asserts.equals(
        env,
        ["empty alias at line 1 is not supported"],
        document_problems("d: *\n", True),
    )
    return unittest.end(env)

def _flow_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    # A block entry inside a flow fails naming the line: pub rejects
    # `key: [- a]`, which an older revision read as ["- a"]
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5).
    for doc in [
        "key: [- a]\n",
        "key: [a, - b]\n",
        "key: {a: - b}\n",
        "key: [-]\n",
        "key: [-, a]\n",
        "key: [ - a ]\n",
        "key: [a: - b]\n",
        "key: { - : 1}\n",
        "key: {-, a}\n",
        "key: [a: -: 1]\n",
        "key: [a: ? b]\n",
        "key: [a: ?]\n",
        "key: {a: ? b}\n",
        "key: {a: ?}\n",
        "key: [&x - a]\n",
        "key: [!foo - a]\n",
        "key: [a: &x - b]\n",
        "key: [a: &x -: 1]\n",
        "key: {a: &x -: 1}\n",
        "key: [: - a]\n",
        "key: [: -: 1]\n",
        "key: [: ? b]\n",
        "key: [? - a : b]\n",
        "key: {? - a : b}\n",
        "key: [&x ? b]\n",
        "key: [a: &x ? b]\n",
    ]:
        asserts.equals(
            env,
            ["block entry inside flow at line 1 is not supported"],
            document_problems(doc, True),
        )

    # Glued dashes, `-: ` pairs as items, `?` keys and `-:x` without a space
    # read as pub reads them.
    asserts.equals(env, {"key": ["-a"]}, parse_document("key: [-a]\n"))
    asserts.equals(env, {"key": ["a", "-b"]}, parse_document("key: [a, -b]\n"))
    asserts.equals(env, {"key": [{"-": 1}]}, parse_document("key: [-: 1]\n"))
    asserts.equals(env, {"key": {"-": 1}}, parse_document("key: {-: 1}\n"))
    asserts.equals(env, {"key": [{"a": "-b"}]}, parse_document("key: [a: -b]\n"))
    asserts.equals(env, {"key": [{"a": "-:x"}]}, parse_document("key: [a: -:x]\n"))
    asserts.equals(env, {"key": {"a": "-:x"}}, parse_document("key: {a: -:x}\n"))
    asserts.equals(env, {"key": {"a": "?b"}}, parse_document("key: {a: ?b}\n"))
    asserts.equals(env, {"key": [{"a": "?b"}]}, parse_document("key: [a: ?b]\n"))
    asserts.equals(env, {"key": [{"-": 1}]}, parse_document("key: [&x -: 1]\n"))
    asserts.equals(env, {"key": [{"-": 1}]}, parse_document("key: [!foo -: 1]\n"))
    asserts.equals(env, {"key": ["?a"]}, parse_document("key: [?a]\n"))
    asserts.equals(env, {"key": ["?a"]}, parse_document("key: [&x ?a]\n"))
    asserts.equals(env, {"key": [{"a": "?b"}]}, parse_document("key: [a: &x ?b]\n"))
    return unittest.end(env)

def _number_shape_test_impl(ctx):
    env = unittest.begin(ctx)

    # Numbers read as pub reads them (package:yaml 3.1.4 with the pinned SDK
    # 3.13.5): a decimal past the int64 range reads as a double, overflowing
    # to infinity, while one with a `_` separator past the range stays a
    # string.
    asserts.equals(env, 9223372036854775807, parse_document("key: 9223372036854775807\n")["key"])
    value = parse_document("key: 9223372036854775808\n")["key"]
    asserts.equals(env, "float", type(value))
    asserts.equals(env, 9.223372036854776e18, value)
    value = parse_document("key: -9223372036854775809\n")["key"]
    asserts.equals(env, "float", type(value))
    asserts.equals(env, -9.223372036854776e18, value)
    value = parse_document("key: " + "9" * 400 + "\n")["key"]
    asserts.equals(env, float("inf"), value)
    asserts.equals(env, "9_9" * 200, parse_document("key: " + "9_9" * 200 + "\n")["key"])

    # A hex value wraps modulo 2^64 into the signed range and past 2^64-1
    # stays a string, while an octal past 2^63-1 stays a string, as pub reads
    # them; a hex or octal with a `_` separator stays a string too. An older
    # revision read all of these unbounded.
    asserts.equals(env, -9223372036854775808, parse_document("key: 0x8000000000000000\n")["key"])
    asserts.equals(env, -1, parse_document("key: 0xFFFFFFFFFFFFFFFF\n")["key"])
    asserts.equals(env, 1, parse_document("key: 0x00000000000000000000000001\n")["key"])
    asserts.equals(env, 9223372036854775807, parse_document("key: 0o777777777777777777777\n")["key"])
    asserts.equals(env, "0x10000000000000000", parse_document("key: 0x10000000000000000\n")["key"])
    asserts.equals(env, "0o2000000000000000000000", parse_document("key: 0o2000000000000000000000\n")["key"])
    asserts.equals(env, "0x1_0", parse_document("key: 0x1_0\n")["key"])
    asserts.equals(env, "0o1_7", parse_document("key: 0o1_7\n")["key"])

    # Only the exact `.inf` and `.nan` casings read, as pub reads them; other
    # casings, which an older revision lowercased into infinities, stay
    # strings now.
    asserts.equals(env, float("inf"), parse_document("key: .Inf\n")["key"])
    asserts.equals(env, float("inf"), parse_document("key: +.INF\n")["key"])
    asserts.equals(env, float("-inf"), parse_document("key: -.Inf\n")["key"])
    asserts.equals(env, float("inf"), parse_document("key: .INF\n")["key"])
    asserts.equals(env, float("nan"), parse_document("key: .NaN\n")["key"])
    asserts.equals(env, ".iNf", parse_document("key: .iNf\n")["key"])
    asserts.equals(env, "+.nan", parse_document("key: +.nan\n")["key"])
    asserts.equals(env, "-.nan", parse_document("key: -.nan\n")["key"])

    # `1.e5` and `.5e5` read as doubles, as pub reads them; an older revision
    # read them as strings.
    asserts.equals(env, 100000.0, parse_document("key: 1.e5\n")["key"])
    asserts.equals(env, 50000.0, parse_document("key: .5e5\n")["key"])
    asserts.equals(env, 5000.0, parse_document("key: 5.e3\n")["key"])
    asserts.equals(env, 50000.0, parse_document("key: +.5e5\n")["key"])
    asserts.equals(env, "1_0e3", parse_document("key: 1_0e3\n")["key"])
    asserts.equals(env, "0x1_0", parse_document("key: 0x1_0\n")["key"])

    # Out-of-scope scalar typing stays as read before: `1_000`, `1_2_3`,
    # `.5`, `1.`, `0X1F` and `0O17` keep their older readings. A dotted
    # decimal with a `_` separator keeps its older reading too.
    asserts.equals(env, 1000, parse_document("key: 1_000\n")["key"])
    asserts.equals(env, 123, parse_document("key: 1_2_3\n")["key"])
    asserts.equals(env, ".5", parse_document("key: .5\n")["key"])
    asserts.equals(env, "1.", parse_document("key: 1.\n")["key"])
    asserts.equals(env, 31, parse_document("key: 0X1F\n")["key"])
    asserts.equals(env, 15, parse_document("key: 0O17\n")["key"])
    asserts.equals(env, 10.5, parse_document("key: 1_0.5\n")["key"])

    # `!!int` converts through the scalar text, as pub parses it: plain and
    # padded decimals, lowercase hex and octal read, while a `_` separator,
    # an uppercase prefix, an over-range value and leading padding fail
    # naming the line, as pub rejects them.
    asserts.equals(env, {"key": 12}, parse_document("key: !!int 12\n"))
    asserts.equals(env, {"key": 12}, parse_document("key: !!int '12'\n"))
    asserts.equals(env, {"key": 12}, parse_document("key: !!int '12 '\n"))
    asserts.equals(env, {"key": 1}, parse_document("key: !!int '1 '\n"))
    asserts.equals(env, {"key": 12}, parse_document("key: !!int '+12'\n"))
    asserts.equals(env, {"key": 7}, parse_document("key: !!int '007'\n"))
    asserts.equals(env, {"key": 16}, parse_document("key: !!int 0x10\n"))
    asserts.equals(env, {"key": 16}, parse_document("key: !!int '0x10 '\n"))
    asserts.equals(env, {"key": 15}, parse_document("key: !!int '0o17 '\n"))
    asserts.equals(env, {"key": -1}, parse_document("key: !!int 0xFFFFFFFFFFFFFFFF\n"))
    asserts.equals(env, {"key": 9223372036854775807}, parse_document("key: !!int 0o777777777777777777777\n"))
    asserts.equals(env, {"key": 12}, parse_document("key: !!int\n  12\n"))
    for doc in [
        "key: !!int 1_000\n",
        "key: !!int 0X1F\n",
        "key: !!int 0O17\n",
        "key: !!int 0x1_0\n",
        "key: !!int 0o1_7\n",
        "key: !!int 0x10000000000000000\n",
        "key: !!int 0o2000000000000000000000\n",
        "key: !!int 9223372036854775808\n",
        "key: !!int ' 12'\n",
        "key: !!int '0x'\n",
        "key: !!int ''\n",
    ]:
        asserts.equals(
            env,
            ["Invalid int scalar at line 1"],
            document_problems(doc, True),
        )

    # `!!float` converts through the scalar text too: int shapes, `1.`, `.5`
    # and padded scalars read, while `0x`/`0o` shapes, a `_` separator, a
    # padded infinity and a lone character fail naming the line, as pub reads
    # them. An older revision failed the int shapes.
    for doc, want in [
        ("key: !!float 12\n", 12.0),
        ("key: !!float +12\n", 12.0),
        ("key: !!float 007\n", 7.0),
        ("key: !!float '1.'\n", 1.0),
        ("key: !!float '.5'\n", 0.5),
        ("key: !!float '+.5'\n", 0.5),
        ("key: !!float '1.e5'\n", 100000.0),
        ("key: !!float '.5e5'\n", 50000.0),
        ("key: !!float '5.e3'\n", 5000.0),
        ("key: !!float '12 '\n", 12.0),
        ("key: !!float '12\t'\n", 12.0),
        ("key: !!float '.5\t'\n", 0.5),
        ("key: !!float '1e3 '\n", 1000.0),
        ("key: !!float '+.inf'\n", float("inf")),
        ("key: !!float '-.Inf'\n", float("-inf")),
        ("key: !!float '.Inf'\n", float("inf")),
    ]:
        value = parse_document(doc)["key"]
        asserts.equals(env, "float", type(value))
        asserts.equals(env, want, value)
    asserts.equals(env, float("nan"), parse_document("key: !!float '.NaN'\n")["key"])
    asserts.equals(env, "float", type(parse_document("key: !!float '.NaN'\n")["key"]))
    value = parse_document("key: !!float\n  12\n")["key"]
    asserts.equals(env, "float", type(value))
    asserts.equals(env, 12.0, value)
    for doc in [
        "key: !!float 0x10\n",
        "key: !!float 0o17\n",
        "key: !!float 1_000\n",
        "key: !!float '.inf '\n",
        "key: !!float '+.inf '\n",
        "key: !!float '.nan '\n",
        "key: !!float 5\n",
        "key: !!float '5'\n",
        "key: !!float ''\n",
    ]:
        asserts.equals(
            env,
            ["Invalid float scalar at line 1"],
            document_problems(doc, True),
        )
    return unittest.end(env)

def _block_structure_test_impl(ctx):
    env = unittest.begin(ctx)

    # A `: ` inside a plain same-line value fails naming the line, as pub
    # rejects a mapping value inside a plain scalar (package:yaml 3.1.4 with
    # the pinned SDK 3.13.5); a trailing colon and a leading `:: ` fail the
    # same way, even past mid-scalar quotes or brackets, in strict and
    # lenient modes alike.
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: a: b\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: a: b\n"),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: a:\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: :: foo\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: a \"x: y\" b\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: a [b: c]\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("description: x {a: b}\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("key: -a: b\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("key: ?x: y\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("key: -: 1\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 1 is not supported"],
        document_problems("key:\ta: b\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 2 is not supported"],
        document_problems("dependencies:\n - a: b: c\n", True),
    )
    asserts.equals(
        env,
        ["mapping value at line 2 is not supported"],
        document_problems("dependencies:\n - a: -: 1\n", True),
    )

    # A `- ` entry where a value starts fails naming the line, as pub
    # rejects a block sequence there, even under an anchor or a tab, in
    # strict and lenient modes alike.
    asserts.equals(
        env,
        ["block sequence entry at line 1 is not supported"],
        document_problems("dependencies: - a\n", True),
    )
    asserts.equals(
        env,
        ["block sequence entry at line 1 is not supported"],
        document_problems("dependencies: - a\n"),
    )
    asserts.equals(
        env,
        ["block sequence entry at line 1 is not supported"],
        document_problems("dependencies: &x - a\n", True),
    )
    asserts.equals(
        env,
        ["block sequence entry at line 1 is not supported"],
        document_problems("key: - # x\n", True),
    )
    asserts.equals(
        env,
        ["block sequence entry at line 1 is not supported"],
        document_problems("tags:\t- x\n", True),
    )
    asserts.equals(
        env,
        ["block sequence entry at line 2 is not supported"],
        document_problems("dependencies:\n - a: - b\n", True),
    )

    # A `? ` marker where a value starts fails naming the line, as pub
    # rejects an explicit key there, in strict and lenient modes alike.
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported"],
        document_problems("dependencies: ? bar\n", True),
    )
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported"],
        document_problems("dependencies: ? bar\n"),
    )
    asserts.equals(
        env,
        ["explicit key at line 1 is not supported"],
        document_problems("key:\t? bar\n", True),
    )

    # Later keys of a `- key:` item must sit at the key's own column, as pub
    # rejects them anywhere else; an aligned key still merges, a dedent still
    # leaves the sequence, and a pending key still nests, as pub reads them.
    asserts.equals(
        env,
        ["unreadable line 3: \"foo: any\""],
        document_problems("dependencies:\n - meta: any\n  foo: any\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 3: \"foo: any\""],
        document_problems("dependencies:\n - meta: any\n      foo: any\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 3: \"foo: any\""],
        document_problems("dependencies:\n  - meta: any\n foo: any\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 3: \"foo: any\""],
        document_problems("dependencies:\n- meta: any\n foo: any\n", True),
    )
    asserts.equals(
        env,
        {"dependencies": [{"meta": "any", "foo": "any"}]},
        parse_document("dependencies:\n - meta: any\n   foo: any\n"),
    )
    asserts.equals(
        env,
        {"dependencies": [{"meta": "any"}], "foo": "any"},
        parse_document("dependencies:\n - meta: any\nfoo: any\n"),
    )
    asserts.equals(
        env,
        {"dependencies": [{"meta": {"foo": "any"}}]},
        parse_document("dependencies:\n - meta:\n     foo: any\n"),
    )

    # Everywhere else a colon reads as pub reads it: glued, in quotes, in a
    # flow, or after a URL scheme; a glued dash or question mark reads too.
    asserts.equals(env, {"description": "a:b"}, parse_document("description: a:b\n"))
    asserts.equals(env, {"url": "http://x"}, parse_document("url: http://x\n"))
    asserts.equals(env, {"description": ":foo"}, parse_document("description: :foo\n"))
    asserts.equals(env, {"description": "::foo"}, parse_document("description: ::foo\n"))
    asserts.equals(env, {"description": "a: b"}, parse_document("description: \"a: b\"\n"))
    asserts.equals(
        env,
        {"description": [{"a": "b"}]},
        parse_document("description: [a: b]\n"),
    )
    asserts.equals(env, {"dependencies": "-a"}, parse_document("dependencies: -a\n"))
    asserts.equals(env, {"dependencies": "?bar"}, parse_document("dependencies: ?bar\n"))
    asserts.equals(
        env,
        {"dependencies": [{"a": "b"}]},
        parse_document("dependencies:\n - a: b\n"),
    )
    return unittest.end(env)

def _flow_indicator_test_impl(ctx):
    env = unittest.begin(ctx)

    # A block value starting with `]`, `}` or `,` fails naming the line, as
    # pub rejects a flow-closing indicator where a node starts
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5); past the first
    # character they stay content, in strict and lenient modes alike.
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("description: ]x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("description: ]x\n"),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("description: }x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("description: ,x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("]x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("]x: 1\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 1 is not supported"],
        document_problems("description: &x ]x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 2 is not supported"],
        document_problems("tags:\n - ]x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 2 is not supported"],
        document_problems("tags:\n - ,x\n", True),
    )
    asserts.equals(
        env,
        ["flow indicator at line 2 is not supported"],
        document_problems("tags:\n - }x\n", True),
    )

    # A `|` or `>` where a flow item, pair value or key starts fails naming
    # the line, as pub rejects a block scalar there, even under an anchor or
    # a tag; past the first character they stay content.
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [a, |b]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [a, |b]\n"),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [|a]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [a, >b]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [|]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: {a: |b}\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: {a: >b}\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [&x |b]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [a: &x |b]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: [!foo |b]\n", True),
    )
    asserts.equals(
        env,
        ["block scalar inside flow at line 1 is not supported"],
        document_problems("tags: {|a: b}\n", True),
    )

    # Everywhere else these characters read as pub reads them: mid-scalar in
    # a block or a flow, quoted, or as flow `?` and `:` scalars.
    asserts.equals(env, {"description": "a ]x"}, parse_document("description: a ]x\n"))
    asserts.equals(env, {"description": "a ]x"}, parse_document("description: a\n  ]x\n"))
    asserts.equals(env, {"description": "|b"}, parse_document("description: \"|b\"\n"))
    asserts.equals(env, {"tags": ["a |b"]}, parse_document("tags: [a |b]\n"))
    asserts.equals(env, {"tags": ["a", "?b"]}, parse_document("tags: [a, ?b]\n"))
    asserts.equals(env, {"tags": ["a", "b"]}, parse_document("tags: [a, b]\n"))
    asserts.equals(env, {"key": "]x\n"}, parse_document("key: |\n  ]x\n"))
    return unittest.end(env)

def _block_scalar_indicator_test_impl(ctx):
    env = unittest.begin(ctx)

    # A `0` indentation indicator fails naming the line, as pub rejects it
    # (package:yaml 3.1.4 with the pinned SDK 3.13.5), in any chomping
    # combination and after a dash; other digits read as pub reads them.
    asserts.equals(
        env,
        ["unreadable line 1: \"description: |0\"", "unreadable line 2: \"x\""],
        document_problems("description: |0\n  x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 1: \"description: >0\"", "unreadable line 2: \"x\""],
        document_problems("description: >0\n  x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 1: \"description: |+0\"", "unreadable line 2: \"x\""],
        document_problems("description: |+0\n  x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 1: \"description: |-0\"", "unreadable line 2: \"x\""],
        document_problems("description: |-0\n  x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 1: \"description: |0+\"", "unreadable line 2: \"x\""],
        document_problems("description: |0+\n  x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 2: \"- |0\"", "unreadable line 3: \"x\""],
        document_problems("tags:\n - |0\n   x\n", True),
    )
    asserts.equals(
        env,
        ["unreadable line 2: \"- a: |0\"", "unreadable line 3: \"x\""],
        document_problems("dependencies:\n - a: |0\n   x\n", True),
    )
    asserts.equals(env, {"description": "x\n"}, parse_document("description: |2\n  x\n"))
    asserts.equals(env, {"description": "x\n"}, parse_document("description: |+2\n  x\n"))
    asserts.equals(env, {"description": " x"}, parse_document("description: |-1\n  x\n"))
    return unittest.end(env)

def _directive_test_impl(ctx):
    env = unittest.begin(ctx)

    # Directive versions, tags and unknown directives read as pub reads
    # them (package:yaml 3.1.4 with the pinned SDK 3.13.5): 1.1 through
    # 1.10 (1.3 warns only), tab or space separation, trailing comments
    # even glued to the version, either directive order, several tag
    # handles, and ignored unknown directives with or without `---`.
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.1\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.3\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.9\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.10\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.01\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML\t1.2\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2 \n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2\t\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2 # c\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2#c\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%FOO bar\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%FOO bar\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%123 x\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%YAML 1.2\n%TAG ! t:x\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG ! t:x\n%YAML 1.2\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG ! t:x\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG ! a:x\n%TAG !e! b:y\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG !! p:\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG !a! p:\n---\nname: x\n"))
    asserts.equals(env, {"name": "x"}, parse_document("%TAG ! t:x # c\n---\nname: x\n"))
    asserts.equals(env, None, parse_document("%YAML 1.2\n---\n"))
    asserts.equals(env, "foo", parse_document("%YAML 1.2\n--- foo"))

    # A duplicate `%YAML` fails naming its line, and the content then fails
    # for the missing document start, as pub rejects the duplicate first.
    asserts.equals(
        env,
        ["duplicate YAML directive at line 2", "directive without document start at line 3"],
        document_problems("%YAML 1.2\n%YAML 1.2\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["duplicate YAML directive at line 3", "directive without document start at line 4"],
        document_problems("%YAML 1.2\n# c\n%YAML 1.2\nname: x\n", True),
    )

    # A `%YAML` or `%TAG` without a later `---` fails at the first content
    # line, or past the end when the document has no content.
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 3"],
        document_problems("%YAML 1.2\n# c\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 3"],
        document_problems("%YAML 1.2\n%FOO x\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 3"],
        document_problems("%FOO bar\n%YAML 1.2\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%TAG ! t:x\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 3"],
        document_problems("%YAML 1.2\n# c\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 1"],
        document_problems("%YAML 1.2", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\n[a]\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2", "unreadable line 3: \"name: x\""],
        document_problems("%YAML 1.2\n---x\nname: x\n", True),
    )

    # A missing, malformed or incompatible `%YAML` version fails naming its
    # line, as pub rejects it.
    for version in ["1.0", "0.9", "2.0", "1", "2", "x", "1.x", "1.2.3", "extra"]:
        asserts.equals(
            env,
            ["invalid YAML directive at line 1"],
            document_problems("%YAML " + version + "\n---\nname: x\n", True),
        )
    asserts.equals(
        env,
        ["invalid YAML directive at line 1"],
        document_problems("%YAML\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid YAML directive at line 1"],
        document_problems("%YAML # c\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid YAML directive at line 1"],
        document_problems("%YAML 1.2 extra\n---\nname: x\n", True),
    )

    # A `%TAG` without a valid handle and prefix fails naming its line, and
    # a second `%TAG` with the same handle fails as a duplicate.
    asserts.equals(
        env,
        ["invalid TAG directive at line 1"],
        document_problems("%TAG\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid TAG directive at line 1"],
        document_problems("%TAG !\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid TAG directive at line 1"],
        document_problems("%TAG !a p:\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid TAG directive at line 1"],
        document_problems("%TAG ! t:x extra\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["invalid TAG directive at line 1"],
        document_problems("%TAG ! t:x#c\n---\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["duplicate TAG directive at line 2"],
        document_problems("%TAG ! a:x\n%TAG ! a:y\n---\nname: x\n", True),
    )

    # A bare `%` fails, and an indented `%` line before any content fails,
    # as pub rejects both where a directive goes.
    asserts.equals(
        env,
        ["invalid directive at line 1"],
        document_problems("%\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["indented directive at line 1"],
        document_problems("  %FOO bar\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["indented directive at line 1"],
        document_problems("  %YAML 1.2\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["indented directive at line 1"],
        document_problems("  %TAG ! t:x\nname: x\n", True),
    )
    asserts.equals(
        env,
        ["indented directive at line 2", "directive without document start at line 3"],
        document_problems("%YAML 1.2\n  %FOO x\nname: x\n", True),
    )

    # A `...` line with a pending directive fails at the `...` line, and
    # content glued to `...` fails as content without a document start.
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\n...\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\n... text\n", True),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2", "content after document end (...) at line 3"],
        document_problems("%YAML 1.2\n...\nname: x\n", True),
    )

    # Directive shapes fail closed in lenient mode too.
    asserts.equals(
        env,
        ["duplicate YAML directive at line 2", "directive without document start at line 3"],
        document_problems("%YAML 1.2\n%YAML 1.2\nname: x\n", False),
    )
    asserts.equals(
        env,
        ["directive without document start at line 2"],
        document_problems("%YAML 1.2\nname: x\n", False),
    )
    asserts.equals(
        env,
        ["invalid YAML directive at line 1"],
        document_problems("%YAML 1.0\n---\nname: x\n", False),
    )
    asserts.equals(
        env,
        ["indented directive at line 1"],
        document_problems("  %YAML 1.2\nname: x\n", False),
    )
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
_t36_test = unittest.make(_double_escape_test_impl)
_t37_test = unittest.make(_tab_indent_test_impl)
_t38_test = unittest.make(_refused_character_test_impl)
_t39_test = unittest.make(_flow_entry_test_impl)
_t40_test = unittest.make(_number_shape_test_impl)
_t41_test = unittest.make(_block_structure_test_impl)
_t42_test = unittest.make(_flow_indicator_test_impl)
_t43_test = unittest.make(_block_scalar_indicator_test_impl)
_t44_test = unittest.make(_directive_test_impl)
_t45_test = unittest.make(_tag_remainder_test_impl)

def _encoding_test_impl(ctx):
    env = unittest.begin(ctx)

    # A byte sequence that is not UTF-8 fails naming its line: pub fails
    # reading the file (its decoder throws), while `ctx.read` keeps the
    # bytes verbatim. Stray and bad lead bytes, truncated and bad
    # continuations, overlong starts, surrogate halves and past-max starts
    # all fail.
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\377\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\200\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\301\277\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\342\202\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\360\200a\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\340\200\200\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\355\240\200\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\364\220\200\200\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\303", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 2 is not supported"],
        document_problems("a: 1\nd: x\377\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 2 is not supported"],
        document_problems("a: 1\r\nd: x\377\r\n", True),
    )
    asserts.equals(
        env,
        ["invalid UTF-8 at line 1 is not supported"],
        document_problems("d: x\377\n", False),
    )

    # Valid multibyte sequences read through, including the boundary starts
    # and the U+10FFFF sequence itself.
    asserts.equals(env, {"d": "na\303\257ve \342\202\254"}, parse_document("d: na\303\257ve \342\202\254\n"))
    asserts.equals(env, {"d": "a\360\237\230\200b"}, parse_document("d: a\360\237\230\200b\n"))
    asserts.equals(env, {"d": "\340\240\200"}, parse_document("d: \340\240\200\n"))
    asserts.equals(env, {"d": "\360\220\200\200"}, parse_document("d: \360\220\200\200\n"))
    asserts.equals(env, {"d": "\355\237\277"}, parse_document("d: \355\237\277\n"))
    asserts.equals(env, {"d": "\364\217\277\277"}, parse_document("d: \364\217\277\277\n"))
    asserts.equals(env, {"d": "\335\240"}, parse_document("d: \335\240\n"))
    return unittest.end(env)

_t46_test = unittest.make(_encoding_test_impl)

def _bad_blank_test_impl(ctx):
    env = unittest.begin(ctx)

    # Only space and tab are blanks: a vertical tab, form feed or U+001C to
    # U+001F fails naming the line at the end or start of a value and before
    # a key, as pub rejects them (package:yaml 3.1.4 with the pinned SDK
    # 3.13.5); inside a value they already failed as control characters.
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: x\013\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: \013x\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d\013: 1\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("\013d: 1\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 2 is not supported"],
        document_problems("a: 1\n\013\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 2 is not supported"],
        document_problems("a: 1\n  \013\nb: 2\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: x\014\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d\014: 1\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: x\034\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: \035x\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d\036: 1\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("d: x\037\n", True),
    )

    # A failure drops only its line: siblings still read around it.
    value, problems = document_value_and_problems("a: 1\nd: x\013\nb: 2\n", True)
    asserts.equals(env, {"a": 1, "b": 2}, value)
    asserts.equals(env, ["control character at line 2 is not supported"], problems)

    # Sequence entries fail at the same positions, dropping the entry.
    value, problems = document_value_and_problems("a:\n- x\013\n- y\n", True)
    asserts.equals(env, {"a": ["y"]}, value)
    asserts.equals(env, ["control character at line 2 is not supported"], problems)
    value, problems = document_value_and_problems("a:\n- \013\n- y\n", True)
    asserts.equals(env, {"a": ["y"]}, value)
    asserts.equals(env, ["control character at line 2 is not supported"], problems)

    # Flow collections fail too: brackets never shield a bad blank, while
    # quotes and comments do, as pub scans them.
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("a: [x\013]\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("a: {k\013: v}\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("a: {k: v\013}\n", True),
    )
    asserts.equals(env, {"a": ["x\013y"]}, parse_document("a: [\"x\013y\"]\n"))
    asserts.equals(env, {"a": "x"}, parse_document("a: x # c\013d\n"))

    # A flow document fails the same way naming its line, as pub rejects it.
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("[x\013]\n", True),
    )

    # A bad blank before a comment still fails, as pub scans it first.
    asserts.equals(
        env,
        ["control character at line 1 is not supported"],
        document_problems("a: x\013 # c\n", True),
    )
    asserts.equals(
        env,
        ["control character at line 2 is not supported"],
        document_problems("a: 1\n\013 # c\nb: 2\n", True),
    )

    # A bad blank in a continuation line fails naming that line, as pub
    # reads it.
    asserts.equals(
        env,
        ["control character at line 2 is not supported"],
        document_problems("d: x\n  y\013z\n", True),
    )

    # NEL, NBSP and U+3000 stay in the value, as pub reads them.
    asserts.equals(env, {"d": "x\302\205"}, parse_document("d: x\302\205\n"))
    asserts.equals(env, {"d": "\302\205x"}, parse_document("d: \302\205x\n"))
    asserts.equals(env, {"d": "x\302\205y"}, parse_document("d: x\302\205y\n"))
    asserts.equals(env, {"d": "x\302\240y"}, parse_document("d: x\302\240y\n"))
    asserts.equals(env, {"d": "x\302\240"}, parse_document("d: x\302\240\n"))
    asserts.equals(env, {"d": "\302\240x"}, parse_document("d: \302\240x\n"))
    asserts.equals(env, {"d": "x\343\200\200y"}, parse_document("d: x\343\200\200y\n"))
    asserts.equals(env, {"d": "x\343\200\200"}, parse_document("d: x\343\200\200\n"))
    asserts.equals(env, {"d\302\240": 1}, parse_document("d\302\240: 1\n"))
    asserts.equals(env, {"d": "x\302\205y"}, parse_document("d: \"x\302\205y\"\n"))
    return unittest.end(env)

_t47_test = unittest.make(_bad_blank_test_impl)

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
        _t36_test,
        _t37_test,
        _t38_test,
        _t39_test,
        _t40_test,
        _t41_test,
        _t42_test,
        _t43_test,
        _t44_test,
        _t45_test,
        _t46_test,
        _t47_test,
    )
