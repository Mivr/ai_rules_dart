// The test of `bazel run //:<app>_sign`: makes a key store (the JDK's keytool, a password drawn here),
// runs the sign programs of the app with that key in their environment, as a CI job would, and checks
// what they wrote: the APK carries a v2 signature block with the certificate of that key, the bundle
// verifies as a jar signed with it, and neither password is in what the programs printed.
//
//   SignCheck --sign <app>_sign launcher --bundle-sign <app>_bundle_sign launcher
package rules_flutter.android.testing;

import java.io.File;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Stream;

public final class SignCheck {
  private static void fail(String message) {
    System.err.println("FAIL: " + message);
    System.exit(1);
  }

  private static String secret() {
    byte[] b = new byte[16];
    new SecureRandom().nextBytes(b);
    return HexFormat.of().formatHex(b);
  }

  /** Runs a program; returns what it printed. Fails the test when it fails. */
  private static String run(List<String> command, Map<String, String> env, String what) throws Exception {
    ProcessBuilder pb = new ProcessBuilder(command).redirectErrorStream(true);
    pb.environment().putAll(env);
    Process p = pb.start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    if (p.waitFor() != 0) fail(what + " failed:\n" + out);
    return out;
  }

  private static boolean contains(byte[] haystack, byte[] needle) {
    outer:
    for (int i = 0; i + needle.length <= haystack.length; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /** The APK Signing Block (what is between the entries and the central directory), or null. */
  private static byte[] signingBlock(Path apk) throws Exception {
    try (RandomAccessFile raw = new RandomAccessFile(apk.toFile(), "r")) {
      byte[] tail = new byte[(int) Math.min(raw.length(), 65557)];
      raw.seek(raw.length() - tail.length);
      raw.readFully(tail);
      int eocd = tail.length - 22;
      while (eocd >= 0 && ByteBuffer.wrap(tail, eocd, 4).order(ByteOrder.LITTLE_ENDIAN).getInt() != 0x06054b50) eocd--;
      if (eocd < 0) fail(apk + " is not a zip file");
      long cd = ByteBuffer.wrap(tail, eocd + 16, 4).order(ByteOrder.LITTLE_ENDIAN).getInt() & 0xffffffffL;
      byte[] footer = new byte[24];
      if (cd < 32) return null;
      raw.seek(cd - 24);
      raw.readFully(footer);
      if (!new String(footer, 8, 16, StandardCharsets.US_ASCII).equals("APK Sig Block 42")) return null;
      long size = ByteBuffer.wrap(footer, 0, 8).order(ByteOrder.LITTLE_ENDIAN).getLong();
      byte[] block = new byte[(int) size + 8];
      raw.seek(cd - block.length);
      raw.readFully(block);
      return block;
    }
  }

  public static void main(String[] args) throws Exception {
    String sign = null;
    String bundleSign = null;
    for (int i = 0; i + 1 < args.length; i += 2) {
      if (args[i].equals("--sign")) sign = args[i + 1];
      if (args[i].equals("--bundle-sign")) bundleSign = args[i + 1];
    }
    Path tmp = Files.createTempDirectory(Paths.get(System.getenv("TEST_TMPDIR")), "sign");
    Path store = tmp.resolve("test.p12");
    String storePassword = secret();
    String alias = "rdfsigntest";

    // 1. A key store made here, for this run only. keytool reads the password from its environment.
    String keytool = Paths.get(System.getProperty("java.home"), "bin", "keytool").toString();
    run(List.of(keytool, "-genkeypair", "-keystore", store.toString(), "-storetype", "PKCS12", "-storepass:env", "RDF_STORE_PASSWORD",
        "-alias", alias, "-keyalg", "RSA", "-keysize", "2048", "-validity", "2", "-dname", "CN=rules_flutter sign test"),
        Map.of("RDF_STORE_PASSWORD", storePassword), "keytool");
    KeyStore ks = KeyStore.getInstance(store.toFile(), storePassword.toCharArray());
    Certificate certificate = ks.getCertificate(alias);
    byte[] der = certificate.getEncoded();

    // 2. The sign programs, with the key in the environment (as `bazel run` in CI gives it to them).
    Path workspace = Files.createDirectories(tmp.resolve("workspace"));
    Path out = tmp.resolve("out");
    Map<String, String> env = Map.of(
        "BUILD_WORKSPACE_DIRECTORY", workspace.toString(),
        "BUILD_WORKING_DIRECTORY", tmp.toString(),
        "ANDROID_KEYSTORE_FILE", store.toString(),
        "ANDROID_KEYSTORE_PASSWORD", storePassword,
        "ANDROID_KEY_ALIAS", alias,
        "ANDROID_KEY_PASSWORD", storePassword);
    String printed = run(List.of(new File(sign).getAbsolutePath(), "--out", out.toString()), env, "the sign program")
        + run(List.of(new File(bundleSign).getAbsolutePath(), "--out", out.toString()), env, "the bundle sign program");
    if (printed.contains(storePassword)) fail("a sign program printed the password of the key store");

    List<Path> apks = new ArrayList<>();
    List<Path> bundles = new ArrayList<>();
    try (Stream<Path> files = Files.walk(out)) {
      for (Path f : files.filter(Files::isRegularFile).sorted().toList()) {
        if (f.toString().endsWith(".apk")) apks.add(f);
        if (f.toString().endsWith(".aab")) bundles.add(f);
      }
    }
    if (apks.isEmpty()) fail("the sign program wrote no APK into " + out + ": " + printed);
    if (bundles.isEmpty()) fail("the bundle sign program wrote no bundle into " + out + ": " + printed);

    // 3. Each APK: a v2 signature (block id 0x7109871a) that carries the certificate of the key.
    for (Path apk : apks) {
      byte[] block = signingBlock(apk);
      if (block == null) fail(apk + " has no APK signature block");
      boolean v2 = false;
      for (int at = 8; at + 12 <= block.length - 24;) {
        long length = ByteBuffer.wrap(block, at, 8).order(ByteOrder.LITTLE_ENDIAN).getLong();
        if (ByteBuffer.wrap(block, at + 8, 4).order(ByteOrder.LITTLE_ENDIAN).getInt() == 0x7109871a) v2 = true;
        at += 8 + (int) length;
      }
      if (!v2) fail(apk + " has no v2 signature");
      if (!contains(block, der)) fail(apk + " is not signed with the key of the test's key store");
    }

    // 4. Each bundle: every entry verifies as signed, by that certificate (a bundle is signed as a jar).
    for (Path bundle : bundles) {
      int verified = 0;
      try (JarFile jar = new JarFile(bundle.toFile(), true)) {
        byte[] buffer = new byte[1 << 16];
        for (Enumeration<JarEntry> e = jar.entries(); e.hasMoreElements();) {
          JarEntry entry = e.nextElement();
          if (entry.isDirectory() || entry.getName().startsWith("META-INF/")) continue;
          try (InputStream in = jar.getInputStream(entry)) {
            while (in.read(buffer) >= 0) {
            }
          }
          Certificate[] signers = entry.getCertificates();
          if (signers == null || signers.length == 0) fail(bundle + ": entry " + entry.getName() + " is not signed");
          if (!Arrays.equals(signers[0].getEncoded(), der)) fail(bundle + ": entry " + entry.getName() + " is signed with another key");
          verified++;
        }
      }
      if (verified == 0) fail(bundle + " has no entries");
    }
    System.out.println("ok: " + apks.size() + " APK(s) and " + bundles.size() + " bundle(s) signed with the key made in this test");
  }
}
