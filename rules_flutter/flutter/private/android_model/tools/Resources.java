// Manifests and R classes, with AGP's own code: the manifest merger configured as AGP's
// ProcessApplicationManifest and ProcessLibraryManifest configure it, and the symbol tables and the R
// class writer AGP uses (R classes are written as bytecode; no R.java, no javac).
package rules_flutter.android;

import com.android.aaptcompiler.BlameLogger;
import com.android.aaptcompiler.ResourceCompiler;
import com.android.aaptcompiler.ResourceCompilerOptions;
import com.android.builder.symbols.BytecodeRClassWriterKt;
import com.android.builder.symbols.SymbolExportUtils;
import com.android.ide.common.symbols.IdProvider;
import com.android.ide.common.symbols.ResourceDirectoryParser;
import com.android.ide.common.symbols.SymbolIo;
import com.android.ide.common.symbols.SymbolTable;
import com.android.manifmerger.ManifestMerger2;
import com.android.manifmerger.ManifestSystemProperty;
import com.android.manifmerger.MergingReport;
import com.android.utils.StdLogger;
import java.io.File;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.FieldVisitor;
import org.objectweb.asm.Opcodes;

final class Resources {
  /**
   * `manifest --main f --out f --namespace ns --type APPLICATION|LIBRARY [--overlay f] [--lib f]
   * [--property NAME=value] [--placeholder name=value] [--feature NAME]`
   *
   * The merger's own command line cannot set the namespace or a feature, so this calls its API.
   */
  static int manifest(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    StdLogger logger = new StdLogger(StdLogger.Level.WARNING);
    ManifestMerger2.Invoker inv = ManifestMerger2.newMerger(
        new File(a.one("--main")), logger, ManifestMerger2.MergeType.valueOf(a.one("--type")));
    List<File> overlays = new ArrayList<>();
    for (String o : a.all("--overlay")) overlays.add(new File(o));
    inv.addFlavorAndBuildTypeManifests(overlays.toArray(new File[0]));
    for (String l : a.all("--lib")) inv.addLibraryManifest(new File(l));
    for (String p : a.all("--placeholder")) {
      String[] kv = p.split("=", 2);
      inv.setPlaceHolderValue(kv[0], kv[1]);
    }
    for (String p : a.all("--property")) {
      String[] kv = p.split("=", 2);
      ManifestSystemProperty key = null;
      for (ManifestSystemProperty k : ManifestSystemProperty.getValues()) {
        if (k.getName().equalsIgnoreCase(kv[0]) || k.toString().equalsIgnoreCase(kv[0])) key = k;
      }
      if (key == null) throw new IllegalArgumentException("unknown manifest property " + kv[0]);
      inv.setOverride(key, kv[1]);
    }
    List<ManifestMerger2.Invoker.Feature> features = new ArrayList<>();
    for (String f : a.all("--feature")) features.add(ManifestMerger2.Invoker.Feature.valueOf(f));
    inv.withFeatures(features.toArray(new ManifestMerger2.Invoker.Feature[0]));
    inv.setNamespace(a.one("--namespace"));
    MergingReport report = inv.merge();
    if (!report.getResult().isSuccess()) {
      err.println(report.getReportString());
      return 1;
    }
    Files.write(Paths.get(a.one("--out")),
        report.getMergedDocument(MergingReport.MergedManifestKind.MERGED).getBytes(StandardCharsets.UTF_8));
    return 0;
  }

