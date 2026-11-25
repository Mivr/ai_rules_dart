"""Where a Maven artifact of the pin is fetched from.

The pin records, per artifact, the addresses of the repository Gradle resolved it from (the first
one Gradle used, one address per file name the repository may publish it under). The sha256 of the
pin decides what is accepted, so where the bytes come from cannot change what is built, and a list
of addresses is a list of places to ask in order: Bazel's downloader goes to the next address when one
fails after its own retries (a `429 Too Many Requests` included).

An artifact that Gradle took from Maven Central gets Google's mirror of Central after each Central
address. Nothing is added to the pin or to the lockfile: the addresses are derived when the
extension runs. A user adds, replaces or blocks addresses with Bazel's own downloader config
(`--downloader_config`, see docs/android-model.md), which rewrites whatever address a rule asks for.
"""

# Maven Central under the two names in use. Gradle records the address of the repository as the
# build file spells it.
_CENTRAL = [
    "https://repo.maven.apache.org/maven2/",
    "https://repo1.maven.org/maven2/",
]

# Mirrors of Maven Central that Google runs and documents, with the same layout. All 133 artifacts
# of Maven Central that the e2e pins hold have the sha256 of the pin there.
_CENTRAL_MIRRORS = [
    "https://maven-central.storage-download.googleapis.com/maven2/",
]

def maven_urls(urls):
    """The addresses to fetch an artifact from, in the order to try them.

    Args:
      urls: the addresses the pin records (the repository Gradle used, per published file name).

    Returns:
      The same addresses, each one of Maven Central followed by the same path on a mirror of it.
      Every other address is kept as it is.
    """
    out = []
    for url in urls:
        out.append(url)
        for central in _CENTRAL:
            if url.startswith(central):
                for mirror in _CENTRAL_MIRRORS:
                    out.append(mirror + url[len(central):])
    return [u for i, u in enumerate(out) if u not in out[:i]]

def unavailable(coordinate, file, sha256, urls):
    """The error for an artifact that no address gave, naming it, the addresses and what to do.

    Args:
      coordinate: the artifact as Gradle names it (`group:module:version`).
      file: the file name.
      sha256: the sha256 of the pin.
      urls: the addresses that were tried, in order.

    Returns:
      The message to fail with.
    """
    return (
        "android_model: cannot fetch the Maven artifact {coordinate} ({file}, sha256 {sha256}): " +
        "none of its {n} addresses gave a file with that sha256. Bazel printed each address's " +
        "answer as a WARNING above this error (429 means the server refuses too many requests, " +
        "and other bytes mean a mirror that is out of date or not a mirror).\n" +
        "Addresses tried, in order:\n{urls}\n" +
        "Try again later, or give Bazel another address for it: a downloader config " +
        "(`--downloader_config=<file>`) with a line `rewrite repo.maven.apache.org/maven2/(.*) " +
        "mirror.example.com/maven2/$1` asks your mirror for what Maven Central would give, or a " +
        "directory of files named as above (`--distdir=<dir>`). Whatever address answers, the " +
        "pin decides what is accepted: the sha256 above."
    ).format(
        coordinate = coordinate,
        file = file,
        sha256 = sha256,
        n = len(urls),
        urls = "\n".join(["  " + u for u in urls]),
    )
