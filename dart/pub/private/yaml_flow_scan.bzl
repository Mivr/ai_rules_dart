"""Quote-aware scan and fold for the pubspec YAML reader.

Holds the per-line scan that tracks quotes, plain scalars, comments and
flow depth, and the fold that joins raw lines as pub folds them. Split
out of the flow collections module; loaded by the fold and block
modules and by the ``yaml_subset.bzl`` entry point.
"""

load(":yaml_text.bzl", "bad_blank_index")

def flow_scan_start():
    """A fresh quote-aware scan state for one folded flow."""
    return {"single": False, "double": False, "escaped": False, "plain": False, "have": False, "depth": 0}

def _flow_scan_sep(scan):
    """A separator ends any plain scalar and opens a fresh value slot."""
    scan["plain"] = False
    scan["have"] = False

def _flow_scan_quoted(ch, nxt, scan, res):
    """Scans one character inside a quoted scalar, updating `scan` and `res`.

    `''` inside single quotes is one escaped quote; a backslash escapes the
    next character in double quotes, across lines too. Anything else,
    including `#`, brackets and the other quote kind, is content.
    """
    if scan["single"]:
        if ch == "'":
            if nxt == "'":
                res["kept"].append(ch)
                res["kept"].append(nxt)
                res["skip"] = True
            else:
                scan["single"] = False
                scan["have"] = True
                res["kept"].append(ch)
        else:
            res["kept"].append(ch)
    elif ch == "\\":
        scan["escaped"] = True
        res["kept"].append(ch)
    elif ch == '"':
        scan["double"] = False
        scan["have"] = True
        res["kept"].append(ch)
    else:
        res["kept"].append(ch)

def _flow_scan_hash(ch, prev, scan, res):
    """Handles `#` outside quotes: a comment, or content pub reads as one.

    Between tokens a `#` starts a comment that runs to the end of the line,
    whether the value before it is complete or not: pub reads `["red" # c,
    green]` as two values and only fails where the comment swallows a token
    the flow needs. In a plain scalar `#` is a comment after separation (or
    at the line start) and content otherwise, so an apostrophe line such as
    `don't` never opens a quote. Past the closing bracket a `#` after
    separation is a trailing comment.
    """
    if scan["plain"]:
        if prev in [" ", "\t"]:
            res["plain_comment"] = True
            res["stopped"] = True
        else:
            res["kept"].append(ch)
    else:
        res["stopped"] = True

def _flow_scan_struct(ch, nxt, scan, res):
    """Scans one bracket, separator or value character outside quotes."""
    if ch in ["[", "{"]:
        scan["depth"] += 1
        _flow_scan_sep(scan)
    elif ch in ["]", "}"]:
        if scan["depth"] > 0:
            scan["depth"] -= 1
        _flow_scan_sep(scan)
        scan["have"] = True
    elif ch == ",":
        _flow_scan_sep(scan)
    elif ch == ":" and (nxt in [" ", "\t"] or nxt == ""):
        _flow_scan_sep(scan)
    else:
        scan["plain"] = True
        scan["have"] = True
    res["kept"].append(ch)

def _flow_scan_open(ch, nxt, prev, scan, res):
    """Scans one character where a scalar may start. Returns the new previous character."""
    if ch == "'" and not scan["plain"]:
        scan["single"] = True
        res["kept"].append(ch)
    elif ch == '"' and not scan["plain"]:
        scan["double"] = True
        res["kept"].append(ch)
    elif ch == "#":
        _flow_scan_hash(ch, prev, scan, res)
        if res["stopped"]:
            return prev
    elif ch == "%" and not scan["plain"]:
        res["pct_flag"] = True
        res["stopped"] = True
        return prev
    elif ch in [" ", "\t"]:
        res["kept"].append(ch)
    else:
        _flow_scan_struct(ch, nxt, scan, res)
    return ch

def flow_scan_text(text, scan, res):
    """Scans one fold line, updating `scan` and collecting into `res`.

    `res` holds the kept characters and the line flags: `plain_comment`
    when a comment starts inside a plain scalar, `pct_flag` on a `%`
    outside quotes and plain scalars. A quote opens only where a scalar
    starts. Scanning stops at a comment or a flag; the caller fails closed
    on the flags.

    Args:
      text: the fold line to scan.
      scan: the quote state updated in place.
      res: the result collecting kept characters and line flags.
    """
    prev = " "
    for i in range(len(text) + 1):
        if i >= len(text) or res["stopped"]:
            break
        ch = text[i]
        if res["skip"]:
            res["skip"] = False
            prev = ch
            continue
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if scan["escaped"]:
            scan["escaped"] = False
            res["kept"].append(ch)
            prev = ch
        elif scan["single"] or scan["double"]:
            _flow_scan_quoted(ch, nxt, scan, res)
            prev = ch
        else:
            prev = _flow_scan_open(ch, nxt, prev, scan, res)

def _flow_fold_join(out, kept, cont):
    """Joins one kept line onto `out`: directly after a backslash continuation, else with one space."""
    if cont:
        return out + kept
    if out != "" and not out.endswith("\n"):
        return out + " " + kept
    return out + kept