  /**
   * `rescompile --out out.zip --aapt2 path [--no-crunch] <resource files>`: compiles one library's
   * resource files as AGP does. XML and plain files are compiled in this process by AGP's own resource
   * compiler (which is why the line numbers in compiled XML equal the stock build's); PNGs that are
   * crunched and nine-patches go to the aapt2 binary. The result is a zip of `.flat` files.
   */
  static int rescompile(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--no-crunch"));
    boolean crunch = !a.has("--no-crunch");
    Path out = Paths.get(a.one("--out"));
    Path dir = Files.createTempDirectory(out.toAbsolutePath().getParent(), "flat");
    try {
      ResourceCompilerOptions d = new ResourceCompilerOptions();
      BlameLogger logger = new BlameLogger(new StdLogger(StdLogger.Level.ERROR), (BlameLogger.Source src) -> src);
      List<String> native_ = new ArrayList<>();
      for (String f : a.rest) {
        File file = new File(f);
        if (ResourceCompiler.canCompileResourceInJvm(file, crunch)) {
          // The options AGP's ResourceCompilerRunnable passes: legacy mode, the rest at their defaults.
          // The source path a compiled file records is the path as given (relative to the execution
          // root), never this machine's absolute one: it ends up in an app bundle's resource table.
          ResourceCompilerOptions options = new ResourceCompilerOptions(
              d.getGenerateSymbolsPathData(), d.getVisibility(), d.getRequirePngCrunching(), false, null, true, d.getVerbose(), f);
          ResourceCompiler.compileResource(file, dir.toFile(), options, logger);
        } else {
          native_.add(f);
        }
      }
      if (!native_.isEmpty()) {
        List<String> cmd = new ArrayList<>(List.of(a.one("--aapt2"), "compile", "--legacy"));
        if (!crunch) cmd.add("--no-crunch");
        cmd.add("-o");
        cmd.add(dir.toString());
        cmd.addAll(native_);
        Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        String output = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        if (p.waitFor() != 0) {
          err.print(output);
          return 1;
        }
      }
      List<Path> flats;
      try (java.util.stream.Stream<Path> st = Files.list(dir)) {
        flats = st.sorted().toList();
      }
      try (Apk.ZipWriter z = new Apk.ZipWriter(out)) {
        for (Path f : flats) z.add(f.getFileName().toString(), Files.readAllBytes(f), Apk.STORE, 1);
      }
      return 0;
    } finally {
      try (java.util.stream.Stream<Path> st = Files.walk(dir)) {
        for (Path f : st.sorted(java.util.Comparator.reverseOrder()).toList()) Files.deleteIfExists(f);
      }
    }
  }

  private static final Map<String, SymbolTable> PLATFORM = new HashMap<>();

  /** The platform's `attr` symbols, read from `android.R$attr` in android.jar as AGP does. */
  private static synchronized SymbolTable platformAttrs(String androidJar) throws Exception {
    SymbolTable t = PLATFORM.get(androidJar);
    if (t != null) return t;
    StringBuilder rtxt = new StringBuilder();
    try (ZipFile z = new ZipFile(androidJar)) {
      ZipEntry e = z.getEntry("android/R$attr.class");
      if (e == null) throw new IllegalArgumentException(androidJar + " has no android.R$attr");
      try (InputStream is = z.getInputStream(e)) {
        new ClassReader(is.readAllBytes()).accept(new ClassVisitor(Opcodes.ASM9) {
          @Override
          public FieldVisitor visitField(int access, String name, String desc, String signature, Object value) {
            if (value instanceof Integer) rtxt.append("int attr ").append(name).append(" 0x").append(Integer.toHexString((Integer) value)).append('\n');
            return null;
          }
        }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
      }
    }
    Path tmp = Files.createTempFile("android-attrs", ".txt");
    try {
      Files.writeString(tmp, rtxt);
      t = SymbolIo.readFromAapt(tmp.toFile(), "android");
    } finally {
      Files.delete(tmp);
    }
    PLATFORM.put(androidJar, t);
    return t;
  }

  /**
   * `symbols --package p --android-jar jar --out R-def.txt <resource files>`: the symbols a project's
   * own resources declare (AGP's ParseLibraryResourcesTask). The files are grouped by their resource
   * directory (`<res>/<type>/<file>`).
   */
  static void symbols(List<String> args) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    Set<File> roots = new LinkedHashSet<>();
    for (String f : a.rest) roots.add(new File(f).getAbsoluteFile().getParentFile().getParentFile());
    SymbolTable platform = platformAttrs(a.one("--android-jar"));
    StdLogger logger = new StdLogger(StdLogger.Level.ERROR);
    List<SymbolTable> tables = new ArrayList<>();
    for (File root : roots) {
      tables.add(ResourceDirectoryParser.parseResourceSourceSetDirectory(root, IdProvider.Companion.constant(), platform, a.one("--package"), true, logger));
    }
    SymbolTable all = tables.isEmpty()
        ? SymbolTable.builder().tablePackage(a.one("--package")).build()
        : SymbolTable.merge(tables);
    SymbolIo.writeRDef(all, Paths.get(a.one("--out")));
  }

  private static SymbolTable empty(String pkg) {
    return SymbolTable.builder().tablePackage(pkg).build();
  }

