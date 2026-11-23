#!/usr/bin/env python3
"""Guards workflow_dispatch inputs against unquoted YAML 1.1 scalars.

GitHub reads workflow files with YAML 1.1 scalar rules, where a bare
`off` (like on/yes/no/true/false/y/n and their capitalised forms) is a
boolean. A dispatch that leaves such an input at its default passes the
string "false" instead, and the bench tooling refuses it. Every
non-`boolean` workflow_dispatch input default and option must therefore
be quoted when YAML 1.1 would read it as a boolean or null.
"""

import os
import re
import unittest

_BOOL_WORDS = frozenset(
    ["y", "n", "yes", "no", "true", "false", "on", "off"])

_KEY_LINE = re.compile(r"^(\s*)([A-Za-z0-9_.\-]+):(.*)$")


def yaml11_scalar_kind(value):
    """Return "boolean"/"null" when YAML 1.1 reads value so, else None."""
    text = value.strip()
    if text == "" or text == "~" or text.lower() == "null":
        return "null"
    if text.lower() in _BOOL_WORDS:
        return "boolean"
    return None


def is_quoted_scalar(value):
    """Whether a YAML scalar is single- or double-quoted (hence a string)."""
    return value.strip()[:1] in ("'", '"')


def _first_token(value):
    """The scalar before any trailing comment or whitespace."""
    parts = value.strip().split()
    return parts[0] if parts else ""


def _bare_token(rest):
    """First token of a mapping value, without surrounding quotes."""
    token = _first_token(rest)
    if len(token) >= 2 and token[0] in ("'", '"') and token[-1] == token[0]:
        return token[1:-1]
    return token


def _check_scalar(text, filename, input_name, field):
    """Violation message for one unquoted default or option, or None."""
    if is_quoted_scalar(text):
        return None
    token = _first_token(text)
    kind = yaml11_scalar_kind(token)
    if kind is None:
        return None
    return ("%s: input '%s' has unquoted YAML 1.1 %s %r in %s; quote it"
            % (filename, input_name, kind, token, field))


def _flow_items(rest):
    """Items of an inline `[a, b]` option list, brackets stripped."""
    inner = rest.strip()
    start = inner.find("[")
    end = inner.rfind("]")
    if start < 0 or end < 0 or end < start:
        return []
    return [item.strip() for item in inner[start + 1:end].split(",")]


def _is_blank_value(rest):
    """Whether a mapping value is empty or a comment."""
    return rest.strip() == "" or rest.strip().startswith("#")


def _inputs_block(lines):
    """(dispatch_indent, inputs_index, inputs_indent), or None if absent."""
    dispatch_indent = None
    for index, line in enumerate(lines):
        match = _KEY_LINE.match(line)
        if match is None:
            continue
        here = len(line) - len(line.lstrip(" "))
        key, rest = match.group(2), match.group(3)
        if key == "workflow_dispatch" and _is_blank_value(rest):
            dispatch_indent = here
        elif key == "inputs" and _is_blank_value(rest):
            if dispatch_indent is not None and here > dispatch_indent:
                return dispatch_indent, index, here
        elif dispatch_indent is not None and here <= dispatch_indent:
            dispatch_indent = None
    return None


class _InputState:
    """One workflow_dispatch input's body lines, checked once complete."""

    def __init__(self, name):
        self.name = name
        self.is_boolean = False
        self.in_options = False
        self.defaults = []
        self.options = []

    def add(self, match, stripped):
        """Record one body line: a mapping key or a block option item."""
        if match is not None:
            self._add_key(match.group(2), match.group(3).strip())
        elif self.in_options and stripped.startswith("- "):
            self.options.append(stripped[2:].strip())

    def _add_key(self, key, rest):
        self.in_options = key == "options" and _is_blank_value(rest)
        if key == "type":
            if _bare_token(rest) == "boolean":
                self.is_boolean = True
        elif key == "default":
            self.defaults.append(rest)
        elif key == "options" and rest.startswith("["):
            self.options.extend(_flow_items(rest))

    def violations(self, filename):
        """Violation messages for this input's defaults and options."""
        if self.is_boolean:
            return []
        problems = []
        fields = (("default", self.defaults), ("options", self.options))
        for field, values in fields:
            for value in values:
                hit = _check_scalar(value, filename, self.name, field)
                if hit is not None:
                    problems.append(hit)
        return problems


