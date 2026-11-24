"""`Package.resolved` reading and pin classification for SwiftPM spokes.

Only versions 2 and 3 (`{"pins": [...], "version": N}`) are supported;
version 1 (`object.pins`) fails naming the file. Starlark's `json.decode`
reports no file on malformed input, so a bounded tokenizer and checker run
first and fail naming the resolved label. Pin classification is pure, so
Starlark unit tests drive every pinned/unpinned shape without fetching.
"""

visibility(["//flutter/..."])

def is_swiftpm_identity(text):
    """Whether `text` is a usable SwiftPM package identity.

    Args:
        text: The candidate identity.

    Returns:
        True for non-empty lowercase letters, digits, `.`, `_` and `-`.
    """
    if not text:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("a" <= char and char <= "z") or ("0" <= char and char <= "9") or char == "." or char == "_" or char == "-"):
            return False
    return True

def is_swiftpm_sha256(text):
    """Whether `text` is a pinned SHA-256 hex digest.

    Args:
        text: The candidate digest.

    Returns:
        True for exactly 64 lowercase hex characters.
    """
    if len(text) != 64:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("0" <= char and char <= "9") or ("a" <= char and char <= "f")):
            return False
    return True

def is_swiftpm_revision(text):
    """Whether `text` is a usable commit revision.

    Args:
        text: The candidate `state.revision`.

    Returns:
        True for exactly 40 hex characters of either case.
    """
    if len(text) != 40:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("0" <= char and char <= "9") or ("a" <= char and char <= "f") or ("A" <= char and char <= "F")):
            return False
    return True

def swiftpm_spoke_name(hub_name, identity):
    """The spoke repository name for one SwiftPM pin.

    Args:
        hub_name: The `flutter.pub` hub name.
        identity: The SwiftPM package identity.

    Returns:
        The spoke repository name, formatted as `<hub>__swiftpm-<identity>`.
    """
    return hub_name + "__swiftpm-" + identity

def _swiftpm_bad_location():
    """The `swiftpm_github_parts` failure for a non-GitHub location.

    Returns:
        The failure struct with reason `"location"`.
    """
    return struct(ok = False, owner = "", repo = "", reason = "location")

def _swiftpm_https_parts(rest):
    """Split the host-and-path remainder of an `https://` location.

    Args:
        rest: The location past the `https://` scheme.

    Returns:
        `struct(ok, owner, repo, reason)`.
    """
    slash = rest.find("/")
    if slash < 0:
        return _swiftpm_bad_location()
    if rest[:slash].lower() != "github.com":
        return _swiftpm_bad_location()
    path = rest[slash + 1:]
    first = path.find("/")
    if first < 0 or path.find("/", first + 1) >= 0:
        return _swiftpm_bad_location()
    owner = path[:first]
    repo = path[first + 1:]
    if repo.endswith(".git"):
        repo = repo[:len(repo) - 4]
    if not owner or not repo:
        return _swiftpm_bad_location()
    return struct(ok = True, owner = owner, repo = repo, reason = "")

def _swiftpm_scp_parts(rest):
    """Split the remainder of a `git@` scp-like location.

    Args:
        rest: The location past the `git@` prefix.

    Returns:
        `struct(ok, owner, repo, reason)`: reason `"ssh"` marks a
        `git@github.com` location without the `.git` suffix.
    """
    colon = rest.find(":")
    if colon < 0:
        return _swiftpm_bad_location()
    if rest[:colon].lower() != "github.com":
        return _swiftpm_bad_location()
    path = rest[colon + 1:]
    if not path.endswith(".git"):
        return struct(ok = False, owner = "", repo = "", reason = "ssh")
    path = path[:len(path) - 4]
    first = path.find("/")
    if first < 0 or path.find("/", first + 1) >= 0:
        return _swiftpm_bad_location()
    owner = path[:first]
    repo = path[first + 1:]
    if not owner or not repo:
        return _swiftpm_bad_location()
    return struct(ok = True, owner = owner, repo = repo, reason = "")

