# `pub` root-wins precedence

One version per package stays the rule, and the root module picks it. A
dependency's `pub.package()` never changes the root's resolved version.

The root module pins a hosted package two ways:

- declaring it with its own `pub.package(name, version, ...)`, or
- reading a lock that lists it with `pub.from_lock()` (a non-isolated hub;
  isolated hubs keep their own namespaced versions and never pin the global
  one).

When the root pins a package and a non-root module's `pub.package()`
declares another version, the root's version is the one resolved: every hub
aliases the package to the root's repository, and a module that `use_repo`s
the package by its `pub.package()` name keeps loading against the root's
version. Evaluation prints an informational NOTE naming the package, the
root's version and where it came from (the root's `pub.package()`, or the
lock's label), and each overridden version with the module that declared
it:

```text
NOTE: Pub package "path" uses 1.9.1 from the root module's pub.package(), not 1.9.0 declared by module "dep_a".
```

A non-root declaration that agrees with the pin is silent. A non-root
declaration at the pin's version with a different sha256 is an integrity
conflict, not a choice: evaluation fails naming both values.

Without a root pin, `pub.package()` behaves as before: the single
declaration applies, and disagreeing non-root declarations fail. Inside the
root nothing changes either: the root's own `pub.package()` still overrides
the root's own locks, disagreeing root declarations still fail, and the
root's own locks settle through the usual cross-lock rules first.
