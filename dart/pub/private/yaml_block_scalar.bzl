"""Block scalars for the pubspec YAML reader.

Holds `|` and `>` headers, indentation and chomping. Loaded by the block
module.
"""

load(":yaml_text.bzl", "indent_width", "record_unreadable", "spaces_width")

def _block_scalar_header(header):
    """Reads a `|` or `>` header into (style, chomping, explicit_indent)."""
    style = header[0]
    chomping = ""
    explicit_indent = 0
    for i in range(1, len(header)):
        ch = header[i]
        if ch in ["+", "-"] and chomping == "":
            chomping = ch
        elif ch.isdigit() and explicit_indent == 0:
            explicit_indent = int(ch)
    return style, chomping, explicit_indent

def _block_scalar_header_ok(header):
    """Returns whether `header` is a valid `|` or `>` indicator.

    After the style comes at most one chomping indicator and at most one
    digit, in either order. Anything else is rejected, as pub rejects text
    after the indicator where it expects a comment or line break.
    """
    if len(header) < 1 or len(header) > 3:
        return False
    if header[0] != "|" and header[0] != ">":
        return False
    chomping = False
    digit = False
    for i in range(1, len(header)):
        ch = header[i]
        if (ch == "+" or ch == "-") and not chomping:
            chomping = True
        elif ch in "123456789" and not digit:
            # A `0` is no indentation indicator, as pub rejects it; any other
            # digit reads as pub reads it.
            digit = True
        else:
            return False
    return True

def _block_scalar_raw_lines(lines, start, parent_indent):
    """Collects the scalar lines. Returns (items, next index).

    Each item is [raw, indent], with indent -1 for a blank line, which is
    kept verbatim: spaces beyond the content indentation are content, as
    pub reads them. Collection stops before the first line at or above
    `parent_indent`, and before a line starting with a tab, which pub never
    reads as scalar content: the driver re-reads it downstream, where the
    tab indentation fails naming the line, as pub rejects it.
    """
    idx = start
    items = []
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if raw.startswith("\t"):
            break
        if not raw.strip():
            items.append([raw, -1])
            idx += 1
            continue
        indent = indent_width(raw)
        if indent <= parent_indent:
            break
        items.append([raw, indent])
        idx += 1
    return items, idx

def _block_scalar_indent(items, explicit_base, explicit_indent):
    """Reads the content indent. Returns (indent, putback, bad_lead).

    With an explicit indicator the content sits `explicit_indent` past
    `explicit_base`, the key's own column. Otherwise it sits at the first
    content line. `putback` is the first item the scalar does not cover: a
    line less indented than the content ends the scalar, as pub ends it,
    and the driver re-reads it downstream. `bad_lead` is the first content
    item when, without an explicit indicator, a leading blank line runs
    deeper than it, which pub rejects; with an explicit indicator such a
    line strips to content instead. Only spaces count toward the depth: a
    tab never indents, so a blank with spaces up to the content and a tab
    past it strips to content, as pub reads it.
    """
    first = -1
    for i in range(len(items)):
        if items[i][1] >= 0:
            first = i
            break
    if explicit_indent > 0:
        indent = explicit_base + explicit_indent
    elif first < 0:
        indent = -1
    else:
        indent = items[first][1]
    putback = len(items)
    bad_lead = -1
    if first >= 0:
        if explicit_indent == 0:
            for i in range(first):
                if spaces_width(items[i][0]) > indent:
                    bad_lead = first
                    break
        for i in range(first, len(items)):
            if items[i][1] >= 0 and items[i][1] < indent:
                putback = i
                break
    return (indent, putback, bad_lead)

def _block_scalar_values(items, kept, indent):
    """Strips the content indent. What strips to nothing stays blank.

    A line without content of its own still contributes when it runs past
    the content indent, as pub reads those spaces as content.
    """
    values = []
    for i in range(kept):
        values.append(items[i][0][indent:])
    return values

