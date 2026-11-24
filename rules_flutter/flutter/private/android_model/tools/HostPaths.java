// Paths for the native programs the tools start. Bazel names every file with `/`, and the JVM and
// most programs take that on any host. A program that reads something out of the path's text does
// not: `aapt2 compile` finds the resource directory (`drawable-hdpi-v4`) by splitting the path at the
// host's separator, so on Windows a path with `/` is one part and it says "bad resource path". AGP
// gives it `File.getAbsolutePath()`, the host's form.
package rules_flutter.android;

final class HostPaths {
  private HostPaths() {}

  /** `path` (as Bazel gives it, with `/`) in the form of a host whose separator is `separator`. */
  static String forHost(String path, char separator) {
    return separator == '/' ? path : path.replace('/', separator);
  }

  /** `path` in this host's form. */
  static String forHost(String path) {
    return forHost(path, java.io.File.separatorChar);
  }
}
