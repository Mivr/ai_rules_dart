// The escape hatch: one plugin project built by Gradle itself.
//
// `gradle-aar --android <dir> --project :name --variant debug --init <script> --classes out.jar
//  --manifest out.xml --rtxt out.txt --res <dir> --assets <dir>`
//
// Runs the app's Gradle wrapper for that project's AAR and unpacks it into the declared outputs. It is
// what the model cannot express (a Gradle plugin that generates code, say) that makes a project take
// this path; everything else about the project (its classpath, its place in the app) still comes from
// the pin. Gradle runs with `--offline`: what it needs was resolved when the model was pinned.
package rules_flutter.android;

import java.io.File;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class GradleAar {
  static int run(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    Path android = Paths.get(a.one("--android")).toRealPath();
    boolean windows = System.getProperty("os.name").toLowerCase().contains("windows");
    Path gradlew = android.resolve(windows ? "gradlew.bat" : "gradlew");
    if (!Files.isRegularFile(gradlew) || !Files.isRegularFile(android.resolve("local.properties"))) {
      err.println("Gradle builds project " + a.one("--project") + " (gradle_fallback), and " + android
          + " is not ready for it: run `flutter pub get` there, and the pin target once (it puts the Gradle wrapper in place)");
      return 1;
    }
    Path aar = Paths.get(a.one("--classes")).toAbsolutePath().resolveSibling("fallback.aar");
    Files.deleteIfExists(aar);
    List<String> cmd = new ArrayList<>(List.of(
        gradlew.toString(), "-q", "--offline", "-I", Paths.get(a.one("--init")).toAbsolutePath().toString(),
        "rdfFallbackAar", "--no-configuration-cache",
        "-Prdf.fallback.project=" + a.one("--project"), "-Prdf.fallback.variant=" + a.one("--variant"),
        "-Prdf.fallback.out=" + aar));
    Process p = new ProcessBuilder(cmd).directory(android.toFile()).redirectErrorStream(true).start();
    String output = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    if (p.waitFor() != 0 || !Files.isRegularFile(aar)) {
      err.print(output);
      err.println("Gradle failed to build project " + a.one("--project") + " (gradle_fallback)");
      return 1;
    }
    Path res = Paths.get(a.one("--res"));
    Path assets = Paths.get(a.one("--assets"));
    Files.createDirectories(res);
    Files.createDirectories(assets);
    boolean classes = false;
    boolean rtxt = false;
    try (ZipFile z = new ZipFile(aar.toFile())) {
      for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
        ZipEntry entry = e.nextElement();
        String n = entry.getName();
        if (entry.isDirectory()) continue;
        Path to = null;
        if (n.equals("classes.jar")) {
          to = Paths.get(a.one("--classes"));
          classes = true;
        } else if (n.equals("AndroidManifest.xml")) {
          to = Paths.get(a.one("--manifest"));
        } else if (n.equals("R.txt")) {
          to = Paths.get(a.one("--rtxt"));
          rtxt = true;
        } else if (n.startsWith("res/")) {
          to = res.resolve(n.substring(4));
        } else if (n.startsWith("assets/")) {
          to = assets.resolve(n.substring(7));
        } else if (n.startsWith("jni/") || (n.startsWith("libs/") && n.endsWith(".jar"))) {
          err.println("project " + a.one("--project") + " (gradle_fallback): its AAR holds " + n
              + "; native libraries and bundled jars of a project built by Gradle are not packaged yet");
          return 1;
        }
        if (to == null) continue;
        if (to.getParent() != null) Files.createDirectories(to.getParent());
        try (InputStream in = z.getInputStream(entry)) {
          Files.copy(in, to, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
      }
    }
    if (!classes) {
      try (Apk.ZipWriter empty = new Apk.ZipWriter(Paths.get(a.one("--classes")))) {
        // A project without code: an empty jar.
      }
    }
    if (!rtxt) Files.writeString(Paths.get(a.one("--rtxt")), "");
    Files.delete(aar);
    return 0;
  }
}