def _flow_fold_backslash(out, kept, trailing, scan):
    """Folds a quoted line's end into `out`. Returns (out, mode).

    `kept` is the rstripped scanned line and `trailing` its trailing
    whitespace. A `\\` at the line's end inside double quotes continues the
    scalar: the backslash is dropped and the next line joins directly.
    Elsewhere a backslash is an ordinary character, as pub keeps it, and
    the break folds to one space. A `\\` with trailing space stays literal
    in both, as pub keeps it, and the next line joins with one space.
    `mode` is "direct" or "space".
    """
    if not scan["single"] and not scan["double"]:
        return out, "space"
    bs = 0
    for _ in range(len(kept) + 1):
        if bs < len(kept) and kept[len(kept) - 1 - bs] == "\\":
            bs += 1
        else:
            break
    if bs == 0 or bs % 2 == 0:
        return out, "space"
    if trailing != "":
        if scan["double"]:
            return out[:len(out) - 1] + trailing[:1], "space"
        return out, "space"
    if scan["double"]:
        scan["escaped"] = False
        return out[:len(out) - 1], "direct"
    return out, "space"

def _flow_fold_blank(scan, st):
    """Folds one blank line into `st`, ending any backslash continuation."""
    if st["cont"]:
        st["cont"] = False
        st["out"] += "\n"
        return
    if scan["single"] or scan["double"]:
        st["out"] += "\n"
    elif st["out"] != "" and not st["out"].endswith("\n"):
        st["out"] += "\n"

def _flow_fold_closer(kept):
    """Whether a content line after a plain-scalar comment closes the collection."""
    first = kept[:1]
    if first in [",", "]", "}"]:
        return True
    return first == ":" and (len(kept) == 1 or kept[1:2] in [" ", "\t"])

def _flow_fold_kept(scan, st, res, raw_kept, line):
    """Folds one scanned content line into `st`. Returns a problem pair, or None."""
    kept = raw_kept.rstrip()
    if kept == "":
        if res["plain_comment"]:
            st["comment_pending"] = True
            st["pending_line"] = line
        return None
    if st["comment_pending"] and not _flow_fold_closer(kept):
        return ("plain-comment", st["pending_line"])
    st["comment_pending"] = res["plain_comment"]
    if res["plain_comment"]:
        st["pending_line"] = line
    st["out"] = _flow_fold_join(st["out"], kept, st["cont"])
    st["cont"] = False
    trailing = raw_kept[len(kept):]
    out, mode = _flow_fold_backslash(st["out"], kept, trailing, scan)
    st["out"] = out
    if mode == "direct":
        st["cont"] = True
    return None

def _flow_fold_control(item, n, skip_first, scan):
    """Returns the item's line when it hides a bad blank outside quotes, else 0.

    The head item reads through its own line's check, so folds skip it; any
    other line trips on a vertical tab, form feed or U+001C to U+001F
    outside quotes and comments, as pub rejects them. A line inside open
    quotes stays content, as pub reads it.
    """
    if n == 0 and skip_first:
        return 0
    if scan["single"] or scan["double"]:
        return 0
    if bad_blank_index(item[1]) < 0:
        return 0
    return item[0]

def flow_fold_lines(items, scan, skip_first):
    """Folds raw flow lines as pub folds them. Returns (folded, problem).

    `items` holds (1-based line, raw line) pairs with "" for blank lines,
    except blank-looking lines with a bad blank, which survive as raw;
    leading indentation is dropped. `skip_first` skips the head item, which
    reads through its own line's check, while a flow document checks every
    line. A bad blank outside quotes and comments is a ("control", line)
    problem, as pub rejects it. A break between content lines is one
    space, except after a double-quoted backslash continuation, which joins
    with no space; a blank line after a continuation, and each blank line
    inside quotes, is one "\\n", while outside quotes a blank run is one
    "\\n". A `#` outside
    quotes is a comment to the end of the line, whether the value before it
    is complete or not: pub only fails where the comment swallows a token
    the flow needs. A comment that ends a line inside a plain scalar poisons
    the fold: the next content must close the collection (`,`, `]`, `}` or
    a separating `:`) or pub rejects the flow. `problem` is None, or a
    (kind, line) pair the caller reports.

    Args:
      items: the (1-based line, raw line) pairs to fold.
      scan: the quote state updated in place.
      skip_first: whether to skip the head item.

    Returns:
      The (folded, problem) pair: the folded text, and None or a (kind, line) pair
      the caller reports.
    """
    st = {"out": "", "cont": False, "comment_pending": False, "pending_line": 0}
    for n in range(len(items)):
        item = items[n]
        line = item[0]
        bad_line = _flow_fold_control(item, n, skip_first, scan)
        if bad_line:
            return "", ("control", bad_line)
        content = item[1].lstrip(" \t")
        if content.strip() == "":
            _flow_fold_blank(scan, st)
            continue
        res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
        flow_scan_text(content, scan, res)
        if res["pct_flag"]:
            return "", ("directive", line)
        problem = _flow_fold_kept(scan, st, res, "".join(res["kept"]), line)
        if problem != None:
            return "", problem
    return st["out"], None

def flow_fold_problem(kind, line):
    """The problem for a folded-flow line this reader cannot spell as pub reads it.

    Args:
      kind: the fold failure kind.
      line: the 1-based line number naming failures.

    Returns:
      The problem text.
    """
    if kind == "control":
        return "control character at line %d is not supported" % line
    if kind == "plain-comment":
        return "comment inside a plain scalar of a flow that spans lines at line %d is not supported" % line
    if kind == "directive":
        return "\"%%\" directive in a flow that spans lines at line %d is not supported" % line
    return "flow collection that spans lines starting at line %d is not supported" % line
