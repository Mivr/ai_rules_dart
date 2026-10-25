"""Byte-level character checks for the pubspec YAML reader.

Holds UTF-8 validity, byte-order-mark stripping and document-marker lines.
A leaf module: it loads nothing. Loaded by the text, scalar, fold, block
and document modules.
"""

# A leading UTF-8 byte-order mark (U+FEFF), written as octal escapes so the
# source stays ASCII. Pub accepts it; without stripping, the first key would
# carry it and a lock would read as missing `packages`.
BOM = "\357\273\277"

def _is_utf8_trail(byte):
    """Returns whether a one-byte string is a UTF-8 continuation byte."""
    return "\200" <= byte and byte <= "\277"

def _utf8_lead_size(byte):
    """Returns the trail count for a lead byte, or -1 when no sequence starts.

    A stray continuation byte, a C0 or C1 lead and a lead past F4 start no
    sequence, as none decodes.
    """
    if byte < "\302":
        return -1
    if byte < "\340":
        return 1
    if byte < "\360":
        return 2
    if byte < "\365":
        return 3
    return -1

def _utf8_sequence_bad(content, i, size, n, byte):
    """Returns whether the sequence at `i` breaks UTF-8.

    A lead with missing or bad continuation bytes, an overlong E0 or F0
    start, an ED start of a surrogate half, and an F4 start past U+10FFFF
    all fail, as none decodes.
    """
    if i + size >= n:
        return True
    for k in range(1, size + 1):
        if not _is_utf8_trail(content[i + k]):
            return True
    second = content[i + 1]
    if byte == "\340" and second < "\240":
        return True
    if byte == "\360" and second < "\220":
        return True
    if byte == "\355" and "\240" <= second and second <= "\277":
        return True
    if byte == "\364" and "\217" < second:
        return True
    return False

def first_bad_utf8_line(content):
    """Returns the 1-based line of the first byte that breaks UTF-8, or 0.

    `ctx.read` keeps the file's bytes verbatim, so a byte sequence that is
    not UTF-8 reaches the reader where pub fails reading the file (its
    decoder throws). Line breaks count as the collector counts them.
    A lead byte with missing or bad continuation bytes, a stray
    continuation byte, a C0 or C1 lead, a lead past F4, an overlong E0 or
    F0 start, an ED start of a surrogate half, and an F4 start past
    U+10FFFF all fail, as none decodes; anything else reads, including a
    4-byte start and the U+10FFFF sequence itself.


    Args:
      content: the file content to scan.

    Returns:
      The 1-based line of the first byte that breaks UTF-8, or 0 when the content decodes.
    """
    line = 1
    i = 0
    n = len(content)
    for _ in range(n + 1):
        if i >= n:
            return 0
        byte = content[i]
        if byte == "\n":
            line += 1
            i += 1
        elif byte == "\r":
            line += 1
            i += 1
            if i < n and content[i] == "\n":
                i += 1
        elif byte < "\200":
            i += 1
        elif byte < "\300":
            return line
        else:
            size = _utf8_lead_size(byte)
            if size < 0 or _utf8_sequence_bad(content, i, size, n, byte):
                return line
            i += size + 1
    return 0

def strip_bom(content):
    """Strips every leading UTF-8 byte-order mark, which pub accepts at the start.

    Args:
      content: the text to strip.

    Returns:
      The text without its leading byte-order marks.
    """
    for _ in range(len(content) + 1):
        if content.startswith(BOM):
            content = content[len(BOM):]
        else:
            break
    return content

def _strip_bom_text(text):
    """Strips leading whitespace and byte-order marks, returning the rest."""
    s = text
    for _ in range(len(s) + 1):
        t = s.lstrip(" \t")
        if t.startswith(BOM):
            s = t[len(BOM):]
        else:
            return t
    return ""

def is_bom_only_line(raw):
    """Returns whether `raw` carries no content past byte-order marks: only BOMs, whitespace and a `#` comment."""
    rest = _strip_bom_text(raw)
    return rest == "" or rest.startswith("#")

def is_marker_line(raw, marker):
    """Returns whether `raw` is a document marker: the marker at column 0 with only whitespace after it.

    An indented marker is never a document marker: inside a `|` or `>`
    block scalar it is content, and elsewhere it is an ordinary line.
    """
    if not raw.startswith(marker):
        return False
    return raw[len(marker):].strip() == ""

def is_clean_marker_line(raw, marker):
    """Returns whether `raw` is a document marker: the marker at column 0 with only whitespace or a `#` comment after it.

    A `#` after separation is a comment, as pub reads `... # c` as a clean
    document end; text glued to the marker or after a space is content the
    document handlers place.


    Args:
      raw: the raw source line.
      marker: the `---` or `...` marker text.

    Returns:
      True when `raw` is the marker with only whitespace or a `#` comment after it.
    """
    if not raw.startswith(marker):
        return False
    rest = raw[len(marker):]
    if rest.strip() == "":
        return True
    return rest[:1] in [" ", "\t"] and rest.strip().startswith("#")
