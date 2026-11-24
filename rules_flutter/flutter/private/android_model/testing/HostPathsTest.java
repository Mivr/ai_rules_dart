// The form of a path handed to a native program (see HostPaths.java): what `aapt2 compile` needs on
// Windows, checked on any host by naming the separator.
package rules_flutter.android;

public final class HostPathsTest {
  private static int failures = 0;

  private static void expect(String what, String want, String got) {
    if (!want.equals(got)) {
      System.err.println("FAIL: " + what + ": expected " + want + ", got " + got);
      failures++;
    }
  }

  /** The resource directory as aapt2 reads it: the part before the last, split at the host's separator. */
  private static String resourceDirectory(String path, char separator) {
    String[] parts = path.split(java.util.regex.Pattern.quote(String.valueOf(separator)));
    return parts.length < 2 ? "bad resource path" : parts[parts.length - 2];
  }

  public static void main(String[] args) {
    String given = "external/am_core/x/res/drawable-hdpi-v4/ic_call_answer.png";
    // POSIX: as given.
    expect("posix form", given, HostPaths.forHost(given, '/'));
    expect("posix resource directory", "drawable-hdpi-v4", resourceDirectory(HostPaths.forHost(given, '/'), '/'));
    // Windows: the host's separator, so that the directory is found; as given it is not.
    expect("windows form", "external\\am_core\\x\\res\\drawable-hdpi-v4\\ic_call_answer.png", HostPaths.forHost(given, '\\'));
    expect("windows resource directory", "drawable-hdpi-v4", resourceDirectory(HostPaths.forHost(given, '\\'), '\\'));
    expect("windows, the path as Bazel gives it", "bad resource path", resourceDirectory(given, '\\'));
    // This host.
    expect("this host", given.replace('/', java.io.File.separatorChar), HostPaths.forHost(given));
    if (failures > 0) System.exit(1);
    System.out.println("ok");
  }
}