  /** `<package>=<file>` where the file is an AAR's R.txt, a project's R-def.txt, or empty. */
  private static SymbolTable dep(String spec) throws Exception {
    int eq = spec.indexOf('=');
    String pkg = spec.substring(0, eq);
    String file = spec.substring(eq + 1);
    if (file.isEmpty()) return empty(pkg);
    if (file.endsWith("R-def.txt")) return SymbolIo.readRDef(Paths.get(file)).rename(pkg);
    return new File(file).length() == 0 ? empty(pkg) : SymbolIo.readFromAaptNoValues(new File(file), pkg);
  }

  private static void export(List<SymbolTable> tables, String out, boolean finalIds) throws Exception {
    // AGP's writer hands over each class file; the jar is written here, so its bytes are stable.
    Map<String, byte[]> classes = new java.util.TreeMap<>();
    BytecodeRClassWriterKt.exportToCompiledJava(tables, finalIds, null, (String path, byte[] bytes) -> {
      classes.put(path, bytes);
      return kotlin.Unit.INSTANCE;
    });
    try (Apk.ZipWriter z = new Apk.ZipWriter(Paths.get(out))) {
      for (Map.Entry<String, byte[]> c : classes.entrySet()) z.add(c.getKey(), c.getValue(), Apk.DEFLATE_FAST, 1);
    }
  }

  /** Tables of the same package become one, as one R class can be written per package. */
  private static List<SymbolTable> byPackage(List<SymbolTable> tables) {
    Map<String, List<SymbolTable>> groups = new java.util.LinkedHashMap<>();
    for (SymbolTable t : tables) groups.computeIfAbsent(t.getTablePackage(), k -> new ArrayList<>()).add(t);
    List<SymbolTable> out = new ArrayList<>();
    for (List<SymbolTable> g : groups.values()) out.add(g.size() == 1 ? g.get(0) : SymbolTable.merge(g));
    return out;
  }

  /**
   * `rjar --mode library --package p --local R-def.txt --android-jar jar --out r.jar`
   *     the R class a library project compiles against: its own symbols, ids not final
   *     (AGP's GenerateLibraryRFileTask with non-transitive R classes).
   * `rjar --mode external --dep <package>=<R.txt> ... --out r.jar`
   *     the same for the AARs of the model, in one jar.
   * `rjar --mode app --package p --rtxt R.txt --local R-def.txt --dep <package>=<file> ... --out r.jar`
   *     the R classes packaged in the app: one per library from that library's own symbol list, and the
   *     app's own, with the ids aapt2 assigned (AGP's LinkApplicationAndroidResourcesTask). The fields
   *     are final only with `--final-ids` (android.nonFinalResIds=false): AGP's default leaves them
   *     not final, so that code reads the field and a release build's shrinker sees the use.
   */
  static void rjar(List<String> args) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--final-ids"));
    String mode = a.one("--mode");
    List<SymbolTable> deps = new ArrayList<>();
    for (String d : a.all("--dep")) deps.add(dep(d));
    if (mode.equals("external")) {
      export(byPackage(deps), a.one("--out"), false);
    } else if (mode.equals("library")) {
      String pkg = a.one("--package");
      SymbolTable local = SymbolIo.readRDef(Paths.get(a.one("--local"))).rename(pkg);
      Path symbolsOut = Files.createTempFile("r", ".txt");
      try {
        List<SymbolTable> tables = SymbolExportUtils.processLibraryMainSymbolTable(
            pkg, local, List.of(), platformAttrs(a.one("--android-jar")), true, symbolsOut, false, IdProvider.Companion.constant());
        export(new ArrayList<>(tables), a.one("--out"), false);
      } finally {
        Files.deleteIfExists(symbolsOut);
      }
    } else if (mode.equals("app")) {
      String pkg = a.one("--package");
      File rtxt = new File(a.one("--rtxt"));
      SymbolTable main = rtxt.length() > 0 ? SymbolIo.readFromAapt(rtxt, pkg) : empty(pkg);
      deps.add(SymbolIo.readRDef(Paths.get(a.one("--local"))).rename(pkg));
      List<SymbolTable> tables = new ArrayList<>();
      for (SymbolTable t : byPackage(deps)) tables.add(t.withValuesFrom(main));
      export(tables, a.one("--out"), a.has("--final-ids"));
    } else {
      throw new IllegalArgumentException("unknown mode " + mode);
    }
  }
}