def swiftpm_github_parts(location):
    """Split a pin location into a GitHub owner/repo.

    Accepts `https://github.com/<owner>/<repo>[.git]` (any host letter
    case) and `git@github.com:<owner>/<repo>.git`. Anything else —
    another host, another scheme, a `git@` location without the `.git`
    suffix — is not a fetchable GitHub repository.

    Args:
        location: The pin's `location` string.

    Returns:
        `struct(ok, owner, repo, reason)`: `reason` is "" when ok, else
        `"ssh"` (a `git@github.com` location without `.git`) or
        `"location"` (not a GitHub repository location at all).
    """
    if location[:8].lower() == "https://":
        return _swiftpm_https_parts(location[len("https://"):])
    if location.startswith("git@"):
        return _swiftpm_scp_parts(location[len("git@"):])
    return _swiftpm_bad_location()

def _swiftpm_json_scan_gap(char):
    """Whether one character is JSON whitespace outside strings.

    Args:
        char: The single character.

    Returns:
        Whether it is a space, tab, carriage return or newline.
    """
    return char == " " or char == "\t" or char == "\r" or char == "\n"

def _swiftpm_json_scan_one(text, i, line):
    """Scan the single token starting at one index.

    Args:
        text: The complete file text to scan, as read from disk.
        i: The index of the token's first character (never whitespace).
        line: The line the token starts on.

    Returns:
        `struct(ok, detail, kind, next, line)`: `kind` is "" when the
        character starts no token.
    """
    char = text[i]
    if char == "{" or char == "}" or char == "[" or char == "]" or char == "," or char == ":":
        return struct(ok = True, detail = "", kind = char, next = i + 1, line = line)
    if char == "\"":
        parsed = _swiftpm_json_string(text, i, line)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "str", next = parsed.next, line = parsed.line)
    if char == "-" or ("0" <= char and char <= "9"):
        parsed = _swiftpm_json_number(text, i)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "num", next = parsed.next, line = line)
    if ("a" <= char and char <= "z") or ("A" <= char and char <= "Z"):
        parsed = _swiftpm_json_literal(text, i)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "lit", next = parsed.next, line = line)
    return struct(ok = False, detail = "unexpected character {char}".format(char = repr(char)), kind = "", next = i, line = line)

def _swiftpm_json_tokenize(text):
    """Tokenize JSON text without decoding it.

    Args:
        text: The candidate JSON text.

    Returns:
        `struct(ok, detail, tokens)`: tokens carry `kind` (`{`, `}`, `[`,
        `]`, `,`, `:`, `str`, `num`, `lit`) and `line`.
    """
    tokens = []
    i = 0
    line = 1
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        if _swiftpm_json_scan_gap(text[i]):
            if text[i] == "\n":
                line += 1
            i += 1
            continue
        scanned = _swiftpm_json_scan_one(text, i, line)
        if not scanned.ok:
            return struct(ok = False, detail = scanned.detail, tokens = [])
        tokens.append(struct(kind = scanned.kind, line = line))
        i = scanned.next
        line = scanned.line
    return struct(ok = True, detail = "", tokens = tokens)

def _swiftpm_json_is_hex(char):
    """Whether one character is an ASCII hex digit.

    Args:
        char: The single character.

    Returns:
        True for `0-9`, `a-f` and `A-F`.
    """
    return ("0" <= char and char <= "9") or ("a" <= char and char <= "f") or ("A" <= char and char <= "F")

def _swiftpm_json_unicode(text, i, n):
    """Skip the four hex digits of a `\\u` escape.

    Args:
        text: The complete file text to scan, as read from disk.
        i: The index of the `u`.
        n: The text length.

    Returns:
        `struct(ok, detail, next)`: `next` is past the fourth digit.
    """
    for j in range(1, 5):
        if i + j >= n:
            return struct(ok = False, detail = "a bad `\\u` escape", next = i)
        if not _swiftpm_json_is_hex(text[i + j]):
            return struct(ok = False, detail = "a bad `\\u` escape", next = i)
    return struct(ok = True, detail = "", next = i + 5)

def _swiftpm_json_escape(text, i, n):
    """Skip one backslash escape inside a JSON string.

    Args:
        text: The complete file text to scan, as read from disk.
        i: The index of the backslash.
        n: The text length.

    Returns:
        `struct(ok, detail, next)`: `next` is past the escape.
    """
    if i + 1 >= n:
        return struct(ok = False, detail = "an unterminated string", next = i)
    esc = text[i + 1]
    if esc == "u":
        return _swiftpm_json_unicode(text, i + 1, n)
    if esc == "\"" or esc == "\\" or esc == "/" or esc == "b" or esc == "f" or esc == "n" or esc == "r" or esc == "t":
        return struct(ok = True, detail = "", next = i + 2)
    return struct(ok = False, detail = "a bad escape {esc}".format(esc = repr("\\" + esc)), next = i + 1)

