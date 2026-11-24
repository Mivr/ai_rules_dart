// The pin step: `bazel run //:android_pin`.
//
// Runs the app's own Gradle wrapper once, with the init script that dumps the model, and writes the pin
// file (android_model.json) beside the app's pubspec. Gradle evaluates the build files and resolves the
// Maven graph; nothing is compiled. The stock tools a Flutter Android developer has are needed (JDK,
// Android SDK, a Flutter SDK that has run `flutter pub get`), and the network for what Gradle has not
// resolved before. A build needs none of them.
package rules_flutter.android;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class Pin {
  private static void die(String message) {
    System.err.println("android_pin: " + message);
    System.exit(1);
  }

  public static void main(String[] args) throws Exception {
    String app = ".";
    String out = "android_model.json";
    String variants = "";
    String fallback = "";
    String init = null;
    boolean check = false;
    List<String> gradleArgs = new ArrayList<>();
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case "--app": app = args[++i]; break;
        case "--out": out = args[++i]; break;
        case "--variants": variants = args[++i]; break;
        case "--fallback": fallback = args[++i]; break;
        case "--init": init = args[++i]; break;
        case "--check": check = true; break;
        case "--": gradleArgs.addAll(Arrays.asList(args).subList(i + 1, args.length)); i = args.length; break;
        default: die("unknown argument " + args[i] + " (known: --check, --variants a,b, -- <gradle arguments>)");
      }
    }
    String ws = System.getenv("BUILD_WORKSPACE_DIRECTORY");
    if (ws == null) die("run this with `bazel run`");
    Path initScript = Paths.get(init).toAbsolutePath().normalize();
    Path appDir = Paths.get(ws).resolve(app).normalize();
    Path android = appDir.resolve("android");
    boolean windows = System.getProperty("os.name").toLowerCase().contains("windows");
    Path gradlew = android.resolve(windows ? "gradlew.bat" : "gradlew");
    if (!Files.isRegularFile(android.resolve("settings.gradle")) && !Files.isRegularFile(android.resolve("settings.gradle.kts"))) {
      die(android + " is not a Gradle project. The Android side is built from the app's stock Android project: create it with `flutter create --platforms=android .` in " + appDir);
    }
    Path local = android.resolve("local.properties");
    // `flutter pub get` writes what Gradle reads: the SDK paths, and the plugin list when there are plugins.
    Path config = appDir.resolve(".dart_tool").resolve("package_config.json");
    if (!Files.isRegularFile(local) || !Files.isRegularFile(config)) {
      die("run `flutter pub get` in " + appDir + " first: Gradle reads the plugin list and the SDK paths it writes");
    }
    if (!Files.isRegularFile(gradlew)) {
      // A stock project does not check the wrapper in; the Flutter tool copies it from its cache on
      // the first build. Do the same.
      java.util.Properties p = new java.util.Properties();
      try (java.io.InputStream in = Files.newInputStream(local)) {
        p.load(in);
      }
      Path cache = Paths.get(String.valueOf(p.getProperty("flutter.sdk")), "bin", "cache", "artifacts", "gradle_wrapper");
      if (!Files.isRegularFile(cache.resolve("gradlew"))) {
        die(android + " has no Gradle wrapper and " + cache + " has none to copy; run `flutter build apk --config-only` once");
      }
      for (String f : List.of("gradlew", "gradlew.bat", "gradle/wrapper/gradle-wrapper.jar")) {
        Path to = android.resolve(f);
        if (!Files.exists(to)) {
          Files.createDirectories(to.getParent());
          Files.copy(cache.resolve(f), to, java.nio.file.StandardCopyOption.COPY_ATTRIBUTES);
        }
      }
      gradlew.toFile().setExecutable(true);
    }
    Path target = appDir.resolve(out);
    Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
    Files.deleteIfExists(tmp);
    List<String> cmd = new ArrayList<>(List.of(
        gradlew.toString(), "-q", "-I", initScript.toString(), "rdfAndroidModel", "--no-configuration-cache",
        "-Prdf.out=" + tmp, "-Prdf.workspace=" + Paths.get(ws).toAbsolutePath().normalize()));
    if (!variants.isEmpty()) cmd.add("-Prdf.variants=" + variants);
    if (!fallback.isEmpty()) cmd.add("-Prdf.fallback=" + fallback);
    cmd.addAll(gradleArgs);
    ProcessBuilder pb = new ProcessBuilder(cmd).directory(android.toFile()).inheritIO();
    int rc = pb.start().waitFor();
    if (rc != 0 || !Files.isRegularFile(tmp) || Files.size(tmp) == 0) {
      Files.deleteIfExists(tmp);
      die("Gradle failed (exit " + rc + "); the pin file was not changed");
    }
    if (check) {
      boolean same = Files.isRegularFile(target) && Files.mismatch(tmp, target) == -1;
      Files.delete(tmp);
      if (!same) die(target + " is not what Gradle gives now; run the pin target without --check and commit the result");
      System.out.println("android_pin: " + target + " is current");
      return;
    }
    boolean changed = !Files.isRegularFile(target) || Files.mismatch(tmp, target) != -1;
    Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
    new File(target.toString()).setReadable(true, false);
    System.out.println("android_pin: " + (changed ? "wrote " : "unchanged: ") + target + (changed ? "; check it in" : ""));
  }
}
