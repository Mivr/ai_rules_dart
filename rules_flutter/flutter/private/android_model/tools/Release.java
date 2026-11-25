// A release build's code and resources, through the API that R8 publishes.
//
//   r8   the whole program through R8 as AGP's R8 task runs it. The command is built with
//        `R8Command.builder()` and carries what AGP's own driver (`R8Tool.runR8` of its builder
//        library, read in AGP 9.1.1 and 9.3.1) puts on it for an app without feature modules: the
//        class jars as program, the merged Java resources as data, android.jar with the platform's
//        optional libraries and the lambda stubs as library, the compile-only jars as classpath,
//        the rule files of the app, of the library projects and of the Maven artifacts, the linked
//        resources in proto format (shrunk in the same run) and the baseline profile (rewritten).
//   l8   (in Dexing) calls `shrunkL8` here for a build that shrinks: the desugared library reduced to
//        what the app's final dex uses, as AGP's L8DexWorkAction does it (trace references, then L8).
//
// Nothing here names a class of AGP's builder library: its configuration classes change from one
// AGP to the next (9.3 gave `ResourceShrinkingConfig` and `ProguardConfig` other constructors), and
// the tool is compiled against the R8 the pin names. What AGP 9.3 adds to the command and this
// tool does not: an origin for every rule file (only diagnostics name it) and two reports of R8's
// rule analysis (files in Gradle's build directory that no step reads).
package rules_flutter.android;

