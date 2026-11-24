"""The resolution-variant directory rule, shared by every asset consumer.

Leaf module (it loads nothing) so the bundle action, the pub asset walk and
the pub mirror all apply one rule and none keeps a second copy of it.
"""

visibility(["//flutter/..."])

_DIGITS = "0123456789"

def _is_ratio(text):
    """True when `text` matches `\\d+(\\.\\d*)?` completely.

    Args:
        text: The candidate ratio, e.g. `2`, `2.5`, `2.`.

    Returns:
        True for one or more digits, optionally followed by `.` and more
        digits.
    """
    whole, dot, fraction = text.partition(".")
    if not whole or not dot and fraction:
        return False
    for char in (whole + fraction).elems():
        if char not in _DIGITS:
            return False
    return True

def _ratio_value(text):
    """The float value of one accepted ratio text (`2.` reads as 2.0).

    Args:
        text: A string `_is_ratio` accepted.

    Returns:
        The float ratio.
    """
    return float(text + "0" if text.endswith(".") else text)

def variant_dir_dpr(name):
    """The device-pixel ratio a directory name declares, or None.

    Mirrors flutter_tools 3.47.7 `_assetVariantDirectoryRegExp`
    (`asset.dart:111`, `/?(\\d+(\\.\\d*)?)x$`, applied to a directory
    basename at `asset.dart:1626`) and the manifest's own ratio read
    (`_extractPixelRatioFromKeyRegExp`, `asset.dart:935-947`): only the
    tail of the name matters, so the name must end in `x` and the leftmost
    run that matches `\\d+(\\.\\d*)?` up to the `x` is the ratio. `2x`, `2.0x`, `1.5x`, `2.5x`,
    `0.75x`, `1.0x` and `2.x` are variants; `sub`, `x`, `2xx` are not.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        The float ratio, or None when the name is not a variant directory.
    """
    if not name.endswith("x"):
        return None
    stem = name[:len(name) - 1]
    for start in range(len(stem)):
        if _is_ratio(stem[start:]):
            return _ratio_value(stem[start:])
    return None

def is_asset_variant_dir(name):
    """True when `name` is a resolution-variant directory, per flutter_tools.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        True when `variant_dir_dpr` reads a ratio from the name.
    """
    return variant_dir_dpr(name) != None

def parent_dir_dpr(key):
    """The ratio declared by one asset key's immediate parent directory.

    Args:
        key: A bundle key such as `assets/2.5x/icon.png`.

    Returns:
        The float ratio, or None when the key has no parent directory or
        the parent is not a variant directory.
    """
    parts = key.split("/")
    if len(parts) < 2:
        return None
    return variant_dir_dpr(parts[len(parts) - 2])
