// Checks built APKs: what they hold, how it is stored, and that they are signed. Used by the tests of
// the Android e2e workspaces (see apk_test.bzl); it reads the files a build produced, nothing else.
//
//   ApkCheck --apk app.apk [--split name=split.apk ...] [--class Lpkg/Name; ...] [--no-class ...]
//            [--entry path ...] [--no-entry glob ...] [--split-class name=Lpkg/Name; ...]
//            [--version-name 1.0.0] [--aapt2 path]
package rules_flutter.android.testing;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileSystems;
import java.nio.file.PathMatcher;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public final class ApkCheck {
  private static final List<String> failures = new ArrayList<>();

  private static void check(boolean ok, String message) {
    if (!ok) failures.add(message);
  }

  /** The class descriptors a dex file defines. */
  static List<String> dexClasses(byte[] dex) {
    ByteBuffer b = ByteBuffer.wrap(dex).order(ByteOrder.LITTLE_ENDIAN);
    int stringIdsOff = b.getInt(0x3c);
    int typeIdsOff = b.getInt(0x44);
    int classDefsSize = b.getInt(0x60);
    int classDefsOff = b.getInt(0x64);
    List<String> out = new ArrayList<>();
    for (int i = 0; i < classDefsSize; i++) {
      int type = b.getInt(classDefsOff + 32 * i);
      int off = b.getInt(stringIdsOff + 4 * b.getInt(typeIdsOff + 4 * type));
      while ((dex[off] & 0x80) != 0) off++; // the uleb128 length
      off++;
      int end = off;
      while (dex[end] != 0) end++;
      out.add(new String(dex, off, end - off, StandardCharsets.UTF_8));
    }
    return out;
  }

  private static final class Apk {
    final String path;
    final Map<String, ZipEntry> entries = new LinkedHashMap<>();
    final List<String> classes = new ArrayList<>();
    final Map<String, Long> dataOffsets = new HashMap<>();

    Apk(String path) throws Exception {
      this.path = path;
      try (ZipFile z = new ZipFile(path); RandomAccessFile raw = new RandomAccessFile(path, "r")) {
        // Local header offsets, from the central directory, for the alignment checks.
        long size = raw.length();
        byte[] tail = new byte[(int) Math.min(size, 65557)];
        raw.seek(size - tail.length);
        raw.readFully(tail);
        ByteBuffer t = ByteBuffer.wrap(tail).order(ByteOrder.LITTLE_ENDIAN);
        int eocd = tail.length - 22;
        while (eocd >= 0 && t.getInt(eocd) != 0x06054b50) eocd--;
        int count = t.getShort(eocd + 10) & 0xffff;
        long cdOffset = t.getInt(eocd + 16) & 0xffffffffL;
        byte[] cd = new byte[(int) (t.getInt(eocd + 12) & 0xffffffffL)];
        raw.seek(cdOffset);
        raw.readFully(cd);
        ByteBuffer c = ByteBuffer.wrap(cd).order(ByteOrder.LITTLE_ENDIAN);
        int p = 0;
        for (int i = 0; i < count; i++) {
          int n = c.getShort(p + 28) & 0xffff;
          int m = c.getShort(p + 30) & 0xffff;
          int k = c.getShort(p + 32) & 0xffff;
          long header = c.getInt(p + 42) & 0xffffffffL;
          String name = new String(cd, p + 46, n, StandardCharsets.UTF_8);
          byte[] local = new byte[30];
          raw.seek(header);
          raw.readFully(local);
          ByteBuffer l = ByteBuffer.wrap(local).order(ByteOrder.LITTLE_ENDIAN);
          dataOffsets.put(name, header + 30 + (l.getShort(26) & 0xffff) + (l.getShort(28) & 0xffff));
          p += 46 + n + m + k;
        }
        // The v2 signature is a block right before the central directory, ending with this magic.
        byte[] magic = new byte[16];
        raw.seek(cdOffset - 16);
        raw.readFully(magic);
        check(new String(magic, StandardCharsets.US_ASCII).equals("APK Sig Block 42"), path + " has no APK signature block (v2)");
        for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
          ZipEntry entry = e.nextElement();
          entries.put(entry.getName(), entry);
          if (entry.getName().matches("classes\\d*\\.dex")) {
            try (InputStream in = z.getInputStream(entry)) {
              classes.addAll(dexClasses(in.readAllBytes()));
            }
          }
        }
      }
    }
  }

  private static boolean synthetic(String cls) {
    return cls.contains("$$ExternalSynthetic") || cls.contains("$r8$") || cls.contains("/r8/");
  }

  public static void main(String[] args) throws Exception {
    Map<String, List<String>> opt = new HashMap<>();
    for (int i = 0; i + 1 < args.length; i += 2) opt.computeIfAbsent(args[i], k -> new ArrayList<>()).add(args[i + 1]);
    Apk apk = new Apk(opt.get("--apk").get(0));
    TreeSet<String> all = new TreeSet<>(apk.classes);
    check(all.size() == apk.classes.size(), apk.path + " defines " + (apk.classes.size() - all.size()) + " classes more than once");
    for (String c : opt.getOrDefault("--class", List.of())) check(all.contains(c), "class " + c + " is not in " + apk.path);
    for (String c : opt.getOrDefault("--no-class", List.of())) check(!all.contains(c), "class " + c + " is in " + apk.path);
    for (String e : opt.getOrDefault("--entry", List.of())) check(apk.entries.containsKey(e), "entry " + e + " is not in " + apk.path);
    for (String g : opt.getOrDefault("--no-entry", List.of())) {
      PathMatcher m = FileSystems.getDefault().getPathMatcher("glob:" + g);
      for (String e : apk.entries.keySet()) check(!m.matches(Paths.get(e)), "entry " + e + " (" + g + ") is in " + apk.path);
    }
    for (Map.Entry<String, ZipEntry> e : apk.entries.entrySet()) {
      String n = e.getKey();
      check(!n.endsWith(".class"), "class file " + n + " is in " + apk.path);
      if (n.startsWith("lib/") && n.endsWith(".so")) {
        // Native libraries are loaded from the APK: uncompressed and aligned to a 16 KB page.
        check(e.getValue().getMethod() == ZipEntry.STORED, n + " is compressed");
        check(apk.dataOffsets.get(n) % 16384 == 0, n + " is not aligned to 16 KB");
      } else if (e.getValue().getMethod() == ZipEntry.STORED) {
        check(apk.dataOffsets.get(n) % 4 == 0, n + " is stored and not aligned to 4 bytes");
      }
    }
    if (opt.containsKey("--version-name")) {
      Process p = new ProcessBuilder(opt.get("--aapt2").get(0), "dump", "badging", apk.path).redirectErrorStream(true).start();
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      p.getInputStream().transferTo(out);
      p.waitFor();
      String badging = out.toString(StandardCharsets.UTF_8);
      for (String v : opt.get("--version-name")) check(badging.contains("versionName='" + v + "'"), apk.path + " does not have versionName " + v + ": " + badging.lines().findFirst().orElse(""));
      for (String v : opt.getOrDefault("--version-code", List.of())) check(badging.contains("versionCode='" + v + "'"), apk.path + " does not have versionCode " + v);
    }

    // The splits: together the same app; each project's code in its own split.
    Map<String, Apk> splits = new LinkedHashMap<>();
    for (String s : opt.getOrDefault("--split", List.of())) {
      String[] kv = s.split("=", 2);
      splits.put(kv[0], new Apk(kv[1]));
    }
    if (!splits.isEmpty()) {
      TreeSet<String> inSplits = new TreeSet<>();
      TreeSet<String> entriesInSplits = new TreeSet<>();
      for (Apk s : splits.values()) {
        for (String c : s.classes) {
          check(synthetic(c) || inSplits.add(c), "class " + c + " is in two splits");
        }
        for (String e : s.entries.keySet()) {
          if (!e.equals("AndroidManifest.xml") && !e.matches("classes\\d*\\.dex")) entriesInSplits.add(e);
        }
      }
      TreeSet<String> wanted = new TreeSet<>(all);
      wanted.removeIf(ApkCheck::synthetic);
      inSplits.removeIf(ApkCheck::synthetic);
      TreeSet<String> missing = new TreeSet<>(wanted);
      missing.removeAll(inSplits);
      TreeSet<String> extra = new TreeSet<>(inSplits);
      extra.removeAll(wanted);
      check(missing.isEmpty(), missing.size() + " classes of the whole APK are in no split, for example " + missing.stream().limit(3).toList());
      check(extra.isEmpty(), extra.size() + " classes of the splits are not in the whole APK, for example " + extra.stream().limit(3).toList());
      TreeSet<String> wholeEntries = new TreeSet<>(apk.entries.keySet());
      wholeEntries.removeIf(e -> e.equals("AndroidManifest.xml") || e.matches("classes\\d*\\.dex"));
      check(wholeEntries.equals(entriesInSplits), "the splits and the whole APK hold different files: " + symmetric(wholeEntries, entriesInSplits));
      for (String sc : opt.getOrDefault("--split-class", List.of())) {
        String[] kv = sc.split("=", 2);
        for (Map.Entry<String, Apk> s : splits.entrySet()) {
          boolean has = s.getValue().classes.contains(kv[1]);
          check(has == s.getKey().equals(kv[0]), "class " + kv[1] + (has ? " is in split " : " is not in split ") + s.getKey());
        }
      }
      for (String se : opt.getOrDefault("--split-entry", List.of())) {
        String[] kv = se.split("=", 2);
        for (Map.Entry<String, Apk> s : splits.entrySet()) {
          boolean has = s.getValue().entries.containsKey(kv[1]);
          check(has == s.getKey().equals(kv[0]), "entry " + kv[1] + (has ? " is in split " : " is not in split ") + s.getKey());
        }
      }
    }
    if (!failures.isEmpty()) {
      for (String f : failures) System.err.println("FAIL: " + f);
      System.exit(1);
    }
    System.out.println("ok: " + all.size() + " classes, " + apk.entries.size() + " entries, " + splits.size() + " splits");
  }

  private static String symmetric(TreeSet<String> a, TreeSet<String> b) {
    TreeSet<String> onlyA = new TreeSet<>(a);
    onlyA.removeAll(b);
    TreeSet<String> onlyB = new TreeSet<>(b);
    onlyB.removeAll(a);
    return "only in the whole APK " + onlyA.stream().limit(3).toList() + ", only in the splits " + onlyB.stream().limit(3).toList();
  }
}
