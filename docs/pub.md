# `pub` root-wins precedence

One version per package stays the rule, and the root module picks it. A
dependency's `pub.package()` never changes the root's resolved version.

The root module pins a package two ways:

- declaring it with its own `pub.package(name, version, ...)`, or
- reading a lock that lists it with `pub.from_lock()` (a non-isolated hub;
  isolated hubs keep their own namespaced versions and never pin the global
  one).

A root lock's git entry pins like a hosted one: every non-root
`pub.package()` for that package is dropped at any version — a hosted
declaration never matches a git pin, even at the pin's own version string —
and the package resolves to the git spoke, with the package-named repository
generated as an alias to it:

```text
NOTE: Pub package "path" uses 1.4.0 from git 1111111111111111111111111111111111111111 in //:pubspec.lock, not 1.9.0 declared by module "dep_a".
```

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
conflict, not a choice: evaluation fails naming both values. A root pin
chooses only the version, never the hash: a dropped declaration still faces
every same-version sha256 check it would face without the pin, against every
other non-root declaration and every non-isolated lock entry at that version,
and fails with the same wording.

Under `on_version_conflict = "upgrade"` the resolved version can come from
another lock, and the NOTE names the version that actually resolves and the
lock it comes from, never the root lock's lower version:

```text
NOTE: Pub package "path" uses 1.9.1 from //:other.lock, not 1.9.0 declared by module "dep_a".
```

Whenever any module declares `pub.package()` for a package, the
package-named repository exists. A root `pub.package()` pin materializes it
directly. A root lock pin instead resolves the package through the locks,
and the package-named repository is generated as a thin alias to the lock
spoke `dart_pub__<name>` (or to the merged repository holding the whole
cycle, when the spoke merged away). The spoke stays the single
materialization: hubs alias it, the alias names it, and the package's
registry URL, archive hash and transitive dependencies all come from the
lock, which a second materialization could not reproduce.

Without a root pin, `pub.package()` behaves as before: the single
declaration applies, and disagreeing non-root declarations fail. Inside the
root nothing changes either: the root's own `pub.package()` still overrides
the root's own locks, disagreeing root declarations still fail, and the
root's own locks settle through the usual cross-lock rules first.
