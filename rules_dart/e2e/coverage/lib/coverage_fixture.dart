/// The production code `//:coverage_test` runs under `bazel coverage`.
///
/// Its line numbers are what `//:lcov_check` expects in the BUILD file: the
/// `exercised` line, the `unexercised` line, and the branch with one untaken
/// arm. Do not move them without changing the `args` there.
library;

/// Returns `-1`, `0` or `1` for the sign of [n]. The test only passes
/// positive numbers, so the `n < 0` arm is never taken.
int sign(int n) {
  if (n < 0) {
    return -1; // unexercised
  }
  return n == 0 ? 0 : 1; // exercised
}

/// Never called by any target, so the report holds `FNDA:0,neverCalledFixtureFunction`.
int neverCalledFixtureFunction() => 42;
