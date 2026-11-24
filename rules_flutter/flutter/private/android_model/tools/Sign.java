// `bazel run //:app_release_sign`: signs what a release build left unsigned, with the user's key.
//
// A release key is a secret, and nothing in a build may hold one: not a checked-in file, not an
// attribute, not an action's command line or environment (both are in the action key and in the
// execution log), not a file under the output base. So the build's output is the aligned, unsigned
// APK (or bundle), and this program, which is run and not built, signs it with AGP's signer. It takes
// the key the way the stock tools' users already keep it:
//
//   - `android/key.properties` of the app (the file Flutter's deployment guide has the user write and
//     keep out of version control: storeFile, storePassword, keyAlias, keyPassword), or another file
//     named with `--key-properties`; or
//   - the environment, for CI: ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS,
//     ANDROID_KEY_PASSWORD (set from the CI system's secret store).
//
// The signed files are written where the stock tools put theirs (`build/app/outputs/...` of the app,
// outside Bazel's output base) or into `--out <directory>`. No value of the key is ever printed.
package rules_flutter.android;

import com.android.apksig.ApkSigner;
import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;

public final class Sign {
  private static void die(String message) {
    System.err.println("sign: " + message);
    System.exit(1);
  }

  public static void main(String[] args) throws Exception {
    String app = ".";
    String config = "release";
    String out = null;
    String keyProperties = null;
    int minSdk = 24;
    Boolean v1 = null;
    Boolean v2 = null;
    Boolean v3 = null;
    Map<String, Path> apks = new LinkedHashMap<>();
    Map<String, Path> bundles = new LinkedHashMap<>();
    // What to sign is the target's own (a system property its launcher sets); the command line adds
    // where to write and where the key is.
    List<String> all = new ArrayList<>();
    String fixed = System.getProperty("rules_flutter.sign");
    if (fixed != null && !fixed.isEmpty()) all.addAll(List.of(fixed.split(",")));
    all.addAll(List.of(args));
    args = all.toArray(new String[0]);
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case "--app": app = args[++i]; break;
        case "--config": config = args[++i]; break;
        case "--min-sdk": minSdk = Integer.parseInt(args[++i]); break;
        case "--v1": v1 = Boolean.parseBoolean(args[++i]); break;
        case "--v2": v2 = Boolean.parseBoolean(args[++i]); break;
        case "--v3": v3 = Boolean.parseBoolean(args[++i]); break;
        case "--apk": case "--bundle": {
          String[] kv = args[i + 1].split("=", 2);
          (args[i].equals("--apk") ? apks : bundles).put(kv[0], Paths.get(kv[1]).toAbsolutePath());
          i++;
          break;
        }
        case "--out": out = args[++i]; break;
        case "--key-properties": keyProperties = args[++i]; break;
        default: die("unknown argument " + args[i] + " (known: --out <directory>, --key-properties <file>)");
      }
    }
    String ws = System.getenv("BUILD_WORKSPACE_DIRECTORY");
    if (ws == null) die("run this with `bazel run`");
    Path cwd = Paths.get(System.getenv("BUILD_WORKING_DIRECTORY") != null ? System.getenv("BUILD_WORKING_DIRECTORY") : ws);
    Path appDir = Paths.get(ws).resolve(app).normalize();

    // The key: the environment first (CI), then key.properties.
    String storeFile = System.getenv("ANDROID_KEYSTORE_FILE");
    String storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD");
    String keyAlias = System.getenv("ANDROID_KEY_ALIAS");
    String keyPassword = System.getenv("ANDROID_KEY_PASSWORD");
    Path storeBase = cwd;
    String source = "the environment";
    if (storeFile == null) {
      Path file = keyProperties != null ? cwd.resolve(keyProperties) : appDir.resolve("android").resolve("key.properties");
      if (!Files.isRegularFile(file)) {
        die("no key to sign the `" + config + "` signing configuration's build with. Set ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, "
            + "ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD, or write " + appDir.resolve("android").resolve("key.properties")
            + " (storeFile, storePassword, keyAlias, keyPassword; keep it out of version control), or name such a file with --key-properties.");
      }
      Properties p = new Properties();
      try (InputStream in = Files.newInputStream(file)) {
        p.load(in);
      }
      storeFile = p.getProperty("storeFile");
      storePassword = p.getProperty("storePassword");
      keyAlias = p.getProperty("keyAlias");
      keyPassword = p.getProperty("keyPassword");
      // As the app's Gradle file reads it: `file(...)` in android/app.
      storeBase = keyProperties != null ? file.toAbsolutePath().getParent() : appDir.resolve("android").resolve("app");
      source = file.toString();
    }
    if (storeFile == null || storePassword == null || keyAlias == null) {
      die(source + " does not give the key store, its password and the key alias (storeFile, storePassword, keyAlias; "
          + "ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS)");
    }
    if (keyPassword == null) keyPassword = storePassword;
    Path store = storeBase.resolve(storeFile).normalize();
    if (!Files.isRegularFile(store)) die("the key store " + store + " (from " + source + ") does not exist");

    ApkSigner.SignerConfig signer = null;
    try {
      KeyStore ks = KeyStore.getInstance(store.toFile(), storePassword.toCharArray());
      PrivateKey pk = (PrivateKey) ks.getKey(keyAlias, keyPassword.toCharArray());
      if (pk == null) die("the key store " + store + " has no key `" + keyAlias + "`");
      List<X509Certificate> certs = new ArrayList<>();
      for (Certificate c : ks.getCertificateChain(keyAlias)) certs.add((X509Certificate) c);
      signer = new ApkSigner.SignerConfig.Builder(keyAlias.toUpperCase(Locale.ROOT), pk, certs).build();
    } catch (java.io.IOException | java.security.GeneralSecurityException e) {
      // The cause can quote what was typed; say only what failed.
      die("cannot open the key store " + store + " or its key `" + keyAlias + "` with the passwords from " + source);
    }

    Path outputs = appDir.resolve("build").resolve("app").resolve("outputs");
    // AGP's defaults for the schemes: JAR signing only below API 24, v2 always, v3 when asked for.
    boolean jar = v1 != null ? v1 : minSdk < 24;
    for (Map.Entry<String, Path> e : apks.entrySet()) {
      Path to = (out != null ? cwd.resolve(out) : outputs.resolve("flutter-apk")).resolve(e.getKey());
      Files.createDirectories(to.getParent());
      Apk.sign(signer, e.getValue(), to, minSdk, jar, v2 == null || v2, v3 != null && v3);
      System.out.println("sign: " + to);
    }
    for (Map.Entry<String, Path> e : bundles.entrySet()) {
      // A bundle is signed as a jar (the store re-signs the APKs it makes from it).
      Path to = out != null ? cwd.resolve(out).resolve(Paths.get(e.getKey()).getFileName()) : outputs.resolve("bundle").resolve(e.getKey());
      Files.createDirectories(to.getParent());
      new ApkSigner.Builder(List.of(signer))
          .setInputApk(e.getValue().toFile())
          .setOutputApk(to.toFile())
          .setMinSdkVersion(minSdk)
          .setV1SigningEnabled(true)
          .setV2SigningEnabled(false)
          .setV3SigningEnabled(false)
          .setV4SigningEnabled(false)
          .build()
          .sign();
      System.out.println("sign: " + to);
    }
  }
}
