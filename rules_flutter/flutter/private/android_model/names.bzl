"""Names derived from keys of the Android model."""

# The schema of the pin file these rules read (written by tools/model.init.gradle).
SCHEMA = 4

# The Android Gradle plugin versions the build tools are built and tested with (e2e workspaces): the
# floor the pinned Flutter release accepts, and the version its `flutter create` template names. The
# tools are compiled against the libraries of the AGP the pin names: R8, D8, L8 and trace references
# through the API R8 publishes, which holds from one version to the next; the resource compiler, the
# manifest merger, the R class writer and the baseline profile compiler through AGP's own classes,
# which need not.
AGP_TESTED = ("9.1.1", "9.3.1")

def _numbers(version):
    out = []
    for part in version.split("-")[0].split("."):
        out.append(int(part) if part.isdigit() else 0)
    return out

def agp_tested(version):
    """Whether an Android Gradle plugin version is within the range the tools are tested with.

    Args:
      version: the version a pin records (`tools.agp`), for example `9.3.1` or `9.4.0-alpha02`.

    Returns:
      True when it is at or above the first and at or below the last of `AGP_TESTED`.
    """
    v = _numbers(version)
    return _numbers(AGP_TESTED[0]) <= v and v <= _numbers(AGP_TESTED[1])

def _san(s):
    out = []
    for c in s.elems():
        out.append(c if (c.isalnum() or c in "_.-") else "_")
    return "".join(out)

def artifact_repo(path):
    """Repository name of a Maven artifact, from its repository-relative path."""
    return "am_" + _san(path.rsplit(".", 1)[0])

def artifact_target(path):
    """Target name stem of a Maven artifact in the hub."""
    return "m_" + _san(path.rsplit(".", 1)[0])

def project_target(project_path, variant):
    """Target name stem of one variant of a Gradle project."""
    return "p_" + _san(project_path.lstrip(":")).replace(".", "_").replace("-", "_") + "__" + _san(variant)
