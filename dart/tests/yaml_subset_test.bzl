"""Unit tests for dart/pub/private/yaml_subset.bzl, the pubspec YAML parser.

Expected values match what yaml.bzl returns for the same text. The parity
check against yaml.bzl ran over a corpus of real pubspec files and generated
documents; these cases pin the constructs it covers.
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
    asserts.equals(env, {"a": 1}, parse_document("---\na: 1\n...\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n---\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("%YAML 1.2\n---\na: 1\n"))
    asserts.equals(env, None, parse_document(""))
    asserts.equals(env, None, parse_document("# only a comment\n"))
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

    # yaml.bzl turns a blank line in a folded scalar into two newlines, where
    # YAML 1.2 specifies one. The parity check requires yaml.bzl's output.
    asserts.equals(env, "folded text\n\nnext\n", parsed["b"])
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
        {"base": {"x": 1}, "child": {"x": 1}, "s": "hello", "t": "hello", "u": None},
        parse_document("base: &b\n  x: 1\nchild: *b\ns: &v hello\nt: *v\nu: *none\n"),
    )
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

    # An indented marker outside a block scalar is an ordinary line: strict
    # lines report it naming the line, lenient parsing skips it.
    asserts.equals(env, ["unreadable line 2: \"---\""], document_problems("a: 1\n  ---\nb: 2\n", True))
    value, problems = document_value_and_problems("a: 1\n  ---\nb: 2\n", False)
    asserts.equals(env, {"a": 1, "b": 2}, value)
    asserts.equals(env, [], problems)
    asserts.equals(env, ["unreadable line 2: \"...\""], document_problems("a: 1\n  ...\nb: 2\n", True))
    value, problems = document_value_and_problems("a: 1\n  ...\nb: 2\n", False)
    asserts.equals(env, {"a": 1, "b": 2}, value)
    asserts.equals(env, [], problems)

    # The column-0 controls keep ending the document.
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n---\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n...\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n---   \nb: 2\n"))
    return unittest.end(env)

def _multiline_flow_test_impl(ctx):
    env = unittest.begin(ctx)

    # A flow collection that spans lines is not supported: it fails naming
    # the line where the collection opens, instead of reading partially.
    text = "name: multiflow\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  bar:\n    path: ../stubbar\nflutter:\n  assets:\n    - path: assets/x.png\n      flavors: [premium,\n        free]\n"
    value, problems = document_value_and_problems(text, True)
    asserts.equals(env, "multiflow", value["name"])
    asserts.equals(env, 1, len(problems))
    if len(problems) == 1:
        asserts.true(env, "line 10" in problems[0] and "not supported" in problems[0] and "flow" in problems[0])
    value, problems = document_value_and_problems(text, False)
    asserts.equals(env, "multiflow", value["name"])
    asserts.equals(env, 1, len(problems))
    if len(problems) == 1:
        asserts.true(env, "line 10" in problems[0] and "not supported" in problems[0])

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
    )