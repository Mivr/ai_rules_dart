"""Small file-writing helper shared by the monorepo generator modules."""

import os


def write_plain(out_dir, rel, content):
    full = os.path.join(out_dir, rel)
    parent = os.path.dirname(full)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(full, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
