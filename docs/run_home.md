# New runnable entry points

Every target `bazel run` accepts is registered in `e2e/run_home/registry.sh`
with its run arguments, its HOME policy (`private` or `caller-home`) and its
expected outcome, and `e2e/run_home/run_home_test.sh` runs each entry under a
fresh canary HOME on Linux CI. A commit that adds a runnable entry point —
a new rule or macro whose target `bazel run` accepts, a new public target, a
new compile mode — must register it there (or record it as refusing `bazel
run` with the reason), or CI goes red. Spawns of the Dart CLI in new
launchers and runners go through the two policies in
`dart/private/tools/private_home.dart`, never the caller's HOME directly.
