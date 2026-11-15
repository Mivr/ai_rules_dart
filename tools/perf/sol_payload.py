"""Verify set of the Android bundle configs (split out of sol.py).

``android_payload`` builds only the ``payload_apk`` output group, so its
verify set is that group's signed payload split and nothing else.
"""

PAYLOAD_CONFIG = "android_payload"


class EmptyListing(RuntimeError):
    """A cquery listing of a target's declared outputs held no file."""


def listed_outputs(config, target, query):
    """Runs the listing ``query``; an empty one of android_payload names it.

    The empty payload_apk group is the payload config's own failure (the
    build wrote no split to verify), not a generic cquery problem.
    """
    try:
        return query()
    except EmptyListing as exc:
        if config != PAYLOAD_CONFIG:
            raise
        raise RuntimeError(
            "sol found no payload split for %s (%s): the payload_apk "
            "group lists no files" % (PAYLOAD_CONFIG, target)) from exc


def android_bundle_archives(target_files):
    """Declared Android .apk or .aab archives among a target's outputs."""
    return sorted(path for path in target_files
                  if path.endswith(".apk") or path.endswith(".aab"))


def payload_split_archives(listed, target):
    """The signed ``<name>_payload.apk`` of the listed payload_apk group.

    Fails naming android_payload and the target when the listing holds no
    .apk, or any file that is not the payload split (the full APK or the
    base split would verify bytes this build never wrote).
    """
    wanted = target.rpartition(":")[2] + "_payload.apk"
    apks = [p for p in listed if p.endswith(".apk")]
    stray = [p for p in listed if p.rpartition("/")[2] != wanted]
    if not apks or stray:
        raise RuntimeError(
            "sol found no payload split for %s (%s): the payload_apk "
            "group must list only %s, got %s"
            % (PAYLOAD_CONFIG, target, wanted, sorted(listed) or "no files"))
    return sorted(listed)


def android_archives(config, listed, target):
    """Archives hashed for an Android config, or [] when none are declared."""
    if config == PAYLOAD_CONFIG:
        return payload_split_archives(listed, target)
    return android_bundle_archives(listed)
