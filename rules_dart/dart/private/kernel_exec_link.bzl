"""Pure helpers of an executable's kernel link."""

visibility(["//dart/..."])

def exec_base_dill(dep_kernels):
    """Finds the shared base dill among dependencies.

    Args:
      dep_kernels: The `DartKernelInfo` of each direct dependency.

    Returns:
      `(base_dill, base_keys, base_kmods)` of the first dependency that has one,
      else `(None, None, depset())`.
    """
    base_dill = None
    base_keys = None
    base_kmods = depset()
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            if base_dill == None:
                base_dill = kd
                base_keys = kk
                base_kmods = getattr(k, "base_kmods", depset())
                break
    return base_dill, base_keys, base_kmods

def exec_link_closure(dep_closure, base_dill, base_keys, base_kmods):
    """The dependency closure pruned of base-dill modules, when seeded.

    Args:
      dep_closure: Postorder depset of the dependency module directories.
      base_dill: The shared base `.dill` File, or None.
      base_keys: The `.keys` File of the base `.dill`, or None.
      base_kmods: Depset of the module directories the base `.dill` holds.

    Returns:
      `dep_closure`, less `base_kmods` when both `base_dill` and `base_keys` are set.
    """
    if base_dill == None or base_keys == None:
        return dep_closure
    pruned_paths = {f.path: True for f in base_kmods.to_list()}
    if not pruned_paths:
        return dep_closure
    return depset(
        [f for f in dep_closure.to_list() if f.path not in pruned_paths],
        order = "postorder",
    )