def _swiftpm_json_string(text, start, line):
    """Skip one JSON string literal.

    Args:
        text: The complete file text to scan, as read from disk.
        start: The index of the opening quote.
        line: The line the string starts on.

    Returns:
        `struct(ok, detail, next, line)`: `next` is the index past the
        closing quote.
    """
    i = start + 1
    n = len(text)
    for _ in range(n - start):
        if i >= n:
            return struct(ok = False, detail = "an unterminated string", next = i, line = line)
        char = text[i]
        if char == "\"":
            return struct(ok = True, detail = "", next = i + 1, line = line)
        if char == "\n":
            return struct(ok = False, detail = "an unterminated string", next = i, line = line)
        if char == "\\":
            skipped = _swiftpm_json_escape(text, i, n)
            if not skipped.ok:
                return struct(ok = False, detail = skipped.detail, next = skipped.next, line = line)
            i = skipped.next
            continue
        i += 1
    return struct(ok = False, detail = "an unterminated string", next = i, line = line)

def _swiftpm_json_digits(text, i, n):
    """Skip one run of ASCII digits.

    Args:
        text: The complete file text to scan, as read from disk.
        i: The index the run starts at.
        n: The text length.

    Returns:
        `struct(next, count)`: the index past the run and its length.
    """
    count = 0
    for _ in range(n - i):
        if i >= n or text[i] < "0" or text[i] > "9":
            break
        i += 1
        count += 1
    return struct(next = i, count = count)

def _swiftpm_json_number(text, start):
    """Skip one JSON number literal.

    Args:
        text: The complete file text to scan, as read from disk.
        start: The index the number starts at.

    Returns:
        `struct(ok, detail, next)`: `next` is the index past the number.
    """
    i = start
    n = len(text)
    if i < n and text[i] == "-":
        i += 1
    if i >= n:
        return struct(ok = False, detail = "a bad number", next = i)
    if text[i] == "0":
        i += 1
    elif "1" <= text[i] and text[i] <= "9":
        i = _swiftpm_json_digits(text, i, n).next
    else:
        return struct(ok = False, detail = "a bad number", next = i)
    if i < n and text[i] == ".":
        frac = _swiftpm_json_digits(text, i + 1, n)
        if frac.count == 0:
            return struct(ok = False, detail = "a bad number", next = frac.next)
        i = frac.next
    if i < n and (text[i] == "e" or text[i] == "E"):
        i += 1
        if i < n and (text[i] == "+" or text[i] == "-"):
            i += 1
        exp = _swiftpm_json_digits(text, i, n)
        if exp.count == 0:
            return struct(ok = False, detail = "a bad number", next = exp.next)
        i = exp.next
    return struct(ok = True, detail = "", next = i)

def _swiftpm_json_literal(text, start):
    """Skip one `true`, `false` or `null` literal.

    Args:
        text: The complete file text to scan, as read from disk.
        start: The index the literal starts at.

    Returns:
        `struct(ok, detail, next)`.
    """
    for word in ["true", "false", "null"]:
        if text[start:start + len(word)] == word:
            after = start + len(word)
            if after < len(text):
                tail = text[after]
                if (("a" <= tail and tail <= "z") or ("A" <= tail and tail <= "Z") or
                    ("0" <= tail and tail <= "9") or tail == "_"):
                    continue
            return struct(ok = True, detail = "", next = after)
    return struct(ok = False, detail = "an unknown literal", next = start)

def _swiftpm_json_after_value(stack, counts):
    """Fold one completed value into the checker state.

    Args:
        stack: The open containers (`{`/`[`).
        counts: The per-frame completed values (mutated in place).

    Returns:
        The next state (`"sep"` or `"end"`).
    """
    if not stack:
        return "end"
    counts[len(counts) - 1] += 1
    return "sep"

