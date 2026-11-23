// `bazel run //:app_install`: installs the split APKs of a debug build and starts the app.
//
// Only what changed is sent. The device keeps a small list of what it has (split name and sha256, in
// /data/local/tmp); a split whose hash is the same is left alone, so after a Dart edit only the `dart`
// split travels and after a Kotlin edit only that project's split. The first install, a changed set of
// splits, or a device that lost the app, installs everything.
package rules_flutter.android;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Install {
  private static final List<String> adb = new ArrayList<>();

  private static void die(String message) {
    System.err.println("install: " + message);
    System.exit(1);
  }

  private static String sha256(Path p) throws Exception {
    MessageDigest md = MessageDigest.getInstance("SHA-256");
    try (InputStream in = Files.newInputStream(p)) {
      byte[] buf = new byte[1 << 20];
      for (int n; (n = in.read(buf)) > 0;) md.update(buf, 0, n);
    }
    return HexFormat.of().formatHex(md.digest());
  }

  /** Runs adb; returns its output, or null when it failed and `must` is false. */
  private static String run(boolean must, String... args) throws Exception {
    List<String> cmd = new ArrayList<>(adb);
    cmd.addAll(List.of(args));
    Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    p.getInputStream().transferTo(out);
    int rc = p.waitFor();
    String text = out.toString(StandardCharsets.UTF_8);
    if (rc != 0) {
      if (must) die(String.join(" ", cmd) + " failed:\n" + text);
      return null;
    }
    return text;
  }

  public static void main(String[] args) throws Exception {
    String pkg = null;
    boolean launch = true;
    Map<String, Path> splits = new LinkedHashMap<>();
    String serial = System.getenv("ANDROID_SERIAL");
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case "--package": pkg = args[++i]; break;
        case "--split": {
          String[] kv = args[++i].split("=", 2);
          splits.put(kv[0], Paths.get(kv[1]));
          break;
        }
        case "-s": case "--device": serial = args[++i]; break;
        case "--no-launch": launch = false; break;
        default: die("unknown argument " + args[i] + " (known: -s <device>, --no-launch)");
      }
    }
    String home = System.getenv("ANDROID_HOME") != null ? System.getenv("ANDROID_HOME") : System.getenv("ANDROID_SDK_ROOT");
    Path sdkAdb = home == null ? null : Paths.get(home, "platform-tools", System.getProperty("os.name").toLowerCase().contains("windows") ? "adb.exe" : "adb");
    adb.add(sdkAdb != null && Files.isExecutable(sdkAdb) ? sdkAdb.toString() : "adb");
    if (serial != null) adb.addAll(List.of("-s", serial));

    Map<String, String> now = new LinkedHashMap<>();
    for (Map.Entry<String, Path> s : splits.entrySet()) now.put(s.getKey(), sha256(s.getValue()));
    String state = "/data/local/tmp/rdf-install-" + pkg + ".txt";
    Map<String, String> had = new LinkedHashMap<>();
    String installed = run(false, "shell", "pm", "path", pkg);
    if (installed != null && installed.contains("package:")) {
      String text = run(false, "shell", "cat", state);
      if (text != null) {
        for (String line : text.split("\\R")) {
          String[] kv = line.trim().split(" ", 2);
          if (kv.length == 2) had.put(kv[0], kv[1]);
        }
      }
    }
    List<String> changed = new ArrayList<>();
    for (Map.Entry<String, String> s : now.entrySet()) {
      if (!s.getValue().equals(had.get(s.getKey()))) changed.add(s.getKey());
    }
    long t0 = System.nanoTime();
    boolean all = had.isEmpty() || !had.keySet().equals(now.keySet()) || changed.contains("base");
    if (changed.isEmpty()) {
      System.out.println("install: " + pkg + " is up to date on the device");
    } else {
      List<String> cmd = new ArrayList<>(List.of("install-multiple", "-r", "-t", "-d"));
      if (!all) cmd.addAll(List.of("-p", pkg));
      for (String name : all ? new ArrayList<>(now.keySet()) : changed) cmd.add(splits.get(name).toString());
      run(true, cmd.toArray(new String[0]));
      StringBuilder sb = new StringBuilder();
      for (Map.Entry<String, String> s : now.entrySet()) sb.append(s.getKey()).append(' ').append(s.getValue()).append('\n');
      Path tmp = Files.createTempFile("rdf-install", ".txt");
      Files.writeString(tmp, sb);
      run(true, "push", tmp.toString(), state);
      Files.delete(tmp);
      System.out.printf("install: %s: %s in %.2f s%n", pkg, all ? "all " + now.size() + " splits" : String.join(", ", changed), (System.nanoTime() - t0) / 1e9);
    }
    if (launch) {
      run(false, "shell", "am", "force-stop", pkg);
      run(true, "shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1");
    }
  }
}