def find_unquoted_scalars(text, filename="<inline>"):
    """Messages for unquoted YAML 1.1 booleans/nulls in dispatch inputs."""
    lines = text.splitlines()
    block = _inputs_block(lines)
    if block is None:
        return []
    _, index, inputs_indent = block
    problems = []
    state = None
    input_indent = None
    for line in lines[index + 1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        here = len(line) - len(line.lstrip(" "))
        if here <= inputs_indent:
            break
        match = _KEY_LINE.match(line)
        if match is not None and (input_indent is None
                                  or here <= input_indent):
            if state is not None:
                problems.extend(state.violations(filename))
            state = _InputState(match.group(2))
            input_indent = here
        elif state is not None:
            state.add(match, stripped)
    if state is not None:
        problems.extend(state.violations(filename))
    return problems


def workflows_dir():
    """The repo's .github/workflows directory for this checkout."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", ".github", "workflows")


def check_workflows_dir(path):
    """Violation messages for every workflow file in a directory."""
    problems = []
    for name in sorted(os.listdir(path)):
        if not name.endswith((".yaml", ".yml")):
            continue
        full = os.path.join(path, name)
        with open(full, encoding="utf-8") as handle:
            problems.extend(find_unquoted_scalars(handle.read(), full))
    return problems


def _dispatch_yaml(body):
    """Wrap an inputs: body in a minimal workflow_dispatch document."""
    return ("name: probe\n\"on\":\n  workflow_dispatch:\n    inputs:\n"
            + body)


class Yaml11ScalarTest(unittest.TestCase):
    """The YAML 1.1 boolean/null set, in every case form."""

    def test_booleans_in_every_case_form(self):
        for word in ("y", "n", "yes", "no", "true", "false", "on", "off"):
            forms = (word.lower(), word.upper(), word.capitalize())
            for form in forms:
                with self.subTest(value=form):
                    self.assertEqual(yaml11_scalar_kind(form), "boolean")

    def test_null_forms(self):
        for value in ("~", "null", "Null", "NULL"):
            with self.subTest(value=value):
                self.assertEqual(yaml11_scalar_kind(value), "null")

    def test_empty_is_null(self):
        self.assertEqual(yaml11_scalar_kind(""), "null")

    def test_ordinary_strings_are_neither(self):
        for value in ("none", "main", "compare", "committed", "flags",
                      "500000", "off-peak", "nope", "nullable"):
            with self.subTest(value=value):
                self.assertIsNone(yaml11_scalar_kind(value))


class ScannerSnippetTest(unittest.TestCase):
    """The scanner on inline workflow documents."""

    def scan(self, body, filename="probe.yaml"):
        return find_unquoted_scalars(_dispatch_yaml(body), filename)

    def test_old_perf_ios_ab_default_and_option_fail(self):
        body = ("      ab:\n"
                "        description: ab mode\n"
                "        default: off\n"
                "        type: choice\n"
                "        options: [off, flags, lockfile]\n")
        problems = self.scan(body, "perf-ios.yaml")
        self.assertEqual(len(problems), 2)
        for problem in problems:
            self.assertIn("perf-ios.yaml", problem)
            self.assertIn("'ab'", problem)
            self.assertIn("'off'", problem)

    def test_quoted_default_and_option_pass(self):
        body = ("      ab:\n"
                '        default: "off"\n'
                "        type: choice\n"
                '        options: ["off", flags, lockfile]\n')
        self.assertEqual(self.scan(body), [])

    def test_single_quoted_scalars_pass(self):
        body = ("      ab:\n"
                "        default: 'off'\n"
                "        type: choice\n"
                "        options: ['off', flags]\n")
        self.assertEqual(self.scan(body), [])

    def test_quoted_boolean_and_null_strings_pass(self):
        for quoted in ("\"false\"", "'false'", "\"null\"", "\"~\"",
                       "\"OFF\"", "\"No\""):
            with self.subTest(quoted=quoted):
                body = "      ab:\n        default: %s\n" % quoted
                self.assertEqual(self.scan(body), [])

    def test_boolean_type_is_ignored(self):
        body = ("      uncached:\n"
                "        description: no cache\n"
                "        required: false\n"
                "        default: false\n"
                "        type: boolean\n")
        self.assertEqual(self.scan(body), [])

    def test_block_option_list_form(self):
        body = ("      ab:\n"
                "        type: choice\n"
                "        options:\n"
                "          - off\n"
                "          - flags\n")
        problems = self.scan(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("'ab'", problems[0])
        self.assertIn("'off'", problems[0])
        self.assertIn("options", problems[0])

    def test_null_defaults_fail(self):
        for default in ("~", "null", "Null", "NULL"):
            with self.subTest(default=default):
                body = "      lockfile:\n        default: %s\n" % default
                problems = self.scan(body)
                self.assertEqual(len(problems), 1)
                self.assertIn("null", problems[0])

    def test_empty_default_is_null(self):
        problems = self.scan("      lockfile:\n        default:\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("null", problems[0])

    def test_case_variants_fail(self):
        for value in ("Off", "OFF", "oFf", "False", "NO", "Yes", "N", "y"):
            with self.subTest(value=value):
                body = "      ab:\n        default: %s\n" % value
                self.assertEqual(len(self.scan(body)), 1)

    def test_inputs_outside_dispatch_are_ignored(self):
        text = ("name: probe\n"
                "on:\n"
                "  workflow_call:\n"
                "    inputs:\n"
                "      tag_name:\n"
                "        default: off\n"
                "        type: string\n")
        self.assertEqual(find_unquoted_scalars(text), [])

    def test_file_without_dispatch_passes(self):
        self.assertEqual(find_unquoted_scalars("name: x\non: push\n"), [])


class RealWorkflowsTest(unittest.TestCase):
    """Every workflow file in .github/workflows must pass the scanner."""

    def test_no_unquoted_yaml11_booleans_or_nulls(self):
        problems = check_workflows_dir(workflows_dir())
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