def _swiftpm_json_check_val(tok, stack, counts):
    """Consume one token where a value is expected.

    Args:
        tok: One lexer token from the scanned text, as produced by the tokenizer.
        stack: The open containers (`{`/`[`; mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == "str" or tok.kind == "num" or tok.kind == "lit":
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    if tok.kind == "{":
        stack.append("{")
        counts.append(0)
        return struct(ok = True, detail = "", state = "key")
    if tok.kind == "[":
        stack.append("[")
        counts.append(0)
        return struct(ok = True, detail = "", state = "val")
    if tok.kind == "]" and stack and stack[len(stack) - 1] == "[" and counts[len(counts) - 1] == 0:
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected a value", state = "")

def _swiftpm_json_check_key(tok, stack, counts):
    """Consume one token where an object key is expected.

    Args:
        tok: One lexer token from the scanned text, as produced by the tokenizer.
        stack: The open containers (mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == "str":
        return struct(ok = True, detail = "", state = "colon")
    if tok.kind == "}" and stack and stack[len(stack) - 1] == "{" and counts[len(counts) - 1] == 0:
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected an object key", state = "")

def _swiftpm_json_check_sep(tok, stack, counts):
    """Consume one token where a separator or closing bracket is expected.

    Args:
        tok: One lexer token from the scanned text, as produced by the tokenizer.
        stack: The open containers (mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == ",":
        if stack[len(stack) - 1] == "{":
            return struct(ok = True, detail = "", state = "key")
        return struct(ok = True, detail = "", state = "val")
    if tok.kind == "]" and stack[len(stack) - 1] == "[":
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    if tok.kind == "}" and stack[len(stack) - 1] == "{":
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected a `,` or a closing bracket", state = "")

def _swiftpm_json_check_tokens(tokens):
    """Check one token stream against the JSON value grammar.

    Iterative over an explicit stack, so nesting depth cannot overflow
    Starlark call depth.

    Args:
        tokens: The tokenized stream.

    Returns:
        `struct(ok, detail)`; `detail` says what the grammar check expected when `ok` is false.
    """
    stack = []
    counts = []
    state = "val"
    for tok in tokens:
        if state == "val":
            stepped = _swiftpm_json_check_val(tok, stack, counts)
        elif state == "key":
            stepped = _swiftpm_json_check_key(tok, stack, counts)
        elif state == "colon":
            if tok.kind == ":":
                stepped = struct(ok = True, detail = "", state = "val")
            else:
                stepped = struct(ok = False, detail = "expected a `:`", state = "")
        elif state == "sep":
            stepped = _swiftpm_json_check_sep(tok, stack, counts)
        else:
            return struct(ok = False, detail = "trailing content after the top-level value")
        if not stepped.ok:
            return struct(ok = False, detail = stepped.detail)
        state = stepped.state
    if state == "end":
        return struct(ok = True, detail = "")
    return struct(ok = False, detail = "an incomplete document")

def swiftpm_check_json(text, label):
    """Fail malformed JSON naming the resolved file.

    Args:
        text: The file content.
        label: The resolved label, for messages.

    Returns:
        "" or the fetch failure naming the file and the first problem.
    """
    tokenized = _swiftpm_json_tokenize(text)
    if not tokenized.ok:
        return "Cannot parse {label} as JSON: {detail}.".format(label = label, detail = tokenized.detail)
    checked = _swiftpm_json_check_tokens(tokenized.tokens)
    if not checked.ok:
        return "Cannot parse {label} as JSON: {detail}.".format(label = label, detail = checked.detail)
    return ""

def read_swiftpm_pins(content, label):
    """Read the pins out of a `Package.resolved` file.

    Args:
        content: The file content.
        label: The resolved label, for messages.

    Returns:
        `struct(ok, error, pins)`: `pins` lists `struct(identity, kind,
        location, revision)`. A pin that is not pinned keeps its (possibly
        empty) kind, location and revision: every pin gets a repository, and
        the spoke fetch refuses it before any download.
    """
    bad = swiftpm_check_json(content, label)
    if bad:
        return struct(ok = False, error = bad, pins = [])
    data = json.decode(content)
    if type(data) != "dict":
        return struct(ok = False, error = "{label} must hold a JSON object.".format(label = label), pins = [])
    version = data.get("version", 0)
    if version == 1 or "object" in data:
        return struct(ok = False, error = "{label} is a version 1 `Package.resolved` (`object.pins`): re-resolve it with Xcode to version 2 or 3.".format(label = label), pins = [])
    if version != 2 and version != 3:
        return struct(ok = False, error = "{label} has an unsupported version ({version}): only versions 2 and 3 parse.".format(label = label, version = repr(version)), pins = [])
    raw_pins = data.get("pins", None)
    if type(raw_pins) != "list":
        return struct(ok = False, error = "{label} has no top-level `pins` array.".format(label = label), pins = [])
    pins = []
    for raw in raw_pins:
        if type(raw) != "dict":
            return struct(ok = False, error = "{label} holds a pin that is not an object.".format(label = label), pins = [])
        identity = raw.get("identity", "")
        kind = raw.get("kind", "")
        location = raw.get("location", "")
        state = raw.get("state", None)
        revision = state.get("revision", "") if type(state) == "dict" else ""
        if type(identity) != "string" or not is_swiftpm_identity(identity):
            return struct(ok = False, error = "{label} holds a pin with an unusable identity ({identity}): identities are lowercase letters, digits, `.`, `_` and `-`.".format(label = label, identity = repr(identity)), pins = [])

        # A pin that is not pinned (wrong kind, non-GitHub location, missing
        # or malformed revision, missing sha256) still gets its repository:
        # the spoke fetch fails before any download, naming the fix. Only the
        # identity must parse here — without it no spoke can be named.
        if type(kind) != "string":
            kind = ""
        if type(location) != "string":
            location = ""
        if type(revision) != "string":
            revision = ""
        pins.append(struct(identity = identity, kind = kind, location = location, revision = revision))
    return struct(ok = True, error = "", pins = pins)

def _swiftpm_sha256_failure(error):
    """The `read_swiftpm_checksums` failure result."""
    return struct(ok = False, error = error, sha256_by_identity = {})

def read_swiftpm_checksums(content, label):
    """Read the hub's SwiftPM checksum table.

    A plugin spoke reads this table lazily, only after finding its own
    `Package.swift`, so a pure-Dart spoke never depends on it. The file
    is written by the hub rule from the `swift_package_sha256` tag and
    holds identity-to-digest entries.

    Args:
        content: The file content.
        label: The checksum-file label, for messages.

    Returns:
        `struct(ok, error, sha256_by_identity)`: the map on success, or
        the failure naming the file and the first malformed entry.
    """
    bad = swiftpm_check_json(content, label)
    if bad:
        return _swiftpm_sha256_failure(bad)
    data = json.decode(content)
    if type(data) != "dict":
        return _swiftpm_sha256_failure("{label} must hold a JSON object.".format(label = label))
    sha256_by_identity = {}
    for identity in data.keys():
        digest = data[identity]
        if type(identity) != "string" or not is_swiftpm_identity(identity):
            return _swiftpm_sha256_failure("{label} holds an unusable package identity ({identity}): identities are lowercase letters, digits, `.`, `_` and `-`.".format(label = label, identity = repr(identity)))
        if type(digest) != "string" or not is_swiftpm_sha256(digest):
            return _swiftpm_sha256_failure("{label} holds an invalid checksum for {identity}: expected 64 lowercase hex characters.".format(label = label, identity = repr(identity)))
        sha256_by_identity[identity] = digest
    return struct(ok = True, error = "", sha256_by_identity = sha256_by_identity)

def swiftpm_unpinned_errors(pins, sha256_by_identity, hub_name, resolved_label):
    """Build the identity-to-refusal map a plugin reader consults.

    Args:
        pins: The pin structs from `read_swiftpm_pins`.
        sha256_by_identity: The `swift_package_sha256` map.
        hub_name: The `flutter.pub` hub name, for messages.
        resolved_label: The resolved label, for messages.

    Returns:
        Identity-to-refusal dict for every pin that cannot be fetched;
        an empty dict when every pin is pinned.
    """
    unpinned = {}
    for pin in pins:
        classified = classify_swiftpm_pin(pin, sha256_by_identity, hub_name, resolved_label)
        if not classified.ok:
            unpinned[pin.identity] = classified.error
    return unpinned

def classify_swiftpm_pin(pin, sha256_by_identity, hub_name, resolved_label):
    """Decide how one pin fetches: pinned download or fail-closed refusal.

    A pin is pinned only with all of kind `remoteSourceControl`, a GitHub
    location, a usable `state.revision`, and a `swift_package_sha256` dict
    entry. Anything missing becomes one fetch failure whose clauses each
    name their fix; the checksum clause carries the exact archive URL when
    the location parses.

    Args:
        pin: The pin struct from `read_swiftpm_pins`.
        sha256_by_identity: The `swift_package_sha256` dict.
        hub_name: The `flutter.pub` hub name.
        resolved_label: The resolved label, for messages.

    Returns:
        `struct(ok, url, sha256, error)`: the exact archive URL and digest
        when pinned, else the fetch failure.
    """
    sha = sha256_by_identity.get(pin.identity, "")
    parts = swiftpm_github_parts(pin.location)
    kind_ok = pin.kind == "remoteSourceControl"
    rev_ok = is_swiftpm_revision(pin.revision)
    sha_ok = sha != "" and is_swiftpm_sha256(sha)
    if kind_ok and parts.ok and rev_ok and sha_ok:
        url = "https://github.com/{owner}/{repo}/archive/{revision}.tar.gz".format(owner = parts.owner, repo = parts.repo, revision = pin.revision)
        return struct(ok = True, url = url, sha256 = sha, error = "")
    problems = []
    if not sha_ok:
        if sha == "":
            if parts.ok:
                url = "https://github.com/{owner}/{repo}/archive/{revision}.tar.gz".format(owner = parts.owner, repo = parts.repo, revision = pin.revision)
                problems.append("has no `swift_package_sha256[{identity}]` entry: download {url} and record its SHA-256 digest".format(identity = repr(pin.identity), url = url))
            else:
                problems.append("has no `swift_package_sha256[{identity}]` entry, and its location parses to no downloadable archive URL".format(identity = repr(pin.identity)))
        else:
            problems.append("has an invalid `swift_package_sha256[{identity}]` entry (not 64 lowercase hex characters)".format(identity = repr(pin.identity)))
    if not rev_ok:
        problems.append("has no usable `state.revision` (a 40-character commit hash)")
    if not kind_ok:
        problems.append("has kind {kind} (not `remoteSourceControl`)".format(kind = repr(pin.kind)))
    if not parts.ok:
        if parts.reason == "ssh":
            problems.append("has a `git@github.com` location without a `.git` suffix, which is unresolvable: {location}".format(location = repr(pin.location)))
        else:
            problems.append("has a location that is not a GitHub repository (`https://github.com/<owner>/<repo>` or `git@github.com:<owner>/<repo>.git`): {location}".format(location = repr(pin.location)))
    return struct(ok = False, url = "", sha256 = "", error = "{spoke}: SwiftPM package {identity} (pinned in {label}) cannot be fetched: {problems}.".format(
        spoke = swiftpm_spoke_name(hub_name, pin.identity),
        identity = repr(pin.identity),
        label = resolved_label,
        problems = "; ".join(problems),
    ))

def check_swiftpm_config_present(resolved, sha256_by_identity, build_files):
    """Refuse checksum/build-file dicts with no resolved file to pin.

    Args:
        resolved: The resolved label string, or None when unset.
        sha256_by_identity: The `swift_package_sha256` dict.
        build_files: The `swift_package_build_files` dict.

    Returns:
        "" or the failure naming the dicts without entries to attach to.
    """
    if resolved != None:
        return ""
    problems = []
    if sha256_by_identity:
        problems.append("`swift_package_sha256` names checksums with no `swift_package_resolved` file pinning the packages they belong to")
    if build_files:
        problems.append("`swift_package_build_files` names overrides with no `swift_package_resolved` file pinning the packages they belong to")
    if not problems:
        return ""
    return "flutter.pub: {problems}; set `swift_package_resolved` first.".format(problems = "; ".join(problems))

def read_ios_native_deps(content, label, hub_name):
    """Read a hub's `ios_native_deps.json` into its product mapping.

    The file is the hub's own output, so a missing, malformed or
    wrong-shaped file means a broken hub, never an empty mapping: every
    failure names the hub and the file.

    Args:
        content: The full text of the file that is being parsed.
        label: The file label, for messages.
        hub_name: The `flutter.pub` hub name, for messages.

    Returns:
        `struct(ok, error, product_deps)`: `product_deps` maps
        `<identity>:<product>` to a canonical label string.
    """
    bad = swiftpm_check_json(content, label)
    if bad:
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {bad}".format(hub = repr(hub_name), bad = bad),
            product_deps = {},
        )
    data = json.decode(content)
    if type(data) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} must hold a JSON object.".format(hub = repr(hub_name), label = label),
            product_deps = {},
        )
    if data.get("version", 0) != 1:
        return struct(
            ok = False,
            error = (
                "flutter.pub hub {hub}: {label} has an unsupported version " +
                "({version}): only version 1 parses."
            ).format(hub = repr(hub_name), label = label, version = repr(data.get("version", 0))),
            product_deps = {},
        )
    product_deps = data.get("swift_package_product_deps", None)
    if type(product_deps) != "dict":
        return struct(
            ok = False,
            error = (
                "flutter.pub hub {hub}: {label} has no " +
                "`swift_package_product_deps` object."
            ).format(hub = repr(hub_name), label = label),
            product_deps = {},
        )
    for key in product_deps:
        if type(key) != "string" or type(product_deps[key]) != "string":
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} maps a non-string key to a non-string label.".format(hub = repr(hub_name), label = label),
                product_deps = {},
            )
    return struct(
        ok = True,
        error = "",
        product_deps = product_deps,
        ios_pod_deps = data.get("ios_pod_deps", {}),
        ios_pod_ignore = data.get("ios_pod_ignore", []),
        ios_pods = data.get("ios_pods", {}),
    )

# Shared by `flutter_pub_package` and `flutter_pub_path_package`. Kept
# here so the pub-package rule file does not grow another copy of the
# same attribute documentation.
pub_spoke_package_resolved_attr = attr.label(
    doc = "Label of the hub's `swift_package_resolved` file. A plugin " +
          "spoke that ships a `Package.swift` reads it to link its " +
          "SwiftPM products; an unread label keeps pure-Dart spokes " +
          "independent of the hub's pin list. The path-package rule uses " +
          "the same attribute.",
    allow_single_file = True,
    default = None,
)

pub_spoke_package_sha256_attr = attr.label(
    doc = "Label of the hub's SwiftPM checksum table, read only together " +
          "with `package_resolved` when this package ships a " +
          "`Package.swift`. A plugin that links a pin with no entry fails " +
          "its fetch naming the plugin, the manifest and the missing " +
          "`swift_package_sha256` entry.",
    allow_single_file = True,
    default = None,
)

pub_spoke_ios_native_deps_attr = attr.label(
    doc = "Label of the hub's `ios_native_deps.json`, read only when this " +
          "package ships a `Package.swift` with at least one product " +
          "dependency. A pure-Dart spoke, or an Apple plugin with no " +
          "manifest or no product dependency, never reads it, so adding, " +
          "removing or changing a mapping leaves its marker unchanged.",
    allow_single_file = True,
    default = None,
)

pub_spoke_plugin_native_deps_attr = attr.label(
    doc = "Target providing native Apple dependencies for this plugin spoke, " +
          "from `flutter.pub(ios_plugin_deps = ...)`. When set, replaces " +
          "reading the plugin's lock entry, podspec or Package.swift.",
    default = None,
)

pub_spoke_podfile_lock_attr = attr.label(
    doc = "Label of the hub's `ios_podfile_lock` file. An Apple plugin " +
          "spoke reads it in CocoaPods mode to learn its native pod " +
          "dependencies. Unset (the default) means SwiftPM mode.",
    allow_single_file = True,
    default = None,
)

def pub_spoke_swiftpm_rule_attrs(attrs):
    """Add the SwiftPM file labels every pub-spoke repository rule declares.

    Kept beside the attribute declarations, so both pub spoke rules share
    one copy and `flutter_pub_package.bzl` stays at its size.

    Args:
        attrs: The rule's own attribute dict.

    Returns:
        The same dict with `package_resolved`, `package_sha256`,
        `ios_native_deps`, `plugin_native_deps` and `podfile_lock` added.
    """
    attrs["package_resolved"] = pub_spoke_package_resolved_attr
    attrs["package_sha256"] = pub_spoke_package_sha256_attr
    attrs["ios_native_deps"] = pub_spoke_ios_native_deps_attr
    attrs["plugin_native_deps"] = pub_spoke_plugin_native_deps_attr
    attrs["podfile_lock"] = pub_spoke_podfile_lock_attr
    return attrs

def pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = False, plugin_name = ""):
    """The SwiftPM repository arguments every pub spoke receives.

    A pub spoke gets constant labels: the hub's resolved file and checksum
    table, plus the hub's iOS native-deps map when the caller asks for it,
    and the plugin's own mapped native dependencies when set.
    None of the values is the pin list or the map itself, and all are
    read only if the package ships a `Package.swift` (the map only when
    it also has a product dependency). Pure-Dart spokes therefore keep
    their marker when a pin, a checksum or a mapping is added, removed or
    changed.

    Args:
        pub_tag: The `flutter.pub` tag.
        include_ios_native_deps: Whether to add the hub's
            `ios_native_deps.json` label. The extension passes True for
            every pub spoke; a tag that itself declares
            `swift_package_product_deps` also gets it.
        plugin_name: The pub package name to look up in `ios_plugin_deps`.

    Returns:
        `struct(package_resolved, package_sha256[, podfile_lock][, ios_native_deps][, plugin_deps])`:
        the resolved label, the checksum-file label, the CocoaPods lock
        label when the tag declares one or native deps are requested, the
        native-deps-file label when requested, and the plugin's mapped
        native dependency label. Each is None when unset; the native-deps
        label is constant for every spoke of a named hub.
    """
    resolved = pub_tag.swift_package_resolved
    hub_name = pub_tag.name if hasattr(pub_tag, "name") else ""
    include_native_deps = include_ios_native_deps or hasattr(pub_tag, "swift_package_product_deps")
    include_plugin = plugin_name != "" or hasattr(pub_tag, "ios_plugin_deps")
    sha256 = ("@%s//:swift_package_sha256.json" % hub_name) if (hub_name and resolved != None) else None
    out = {
        "package_resolved": resolved,
        "package_sha256": sha256,
    }
    if hasattr(pub_tag, "ios_podfile_lock") or include_native_deps:
        out["podfile_lock"] = pub_tag.ios_podfile_lock if hasattr(pub_tag, "ios_podfile_lock") else None
    if include_native_deps:
        out["ios_native_deps"] = ("@%s//:ios_native_deps.json" % hub_name) if hub_name else None
    if include_plugin:
        out["plugin_deps"] = (
            pub_tag.ios_plugin_deps.get(plugin_name) if hasattr(pub_tag, "ios_plugin_deps") and plugin_name else None
        )
    return struct(**out)

def swiftpm_spoke_attrs(hub_name, pin, classified, build_file):
    """The repository arguments one SwiftPM spoke receives.

    Only that pin's own translation inputs are passed: its identity, its
    resolved archive URL and checksum, its refusal and its optional
    BUILD-file override. No hub-wide pin list travels with them, so a pin
    added elsewhere leaves this spoke's attributes unchanged.

    Args:
        hub_name: The `flutter.pub` hub name.
        pin: The pin struct from `read_swiftpm_pins`.
        classified: The pin's `classify_swiftpm_pin` result.
        build_file: The pin's `swift_package_build_files` override, or None.

    Returns:
        `struct(name, identity, hub_name, archive_url, sha256,
        unpinned_error, build_file)`.
    """
    return struct(
        name = swiftpm_spoke_name(hub_name, pin.identity),
        identity = pin.identity,
        hub_name = hub_name,
        archive_url = classified.url,
        sha256 = classified.sha256,
        unpinned_error = classified.error,
        build_file = build_file,
    )

def check_swiftpm_dicts(sha256_by_identity, build_files, pin_identities, resolved_label):
    """Validate the checksum/build-file dicts against the pins.

    Args:
        sha256_by_identity: The `swift_package_sha256` dict.
        build_files: The `swift_package_build_files` label dict (keys are
            identities; values are Labels Bazel resolved in the module that
            wrote the tag, so no label-shape check remains).
        pin_identities: Every identity pinned in the resolved file.
        resolved_label: The resolved label, for messages.

    Returns:
        "" or the first failure: unknown dict keys or malformed digests.
    """
    pinned = {identity: True for identity in pin_identities}
    for identity in sorted(sha256_by_identity.keys()):
        if identity not in pinned:
            return "flutter.pub: `swift_package_sha256[{identity}]` names a package pinned nowhere in {label}.".format(identity = repr(identity), label = resolved_label)
        if not is_swiftpm_sha256(sha256_by_identity[identity]):
            return "flutter.pub: `swift_package_sha256[{identity}]` is not 64 lowercase hex characters.".format(identity = repr(identity))
    for identity in sorted(build_files.keys()):
        if identity not in pinned:
            return "flutter.pub: `swift_package_build_files[{identity}]` names a package pinned nowhere in {label}.".format(identity = repr(identity), label = resolved_label)
    return ""
