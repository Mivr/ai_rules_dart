"""Names derived from keys of the Android model."""

# The schema of the pin file these rules read (written by tools/model.init.gradle).
SCHEMA = 4

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