import com.android.tools.r8.AndroidResourceInput;
import com.android.tools.r8.AndroidResourceProvider;
import com.android.tools.r8.ArchiveProgramResourceProvider;
import com.android.tools.r8.ArchiveProtoAndroidResourceConsumer;
import com.android.tools.r8.ArchiveProtoAndroidResourceProvider;
import com.android.tools.r8.AssertionsConfiguration;
import com.android.tools.r8.BaseCompilerCommand;
import com.android.tools.r8.ClassFileConsumer;
import com.android.tools.r8.CompilationMode;
import com.android.tools.r8.DataDirectoryResource;
import com.android.tools.r8.DataEntryResource;
import com.android.tools.r8.DataResourceConsumer;
import com.android.tools.r8.DataResourceProvider;
import com.android.tools.r8.Diagnostic;
import com.android.tools.r8.DiagnosticsHandler;
import com.android.tools.r8.DexIndexedConsumer;
import com.android.tools.r8.L8;
import com.android.tools.r8.L8Command;
import com.android.tools.r8.ProgramResource;
import com.android.tools.r8.ProgramResourceProvider;
import com.android.tools.r8.R8;
import com.android.tools.r8.R8Command;
import com.android.tools.r8.ResourcePath;
import com.android.tools.r8.StringConsumer;
import com.android.tools.r8.TextInputStream;
import com.android.tools.r8.TextOutputStream;
import com.android.tools.r8.origin.Origin;
import com.android.tools.r8.origin.PathOrigin;
import com.android.tools.r8.profile.art.ArtProfileBuilder;
import com.android.tools.r8.profile.art.ArtProfileConsumer;
import com.android.tools.r8.profile.art.ArtProfileProvider;
import com.android.tools.r8.tracereferences.TraceReferences;
import com.android.tools.r8.tracereferences.TraceReferencesCommand;
import com.android.tools.r8.tracereferences.TraceReferencesKeepRules;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collection;
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
import java.util.zip.ZipOutputStream;

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

  /** R8's errors, collected; its warnings and notes are about library code and not the user's to fix. */
  private static final class Problems implements DiagnosticsHandler {
    final List<String> errors = new ArrayList<>();

    @Override
    public synchronized void error(Diagnostic d) {
      String where = d.getOrigin() == null || d.getOrigin() == Origin.unknown() ? "" : d.getOrigin() + ": ";
      errors.add(where + d.getDiagnosticMessage());
    }

    @Override
    public void warning(Diagnostic d) {}

    @Override
    public void info(Diagnostic d) {}
  }

  /** Whether a Java resource is a shrinker rule file a jar carries: R8 gets those as rule files, not as data. */
  private static boolean embeddedRule(String name) {
    String n = name.toLowerCase(java.util.Locale.US);
    return n.startsWith("meta-inf/proguard/") || n.startsWith("/meta-inf/proguard/")
        || n.startsWith("meta-inf/com.android.tools/") || n.startsWith("/meta-inf/com.android.tools/");
  }

  /** The merged Java resources as data of the program: R8 rewrites what names classes (service files). */
  private static final class JavaResources implements ProgramResourceProvider, DataResourceProvider, AutoCloseable {
    private final Path jar;
    private final ZipFile zip;

    JavaResources(Path jar) throws IOException {
      this.jar = jar;
      this.zip = new ZipFile(jar.toFile());
    }

    @Override
    public Collection<ProgramResource> getProgramResources() {
      return List.of();
    }

    @Override
    public DataResourceProvider getDataResourceProvider() {
      return this;
    }

    @Override
    public void accept(DataResourceProvider.Visitor visitor) {
      for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements();) {
        ZipEntry entry = e.nextElement();
        if (entry.isDirectory()) {
          visitor.visit(DataDirectoryResource.fromZip(zip, entry));
        } else if (!entry.getName().endsWith(".class") && !embeddedRule(entry.getName())) {
          visitor.visit(DataEntryResource.fromZip(zip, entry));
        }
      }
    }

    @Override
    public void close() throws IOException {
      zip.close();
    }
  }

  /** The Java resources R8 gives back, as a jar. */
  private static final class JavaResourcesOut implements DataResourceConsumer, AutoCloseable {
    private final Path jar;
    private ZipOutputStream out;

    JavaResourcesOut(Path jar) {
      this.jar = jar;
    }

    private void put(String name, byte[] content) throws IOException {
      if (out == null) out = new ZipOutputStream(Files.newOutputStream(jar));
      ZipEntry entry = new ZipEntry(name);
      entry.setTime(0);
      out.putNextEntry(entry);
      if (content != null) out.write(content);
      out.closeEntry();
    }

    @Override
    public synchronized void accept(DataDirectoryResource directory, DiagnosticsHandler handler) {
      try {
        put(directory.getName() + "/", null);
      } catch (IOException e) {
        throw new java.io.UncheckedIOException(e);
      }
    }

    @Override
    public synchronized void accept(DataEntryResource file, DiagnosticsHandler handler) {
      try (InputStream in = file.getByteStream()) {
        put(file.getName(), in.readAllBytes());
      } catch (IOException | com.android.tools.r8.ResourceException e) {
        throw new RuntimeException(e);
      }
    }

    @Override
    public void finished(DiagnosticsHandler handler) {}

    @Override
    public synchronized void close() throws IOException {
      if (out != null) out.close();
    }
  }

  /** A keep-rules XML file of the resources (`tools:keep`), which R8's resource shrinker reads. */
  private static final class KeepRulesXml implements AndroidResourceInput {
    private final Path file;

    KeepRulesXml(Path file) {
      this.file = file;
    }

    @Override
    public Origin getOrigin() {
      return new PathOrigin(file);
    }

    @Override
    public ResourcePath getPath() {
      return () -> file.toString();
    }

    @Override
    public AndroidResourceInput.Kind getKind() {
      return AndroidResourceInput.Kind.KEEP_RULE_FILE;
    }

    @Override
    public InputStream getByteStream() {
      try {
        return new java.io.ByteArrayInputStream(Files.readAllBytes(file));
      } catch (IOException e) {
        throw new java.io.UncheckedIOException(e);
      }
    }
  }

  /** A baseline profile in its text form for R8 or L8 to rewrite, and where the rewritten one goes. */
  private static void rewriteProfile(BaseCompilerCommand.Builder<?, ?> builder, Path in, Path out) {
    ArtProfileProvider provider = new ArtProfileProvider() {
      @Override
      public void getArtProfile(ArtProfileBuilder profile) {
        profile.addHumanReadableArtProfile(
            new TextInputStream() {
              @Override
              public InputStream getInputStream() {
                try {
                  return Files.newInputStream(in);
                } catch (IOException e) {
                  throw new java.io.UncheckedIOException(e);
                }
              }

              @Override
              public Charset getCharset() {
                return StandardCharsets.UTF_8;
              }
            },
            parser -> {});
      }

      @Override
      public Origin getOrigin() {
        return new PathOrigin(in);
      }
    };
    ArtProfileConsumer consumer = new ArtProfileConsumer() {
      @Override
      public TextOutputStream getHumanReadableArtProfileConsumer() {
        return new TextOutputStream() {
          @Override
          public OutputStream getOutputStream() {
            try {
              return Files.newOutputStream(out);
            } catch (IOException e) {
              throw new java.io.UncheckedIOException(e);
            }
          }

          @Override
          public Charset getCharset() {
            return StandardCharsets.UTF_8;
          }
        };
      }

      @Override
      public void finished(DiagnosticsHandler handler) {}
    };
    builder.addArtProfileForRewriting(provider, consumer);
  }

  static int r8(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--debuggable", "--no-minify", "--no-full-mode", "--legacy-keep-rules"));
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
      Path mapping = Paths.get(a.one("--out-mapping")).toAbsolutePath();
      Path metadata = Paths.get(a.one("--out-metadata")).toAbsolutePath();

      Problems problems = new Problems();
      R8Command.Builder b = R8Command.builder(problems);
      b.setBuildMetadataConsumer(record -> {
        try {
          Files.writeString(metadata, record.toJson(), StandardCharsets.UTF_8);
        } catch (IOException e) {
          throw new java.io.UncheckedIOException(e);
        }
      });
      // AGP's R8Task for an app: dex output for the app's minSdk (native multidex, so no main dex
      // list), desugaring on, tree shaking on, minification unless the rules say otherwise; full
      // mode and, since AGP 9, keep rules read strictly (a kept class does not keep its default
      // constructor), unless the app's Gradle properties say otherwise.
      b.setMinApiLevel(minApi);
      if (a.has("--desugared-lib-config")) {
        b.addSpecialLibraryConfiguration(Files.readString(Paths.get(a.one("--desugared-lib-config")), StandardCharsets.UTF_8));
      }
      if (a.has("--debuggable")) b.addAssertionsConfiguration(AssertionsConfiguration.Builder::compileTimeEnableAllAssertions);
      b.addProguardConfigurationFiles(configs);
      Files.createDirectories(mapping.getParent());
      b.setProguardMapOutputPath(mapping);
      b.setPartitionMapOutputPath(work.resolve("mapping.prt"));
      b.setProguardSeedsConsumer(new StringConsumer.FileConsumer(Paths.get(a.one("--out-seeds")).toAbsolutePath()));
      b.setProguardUsageConsumer(new StringConsumer.FileConsumer(Paths.get(a.one("--out-usage")).toAbsolutePath()));
      b.setProguardConfigurationConsumer(new StringConsumer.FileConsumer(Paths.get(a.one("--out-config")).toAbsolutePath()));
      b.setMode(a.has("--debuggable") ? CompilationMode.DEBUG : CompilationMode.RELEASE);
      b.setDisableTreeShaking(false);
      b.setDisableMinification(a.has("--no-minify"));
      b.setDisableDesugaring(false);
      b.setEnableVerboseSyntheticNames(true);
      b.setProguardCompatibility(a.has("--no-full-mode"));
      b.enableLegacyFullModeForKeepRules(a.has("--legacy-keep-rules"));
      b.setEnableIsolatedSplits(false);
      b.setEnableExperimentalMissingLibraryApiModeling(true);
      for (Path jar : paths(a.all("--program"))) b.addProgramResourceProvider(ArchiveProgramResourceProvider.fromArchive(jar));
      b.addLibraryFiles(paths(a.all("--lib")));
      b.addClasspathFiles(paths(a.all("--classpath")));
      if (hasProfile) rewriteProfile(b, profileIn, profileOut);

      if (a.has("--resources")) {
        // Resource shrinking in the same run, as AGP sets it up: each linked resource archive (proto
        // format) with the file its shrunk form goes to, and the keep rules XML files carry
        // (`tools:keep`), which AGP takes from the merged resource directory; here from the
        // directories of the libraries' own files.
        List<File> linked = files(a.all("--resources"));
        List<File> shrunk = files(a.all("--out-resources"));
        for (int i = 0; i < linked.size(); i++) {
          Path in = linked.get(i).toPath();
          Path out = shrunk.get(i).toPath();
          b.addFeatureSplit(split -> split
              .setAndroidResourceProvider(new ArchiveProtoAndroidResourceProvider(in))
              .setAndroidResourceConsumer(new ArchiveProtoAndroidResourceConsumer(out))
              .setProgramConsumer(DexIndexedConsumer.emptyConsumer())
              .build());
        }
        Set<Path> dirs = new LinkedHashSet<>();
        for (String f : a.all("--res-file")) {
          if (!f.endsWith(".xml")) continue;
          Path parent = Paths.get(f).toAbsolutePath().getParent();
          if (parent != null) dirs.add(parent);
        }
        List<AndroidResourceInput> keepRules = new ArrayList<>();
        for (Path dir : dirs) {
          try (Stream<Path> walk = Files.walk(dir)) {
            for (Path f : walk.filter(p -> Files.isRegularFile(p) && p.toString().endsWith(".xml")).sorted().toList()) keepRules.add(new KeepRulesXml(f));
          }
        }
        b.setAndroidResourceProvider(new AndroidResourceProvider() {
          @Override
          public Collection<AndroidResourceInput> getAndroidResources() {
            return keepRules;
          }
        });
        b.setAndroidResourceConsumer((output, handler) -> {});
        Path log = Paths.get(a.one("--out-resources-log")).toAbsolutePath();
        b.setResourceShrinkerConfiguration(shrinker -> shrinker
            .enableOptimizedShrinkingWithR8()
            .setDebugConsumer(new StringConsumer.FileConsumer(log))
            .build());
      }

      boolean failed = false;
      try (JavaResources javaRes = new JavaResources(javaResIn); JavaResourcesOut javaResWriter = new JavaResourcesOut(javaResOut)) {
        b.addProgramResourceProvider(javaRes);
        b.setProgramConsumer(new DexIndexedConsumer.ForwardingConsumer(new DexIndexedConsumer.DirectoryConsumer(dexDir)) {
          @Override
          public DataResourceConsumer getDataResourceConsumer() {
            return javaResWriter;
          }
        });
        R8.run(b.build());
      } catch (com.android.tools.r8.CompilationFailedException e) {
        failed = true;
        if (problems.errors.isEmpty()) problems.errors.add(String.valueOf(e.getCause() != null ? e.getCause() : e));
      }
      for (String p : problems.errors) err.println(p);
      if (failed) return 1;

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
    runL8(jars, config, boot, minApi, debuggable, new ClassFileConsumer.ArchiveConsumer(classes.resolve("desugared-desugar-lib.jar")), null, null, null, null, null);
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
    TraceReferences.run(TraceReferencesCommand.builder()
        .setConsumer(TraceReferencesKeepRules.builder().setAllowObfuscation(false).setOutputConsumer(new StringConsumer.FileConsumer(keep)).build())
        .addLibraryFiles(boot)
        .addTargetFiles(desugared)
        .addSourceFiles(dexFiles)
        .build());
    Path expanded = null;
    if (profileIn != null && Files.size(profileIn) > 0) {
      expanded = work.resolve("l8-baseline-prof.txt");
      List<String> paths = new ArrayList<>();
      for (Path p : desugared) paths.add(p.toString());
      expandProfile(profileIn, expanded, paths, err);
    }
    runL8(jars, config, boot, minApi, debuggable, new DexIndexedConsumer.DirectoryConsumer(outDir), keep,
        expanded, expanded != null ? profileOut : null, mapping, mappingOut);
    if (mappingOut != null && !Files.exists(mappingOut)) Files.copy(mapping, mappingOut);
    if (profileOut != null && !Files.exists(profileOut)) Files.write(profileOut, new byte[0]);
  }

  /** The id R8 gave its mapping file (`# pg_map_id: <id>` in the header), or null. */
  private static String mapId(Path mapping) throws IOException {
    try (java.io.BufferedReader reader = Files.newBufferedReader(mapping, StandardCharsets.UTF_8)) {
      for (String line = reader.readLine(); line != null; line = reader.readLine()) {
        String t = line.trim();
        if (t.startsWith("# pg_map_id:")) return t.substring(t.indexOf(':') + 1).trim();
        if (!t.isEmpty() && !t.startsWith("#")) return null;
      }
    }
    return null;
  }

  /**
   * One L8 run as AGP's driver (`L8Tool.runL8`) sets it up: the library's jars with its
   * configuration, the keep rules of what the app uses, the profile to rewrite; with the app's
   * mapping file, the library's dex stamped with the mapping's id and the library's own mapping
   * appended to a copy of the app's.
   */
  private static void runL8(List<Path> jars, String config, List<Path> boot, int minApi, boolean debuggable, com.android.tools.r8.ProgramConsumer out,
      Path keepRules, Path profileIn, Path profileOut, Path mapping, Path mappingOut) throws Exception {
    L8Command.Builder b = L8Command.builder();
    b.addProgramFiles(jars);
    b.addSpecialLibraryConfiguration(config);
    b.addLibraryFiles(boot);
    if (profileIn != null && Files.exists(profileIn) && profileOut != null) rewriteProfile(b, profileIn, profileOut);
    if (mapping != null && Files.exists(mapping)) {
      String id = mapId(mapping);
      if (id != null) b.addProguardConfiguration(List.of("-keepattributes SourceFile", "-renamesourcefileattribute \"r8-map-id-" + id + "\""), Origin.unknown());
    }
    Path ownMapping = mappingOut != null ? Files.createTempFile(mappingOut.toAbsolutePath().getParent(), "l8_map", ".txt") : null;
    try {
      if (ownMapping != null) b.setProguardMapOutputPath(ownMapping);
      b.setMinApiLevel(minApi);
      b.setMode(debuggable ? CompilationMode.DEBUG : CompilationMode.RELEASE);
      b.setProgramConsumer(out);
      if (keepRules != null) b.addProguardConfigurationFiles(List.of(keepRules));
      L8.run(b.build());
      if (mappingOut == null) return;
      if (mapping != null && Files.exists(mapping)) {
        // The bytes, not the file: a copy would be read-only as the input is, and the next step appends.
        Files.write(mappingOut, Files.readAllBytes(mapping));
      } else {
        Files.write(mappingOut, new byte[0]);
      }
      if (Files.exists(ownMapping)) {
        StringBuilder text = new StringBuilder("\n# L8 Desugaring Mapping\n");
        boolean header = true;
        for (String line : Files.readAllLines(ownMapping, StandardCharsets.UTF_8)) {
          if (header && line.startsWith("#")) continue;
          header = false;
          text.append(line).append("\n");
        }
        Files.writeString(mappingOut, text, StandardCharsets.UTF_8, java.nio.file.StandardOpenOption.APPEND);
      }
    } finally {
      if (ownMapping != null) Files.deleteIfExists(ownMapping);
    }
  }
}
