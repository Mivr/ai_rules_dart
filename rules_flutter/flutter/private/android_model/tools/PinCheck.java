// The stale-pin check: the pin file records the sha256 of the files it was computed from (the lock and
// the app's Gradle files). A build whose files differ fails here, with the command that pins again.
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
  /** `pincheck --out stamp --pin "<command>" --model <label> --input <path>=<sha256>=<file or empty> ...` */
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
    if (!changed.isEmpty()) {
      err.println(a.one("--model") + " is stale: it was written by Gradle for other contents of");
      for (String c : changed) err.println("  " + c);
      err.println("Pin again and commit the result:");
      err.println("  " + a.one("--pin"));
      return 1;
    }
    Path out = Paths.get(a.one("--out"));
    Files.writeString(out, "ok\n");
    return 0;
  }
}