def _fold_next_is_more(values, i):
    """Returns whether the next non-blank line after `i` is more-indented.

    With no non-blank line after `i`, the break stays, so this returns True.
    A line that is whitespace past the content indent counts as
    more-indented, as pub keeps the break before it.
    """
    for j in range(i + 1, len(values)):
        if values[j] != "":
            return values[j].startswith(" ") or values[j].strip(" \t") == ""
    return True

def _fold_flowed_line(values, i, state, pieces):
    """Appends folded `>` line `i`. Returns the next state.

    `state` is start, blank, base or more, describing the previous line. A
    blank line becomes one break, with a second one after a more-indented
    line whose breaks around it are kept. The break after a base-indented
    line drops only when the next non-blank line is a base line it folds
    into; when a more-indented line follows, the break stays and each blank
    line adds one break. A break between two base lines is one space. A line
    that is whitespace past the content indent counts as more-indented, as
    pub keeps its breaks around it.
    """
    line = values[i]
    if line == "":
        pieces.append("\n")
        if state == "more" or (state == "base" and _fold_next_is_more(values, i)):
            pieces.append("\n")
        return "blank"
    more = line.startswith(" ") or line.strip(" \t") == ""
    if state == "start" or state == "blank":
        pieces.append(line)
    elif state == "base" and not more:
        pieces.append(" ")
        pieces.append(line)
    else:
        pieces.append("\n")
        pieces.append(line)
    return "more" if more else "base"

def _fold_flowed(values):
    """Folds `>` lines as pub folds them. Checked against package:yaml 3.1.4."""
    pieces = []
    state = "start"
    for i in range(len(values)):
        state = _fold_flowed_line(values, i, state, pieces)
    return "".join(pieces)

def _block_scalar_chomp(style, values, chomping):
    """Joins a block scalar and applies the chomping indicator, as pub does.

    `|` joins lines with breaks and `>` folds them with `_fold_flowed`.
    Clip keeps one final break only when anything was read, keep adds the
    final break and every trailing blank, and strip drops them.
    """
    if style == "|":
        folded = "\n".join(values)
    else:
        folded = _fold_flowed(values)
    trailing = 0
    for value in reversed(values):
        if value != "":
            break
        trailing += 1
    text = folded.rstrip("\n")
    if chomping == "-":
        return text
    if chomping == "+":
        return text + "\n" * (1 + trailing) if text else "\n" * trailing
    return text + "\n" if text else ""

def parse_block_scalar(lines, start, parent_indent, explicit_base, header, head_idx, head_text, state):
    """Reads a `|` or `>` block scalar. Returns (text, next index, ok).

    `header` is the indicator text after the key or dash, such as `|-` or
    `>2`; `explicit_base` is the key's own column, which an indentation
    indicator counts from. The content is every following line indented
    deeper than `parent_indent`, minus any lines put back past a
    less-indented line. A header with other text, and without an explicit
    indicator a leading blank line deeper than the content, are problems
    naming the line, as pub rejects them; then text is None and the driver
    re-reads from next index.
    """
    if not _block_scalar_header_ok(header):
        record_unreadable(state, head_idx, head_text)
        return None, start, False
    style, chomping, explicit_indent = _block_scalar_header(header)
    items, _idx = _block_scalar_raw_lines(lines, start, parent_indent)
    indent, putback, bad_lead = _block_scalar_indent(items, explicit_base, explicit_indent)
    if bad_lead >= 0:
        record_unreadable(state, start + bad_lead, lines[start + bad_lead].strip())
        return None, start + bad_lead, False
    values = _block_scalar_values(items, putback, indent)
    if _idx >= len(lines) and values and values[-1] == "":
        # The file ends with a newline, so the split left one artifact blank
        # line after the scalar: keep chomping must not count it as a
        # trailing blank line, as pub does not count it.
        values = values[:-1]
    return _block_scalar_chomp(style, values, chomping), start + putback, True

# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------
