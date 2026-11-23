// A release build's code and resources, with AGP's own drivers.
//
//   r8   the whole program through R8 as AGP's R8 task runs it: `R8Tool.runR8` of AGP's builder
//        library, with the inputs that task gives it (read from an input dump of the stock build of AGP
//        9.1.0): the class jars as program, the merged Java resources, android.jar with the platform's
//        optional libraries and the lambda stubs as library, the compile-only jars as classpath, the
//        rule files of the app, of the library projects and of the Maven artifacts, the linked
//        resources in proto format (shrunk in the same run) and the baseline profile (rewritten).
//   l8   (in Dexing) calls `shrunkL8` here for a build that shrinks: the desugared library reduced to
//        what the app's final dex uses, as AGP's L8DexWorkAction does it (trace references, then L8).
package rules_flutter.android;

import com.android.builder.dexing.KeepRulesConfig;
import com.android.builder.dexing.L8OutputMode;
import com.android.builder.dexing.L8Tool;
import com.android.builder.dexing.MainDexListConfig;
import com.android.builder.dexing.ProguardConfig;
import com.android.builder.dexing.ProguardOutputFiles;
import com.android.builder.dexing.R8OutputType;
import com.android.builder.dexing.R8Tool;
import com.android.builder.dexing.ResourceShrinkingConfig;
import com.android.builder.dexing.ToolConfig;
import com.android.builder.dexing.TraceReferenceToolKt;
import com.android.ide.common.blame.Message;
import com.android.ide.common.blame.MessageReceiver;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class Release {
  private static List<Path> paths(List<String> names) {
    List<Path> out = new ArrayList<>();
    for (String n : names) out.add(Paths.get(n).toAbsolutePath());
    return out;
  }

  private static List<File> files(List<String> names) {
    List<File> out = new ArrayList<>();
    for (String n : names) out.add(new File(n).getAbsoluteFile());
    return out;
  }

  static void deleteTree(Path dir) throws IOException {
    if (!Files.exists(dir)) return;
    try (Stream<Path> s = Files.walk(dir)) {
      for (Path p : s.sorted(Comparator.reverseOrder()).toList()) Files.delete(p);
    }
  }

  /** A version as numbers, for the ranges of `META-INF/com.android.tools/r8-from-A-upto-B`. */
  private static int compareVersions(String a, String b) {
    String[] x = a.split("[.-]");
    String[] y = b.split("[.-]");
    for (int i = 0; i < Math.max(x.length, y.length); i++) {
      int p = i < x.length && x[i].matches("\\d+") ? Integer.parseInt(x[i]) : 0;
      int q = i < y.length && y[i].matches("\\d+") ? Integer.parseInt(y[i]) : 0;
      if (p != q) return Integer.compare(p, q);
    }
    return 0;
  }

  /**
   * The shrinker rules a jar carries, chosen as AGP chooses them: the files under
   * `META-INF/com.android.tools/r8[-from-A][-upto-B]/` whose range holds this R8 (from inclusive,
   * upto exclusive) when the jar has any such directory, otherwise those under `META-INF/proguard/`.
   */
  static List<Path> embeddedRules(Path jar, Path dir, String r8Version) throws IOException {
    List<Path> out = new ArrayList<>();
    try (ZipFile z = new ZipFile(jar.toFile())) {
      TreeMap<String, ZipEntry> tools = new TreeMap<>();
      TreeMap<String, ZipEntry> legacy = new TreeMap<>();
      boolean targeted = false;
      for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
        ZipEntry entry = e.nextElement();
        String n = entry.getName();
        if (entry.isDirectory()) continue;
        if (n.startsWith("META-INF/com.android.tools/")) {
          String[] parts = n.substring("META-INF/com.android.tools/".length()).split("/", 2);
          if (parts.length < 2 || !parts[0].startsWith("r8")) continue;
          targeted = true;
          String from = null;
          String upto = null;
          String[] words = parts[0].split("-");
          boolean ok = words[0].equals("r8");
          for (int i = 1; ok && i + 1 < words.length; i += 2) {
            if (words[i].equals("from")) from = words[i + 1];
            else if (words[i].equals("upto")) upto = words[i + 1];
            else ok = false;
          }
          if (!ok) continue;
          if (from != null && compareVersions(r8Version, from) < 0) continue;
          if (upto != null && compareVersions(r8Version, upto) >= 0) continue;
          tools.put(n, entry);
        } else if (n.startsWith("META-INF/proguard/")) {
          legacy.put(n, entry);
        }
      }
      for (ZipEntry entry : (targeted ? tools : legacy).values()) {
        Path to = dir.resolve(jar.getFileName().toString()).resolve(entry.getName());
        Files.createDirectories(to.getParent());
        try (InputStream in = z.getInputStream(entry)) {
          Files.write(to, in.readAllBytes());
        }
        out.add(to);
      }
    }
    return out;
  }

  static int r8(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--debuggable", "--no-minify", "--final-res-ids", "--no-full-mode", "--legacy-keep-rules"));
    Path dexOut = Paths.get(a.one("--out-dex")).toAbsolutePath();
    Path work = Files.createTempDirectory(dexOut.getParent(), "r8");
    try {
      int minApi = Integer.parseInt(a.one("--min-api"));
      String r8Version = com.android.tools.r8.Version.getVersionString().split(" ")[0];

      // The Java resources, merged under the app's packaging rules (AGP's mergeJavaResource), are
      // R8's to rewrite: service files follow renamed classes.
      Path javaResIn = work.resolve("java_res_in.jar");
      Apk.mergeJavaResources(javaResIn, a.all("--java-res"), a.all("--exclude"), a.all("--pick-first"), a.all("--merge"), Apk.DEFLATE_FAST);

      List<Path> configs = paths(a.all("--config"));
      Path rules = work.resolve("rules");
      for (String jar : a.all("--rules-jar")) configs.addAll(embeddedRules(Paths.get(jar).toAbsolutePath(), rules, r8Version));

      // The baseline profile: the profiles of the app and its libraries in one file (AGP's
      // mergeArtProfile), its wildcards expanded against the program (R8 reads exact rules only),
      // which R8 rewrites to the names and the synthetic classes of the shrunk program.
      Path profileMerged = Paths.get(a.one("--out-merged-profile")).toAbsolutePath();
      Path profileIn = work.resolve("baseline-prof.txt");
      Path profileOut = Paths.get(a.one("--out-profile")).toAbsolutePath();
      boolean hasProfile = mergeProfiles(a.all("--profile"), profileMerged);
      if (hasProfile) expandProfile(profileMerged, profileIn, a.all("--program"), err);

      Path dexDir = Files.createDirectories(work.resolve("dex"));
      Path javaResOut = Paths.get(a.one("--out-java-res")).toAbsolutePath();
      ProguardOutputFiles reports = new ProguardOutputFiles(
          Paths.get(a.one("--out-mapping")).toAbsolutePath(),
          work.resolve("mapping.prt"),
          Paths.get(a.one("--out-seeds")).toAbsolutePath(),
          Paths.get(a.one("--out-usage")).toAbsolutePath(),
          Paths.get(a.one("--out-config")).toAbsolutePath(),
          work.resolve("missing_rules.txt"));
      // AGP's R8Task: tree shaking and minification on, desugaring on, dex output; full mode and,
      // since AGP 9, keep rules read strictly (a kept class does not keep its default constructor),
      // unless the app's Gradle properties say otherwise.
      ToolConfig tool = new ToolConfig(
          minApi,
          a.has("--debuggable"),
          /* disableTreeShaking */ false,
          /* disableMinification */ a.has("--no-minify"),
          /* disableDesugaring */ false,
          /* fullMode */ !a.has("--no-full-mode"),
          /* strictFullModeForKeepRules */ !a.has("--legacy-keep-rules"),
          /* isolatedSplits */ Boolean.FALSE,
          R8OutputType.DEX,
          /* mainDexListDisallowed */ true);

      ResourceShrinkingConfig shrink = null;
      if (a.has("--resources")) {
        // The resource source files, for the keep rules XML files carry (`tools:keep`): AGP walks
        // the merged resource directory; here the directories of the libraries' own files.
        Set<File> dirs = new LinkedHashSet<>();
        for (String f : a.all("--res-file")) {
          if (!f.endsWith(".xml")) continue;
          File parent = new File(f).getAbsoluteFile().getParentFile();
          if (parent != null) dirs.add(parent);
        }
        shrink = new ResourceShrinkingConfig(
            files(a.all("--resources")),
            new ArrayList<>(dirs),
            List.of(),
            /* optimizedShrinking */ true,
            /* nonFinalResIds */ !a.has("--final-res-ids"),
            new File(a.one("--out-resources-log")).getAbsoluteFile(),
            files(a.all("--out-resources")),
            null);
      }

      List<String> problems = new ArrayList<>();
      MessageReceiver receiver = message -> {
        if (message.getKind() == Message.Kind.ERROR) problems.add(message.getText());
      };
      R8Tool.runR8(
          paths(a.all("--program")),
          dexDir,
          javaResIn,
          javaResOut,
          paths(a.all("--lib")),
          paths(a.all("--classpath")),
          tool,
          new ProguardConfig(configs, null, List.of(), reports),
          new MainDexListConfig(List.of(), List.of(), List.of(), null),
          shrink,
          receiver,
          List.of(),
          List.of(),
          null,
          null,
          a.has("--desugared-lib-config") ? Files.readString(Paths.get(a.one("--desugared-lib-config")), StandardCharsets.UTF_8) : null,
          hasProfile ? profileIn : null,
          hasProfile ? profileOut : null,
          null,
          Paths.get(a.one("--out-metadata")).toAbsolutePath(),
          null,
          null);
      for (String p : problems) err.println(p);

      // The dex files as one archive, in order.
      try (Apk.ZipWriter z = new Apk.ZipWriter(dexOut)) {
        TreeSet<Path> files = new TreeSet<>(Comparator.comparingInt((Path p) -> p.getFileName().toString().length()).thenComparing(p -> p.getFileName().toString()));
        try (Stream<Path> s = Files.list(dexDir)) {
          s.filter(p -> p.getFileName().toString().endsWith(".dex")).forEach(files::add);
        }
        int n = 0;
        for (Path f : files) {
          n++;
          z.add(n == 1 ? "classes.dex" : "classes" + n + ".dex", Files.readAllBytes(f), Apk.DEFLATE_DEFAULT, 4);
        }
      }
      for (String out : List.of("--out-seeds", "--out-usage", "--out-config", "--out-mapping", "--out-profile", "--out-merged-profile", "--out-metadata")) {
        Path p = Paths.get(a.one(out));
        if (!Files.exists(p)) Files.write(p, new byte[0]);
      }
      if (a.has("--out-resources-log") && !Files.exists(Paths.get(a.one("--out-resources-log")))) {
        Files.write(Paths.get(a.one("--out-resources-log")), new byte[0]);
      }
      if (!Files.exists(javaResOut)) {
        try (Apk.ZipWriter z = new Apk.ZipWriter(javaResOut)) {
          // No Java resources at all: an empty archive.
        }
      }
      return 0;
    } finally {
      deleteTree(work);
    }
  }

  /** Profile files joined as AGP's mergeArtProfile joins them; false when there is nothing. */
  static boolean mergeProfiles(List<String> files, Path out) throws IOException {
    List<String> texts = new ArrayList<>();
    for (String f : files) texts.add(Files.readString(Paths.get(f), StandardCharsets.UTF_8));
    Files.writeString(out, String.join("\n", texts), StandardCharsets.UTF_8);
    return !String.join("", texts).isBlank();
  }

  /** AGP's expandArtProfileWildcards: the rules with wildcards as the exact rules of these classes. */
  static void expandProfile(Path in, Path out, List<String> programJars, PrintStream err) {
    List<String> paths = new ArrayList<>();
    for (String jar : programJars) paths.add(Paths.get(jar).toAbsolutePath().toString());
    com.android.tools.profgen.ProfgenUtilsKt.expandWildcards(in.toString(), out.toString(), paths, message -> err.println("baseline profile: " + message));
  }

  /**
   * `artprofile --profile f ... --dex zip ... --out-prof f --out-profm f`: the baseline profile as
   * the binary files an APK carries in `assets/dexopt/` (AGP's compileArtProfile): the rules, already
   * in the names of the final dex, matched against the dex files in the order they are packaged.
   */
  static int artProfile(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    Path prof = Paths.get(a.one("--out-prof")).toAbsolutePath();
    Path merged = Files.createTempFile(prof.getParent(), "profile", ".txt");
    try {
      mergeProfiles(a.all("--profile"), merged);
      List<String> problems = new ArrayList<>();
      com.android.tools.profgen.HumanReadableProfile hrp =
          com.android.tools.profgen.HumanReadableProfileKt.HumanReadableProfile(merged.toFile(), problems::add);
      if (hrp == null) {
        err.println("the baseline profile cannot be read:");
        for (String p : problems) err.println("  " + p);
        return 1;
      }
      List<com.android.tools.profgen.DexFile> dexFiles = new ArrayList<>();
      for (String zip : a.all("--dex")) {
        try (ZipFile z = new ZipFile(zip)) {
          TreeSet<String> names = new TreeSet<>(Comparator.comparingInt(String::length).thenComparing(n -> n));
          for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
            String n = e.nextElement().getName();
            if (n.endsWith(".dex")) names.add(n);
          }
          for (String n : names) {
            int index = dexFiles.size() + 1;
            try (InputStream in = z.getInputStream(z.getEntry(n))) {
              dexFiles.add(com.android.tools.profgen.DexDataKt.DexFile(in, index == 1 ? "classes.dex" : "classes" + index + ".dex"));
            }
          }
        }
      }
      com.android.tools.profgen.ArtProfile profile = com.android.tools.profgen.ArtProfileKt.ArtProfile(
          hrp, com.android.tools.profgen.ObfuscationMap.Companion.getEmpty(), dexFiles, "");
      try (java.io.OutputStream os = Files.newOutputStream(prof)) {
        profile.save(os, com.android.tools.profgen.ArtProfileSerializer.V0_1_0_P);
      }
      try (java.io.OutputStream os = Files.newOutputStream(Paths.get(a.one("--out-profm")))) {
        profile.save(os, com.android.tools.profgen.ArtProfileSerializer.METADATA_0_0_2);
      }
      return 0;
    } finally {
      Files.deleteIfExists(merged);
    }
  }

  /**
   * The desugared core library shrunk to what the app's final dex uses, as AGP's L8DexWorkAction:
   * the library desugared to class files, the references of the app's dex into it traced to keep
   * rules, then L8 with those rules. With a baseline profile, its rules for the library are
   * rewritten by L8 as R8 rewrites the app's.
   */
  static void shrunkL8(List<Path> jars, String config, List<Path> boot, int minApi, boolean debuggable, List<Path> appDex, Path mapping, Path mappingOut, Path profileIn, Path profileOut, Path outDir, Path work, PrintStream err) throws Exception {
    Path classes = Files.createDirectories(work.resolve("desugared"));
    L8Tool.runL8(jars, classes, config, boot, minApi, new KeepRulesConfig(List.of(), List.of()), debuggable, L8OutputMode.ClassFile, null, null, null, null);
    List<Path> desugared = new ArrayList<>();
    try (Stream<Path> s = Files.list(classes)) {
      s.filter(p -> p.getFileName().toString().endsWith(".jar")).sorted().forEach(desugared::add);
    }
    Path dexDir = Files.createDirectories(work.resolve("appdex"));
    List<Path> dexFiles = new ArrayList<>();
    for (Path zip : appDex) {
      try (ZipFile z = new ZipFile(zip.toFile())) {
        for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
          ZipEntry entry = e.nextElement();
          if (!entry.getName().endsWith(".dex")) continue;
          Path to = dexDir.resolve(dexFiles.size() + "-" + entry.getName());
          try (InputStream in = z.getInputStream(entry)) {
            Files.write(to, in.readAllBytes());
          }
          dexFiles.add(to);
        }
      }
    }
    Path keep = work.resolve("keep_rules.txt");
    TraceReferenceToolKt.runTraceReferenceTool(boot, desugared, dexFiles, keep);
    Path expanded = null;
    if (profileIn != null && Files.size(profileIn) > 0) {
      expanded = work.resolve("l8-baseline-prof.txt");
      List<String> paths = new ArrayList<>();
      for (Path p : desugared) paths.add(p.toString());
      expandProfile(profileIn, expanded, paths, err);
    }
    L8Tool.runL8(jars, outDir, config, boot, minApi, new KeepRulesConfig(List.of(keep), List.of()), debuggable, L8OutputMode.DexIndexed,
        expanded, expanded != null ? profileOut : null, mapping, mappingOut);
    if (mappingOut != null && !Files.exists(mappingOut)) Files.copy(mapping, mappingOut);
    if (profileOut != null && !Files.exists(profileOut)) Files.write(profileOut, new byte[0]);
  }
}
