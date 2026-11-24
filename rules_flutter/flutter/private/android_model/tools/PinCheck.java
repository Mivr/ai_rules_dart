// The stale-pin check: the pin file records the sha256 of the files it was computed from (the app's
// Gradle files) and, of the pub lock, what the Android side depends on: the plugins that have an
// Android side, with their versions. A build whose files or plugins differ fails here, with the
// command that pins again. The lock's other packages can change without a new pin.
package rules_flutter.android;

import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

final class PinCheck {
  /**
   * `pincheck --out stamp --pin "<command>" --model <label> --input <path>=<sha256>=<file or empty> ...
   * [--plugin-list <file> --plugin "<name> <version>" ...]`: `--plugin-list` is the build's own list
   * (`complete` or `partial`, then the plugins that have an Android side, a line each), `--plugin` the pin's.
   */
  static int run(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    List<String> changed = new ArrayList<>();
    for (String spec : a.all("--input")) {
      String[] p = spec.split("=", 3);
      if (p[2].isEmpty() || !Files.isRegularFile(Paths.get(p[2]))) {
        changed.add(p[0] + " (removed)");
        continue;
      }
      MessageDigest md = MessageDigest.getInstance("SHA-256");
      String sha = HexFormat.of().formatHex(md.digest(Files.readAllBytes(Paths.get(p[2]))));
      if (!sha.equals(p[1])) changed.add(p[0]);
    }
    List<String> plugins = new ArrayList<>();
    if (a.has("--plugin-list")) {
      java.util.Map<String, String> pinned = new java.util.TreeMap<>();
      for (String p : a.all("--plugin")) pinned.put(p.split(" ", 2)[0], p.contains(" ") ? p.split(" ", 2)[1] : "");
      java.util.Map<String, String> now = new java.util.TreeMap<>();
      // The first line says whether the list is every plugin of the app's lock (`complete`) or only
      // those the app depends on (`partial`: the pin may hold more).
      List<String> lines = Files.readAllLines(Paths.get(a.one("--plugin-list")));
      boolean complete = !lines.isEmpty() && lines.get(0).equals("complete");
      for (String line : lines.subList(Math.min(1, lines.size()), lines.size())) {
        if (!line.isBlank()) now.put(line.split(" ", 2)[0], line.contains(" ") ? line.split(" ", 2)[1] : "");
      }
      java.util.Set<String> names = new java.util.TreeSet<>(pinned.keySet());
      names.addAll(now.keySet());
      for (String name : names) {
        String was = pinned.get(name);
        String is = now.get(name);
        if (was == null) {
          plugins.add(name + " " + is + " (not in the pin)");
        } else if (is == null) {
          if (complete) plugins.add(name + " " + was + " (in the pin, no longer in pubspec.lock)");
        } else if (!was.equals(is) && !was.isEmpty() && !is.isEmpty()) {
          // A package whose target states no version (one the workspace writes itself) is known by name.
          plugins.add(name + " " + is + " (the pin has " + was + ")");
        }
      }
    }
    if (!changed.isEmpty() || !plugins.isEmpty()) {
      if (!changed.isEmpty()) {
        err.println(a.one("--model") + " is stale: it was written by Gradle for other contents of");
        for (String c : changed) err.println("  " + c);
      }
      if (!plugins.isEmpty()) {
        err.println(a.one("--model") + " is stale: pubspec.lock has other plugins with an Android side than it was written for");
        for (String p : plugins) err.println("  " + p);
      }
      err.println("Pin again and commit the result:");
      err.println("  " + a.one("--pin"));
      return 1;
    }
    Path out = Paths.get(a.one("--out"));
    Files.writeString(out, "ok\n");
    return 0;
  }
}
