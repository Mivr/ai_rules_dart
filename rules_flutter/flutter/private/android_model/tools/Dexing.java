// D8 and L8, driven as AGP drives them.
//
// AGP dexes in two steps and so do the rules, with the settings of AGP's D8DexArchiveBuilder and
// D8DexArchiveMerger (read from AGP 9.1.0):
//   dex       one jar to one dex archive, in intermediate mode: synthetic classes keep their verbose
//             names and the global synthetics go to a side file instead of into every archive
//   dexmerge  the archives of one scope (Maven libraries, plugin projects, the app) to the final dex
//             files, with the global synthetics, which is where equal helpers are shared
package rules_flutter.android;

import com.android.tools.r8.AssertionsConfiguration;
import com.android.tools.r8.ByteDataView;
import com.android.tools.r8.CompilationMode;
import com.android.tools.r8.D8;
import com.android.tools.r8.D8Command;
import com.android.tools.r8.DexIndexedConsumer;
import com.android.tools.r8.DiagnosticsHandler;
import com.android.tools.r8.GlobalSyntheticsConsumer;
import com.android.tools.r8.L8;
import com.android.tools.r8.L8Command;
import com.android.tools.r8.origin.Origin;
import com.android.tools.r8.references.ClassReference;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class Dexing {
  /** Errors are thrown by D8 itself; its notes and warnings about library code are not the user's to fix. */
  private static final class Quiet implements DiagnosticsHandler {
    @Override
    public void info(com.android.tools.r8.Diagnostic d) {}

    @Override
    public void warning(com.android.tools.r8.Diagnostic d) {}
  }

  // One pool for the life of a worker: Bazel already runs several workers side by side.
  private static final ExecutorService POOL = Executors.newFixedThreadPool(
      Math.max(2, Math.min(4, Runtime.getRuntime().availableProcessors() / 4)),
      r -> {
        Thread t = new Thread(r, "rdf-d8");
        t.setDaemon(true);
        return t;
      });

  /** Collects the dex files D8 produces and writes them as `classes.dex`, `classes2.dex`, ... */
  private static final class DexOut implements DexIndexedConsumer {
    final TreeMap<Integer, byte[]> files = new TreeMap<>();

    @Override
    public synchronized void accept(int fileIndex, ByteDataView data, Set<String> descriptors, DiagnosticsHandler handler) {
      files.put(fileIndex, data.copyByteData());
    }

    @Override
    public void finished(DiagnosticsHandler handler) {}

    void write(String out, boolean store) throws Exception {
      try (Apk.ZipWriter z = new Apk.ZipWriter(Paths.get(out))) {
        int n = 0;
        for (byte[] dex : files.values()) {
          n++;
          z.add(n == 1 ? "classes.dex" : "classes" + n + ".dex", dex, store ? Apk.STORE : Apk.DEFLATE_FAST, 4);
        }
      }
    }
  }

  private static CompilationMode mode(AndroidTool.Args a) {
    return a.has("--release") ? CompilationMode.RELEASE : CompilationMode.DEBUG;
  }

  static void dex(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--release", "--store"));
    boolean debug = !a.has("--release");
    D8Command.Builder b = D8Command.builder(new Quiet());
    for (String in : a.rest) b.addProgramFiles(Paths.get(in));
    DexOut out = new DexOut();
    ByteArrayOutputStream globals = new ByteArrayOutputStream();
    b.setMode(mode(a));
    b.setMinApiLevel(Integer.parseInt(a.one("--min-api")));
    b.setIntermediate(true);
    b.setProgramConsumer(out);
    b.setIncludeClassesChecksum(debug);
    b.setEnableVerboseSyntheticNames(true);
    if (debug) b.addAssertionsConfiguration(AssertionsConfiguration.Builder::compileTimeEnableAllAssertions);
    b.setGlobalSyntheticsConsumer(new GlobalSyntheticsConsumer() {
      @Override
      public synchronized void accept(ByteDataView data, ClassReference context, DiagnosticsHandler handler) {
        if (context != null || globals.size() > 0) throw new IllegalStateException("global synthetics per class are not expected in indexed mode");
        globals.write(data.getBuffer(), data.getOffset(), data.getLength());
      }
    });
    // Desugaring is always on, as in AGP. What D8 is given to desugar against is AGP's choice too:
    // the classpath only below API 24, and the platform library (android.jar) only below API 24 or
    // with core library desugaring. Without the library D8 does not know newer platform types, and
    // writes no helpers for them; the stock build has none either.
    if (a.has("--lib")) b.addLibraryFiles(Paths.get(a.one("--lib")));
    for (String cp : a.all("--classpath")) b.addClasspathFiles(Paths.get(cp));
    if (a.has("--desugared-lib-config")) {
      b.addSpecialLibraryConfiguration(Files.readString(Paths.get(a.one("--desugared-lib-config")), StandardCharsets.UTF_8));
    }
    if (!a.rest.isEmpty()) D8.run(b.build(), POOL);
    out.write(a.one("--output"), a.has("--store"));
    Files.write(Paths.get(a.one("--globals")), globals.toByteArray());
  }

  static void merge(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--release", "--store"));
    boolean debug = !a.has("--release");
    DexOut out = new DexOut();
    int inputs = 0;
    D8Command.Builder b = D8Command.builder(new Quiet());
    b.setDisableDesugaring(true);
    b.setEnableVerboseSyntheticNames(true);
    b.setIncludeClassesChecksum(debug);
    for (String in : a.rest) {
      try (ZipFile z = new ZipFile(in)) {
        List<String> names = new ArrayList<>();
        for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
          String n = e.nextElement().getName();
          if (n.endsWith(".dex")) names.add(n);
        }
        names.sort(null);
        for (String n : names) {
          try (InputStream is = z.getInputStream(z.getEntry(n))) {
            b.addDexProgramData(is.readAllBytes(), Origin.unknown());
            inputs++;
          }
        }
      }
    }
    List<Path> globals = new ArrayList<>();
    for (String g : a.all("--globals")) {
      Path p = Paths.get(g);
      if (Files.size(p) > 0) globals.add(p);
    }
    if (inputs > 0 || !globals.isEmpty()) {
      b.addGlobalSyntheticsFiles(globals);
      if (a.has("--lib")) b.addLibraryFiles(Paths.get(a.one("--lib")));
      // Native multidex: AGP merges for API 21 at least.
      b.setMinApiLevel(Math.max(21, Integer.parseInt(a.one("--min-api"))));
      b.setMode(mode(a));
      b.setProgramConsumer(out);
      b.setIntermediate(false);
      D8.run(b.build(), POOL);
    }
    out.write(a.one("--output"), a.has("--store"));
  }

  /** The desugared core library itself as dex: AGP's l8DexDesugarLib task for a build without shrinking. */
  static void l8(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--release", "--store"));
    DexOut out = new DexOut();
    L8Command.Builder b = L8Command.builder(new Quiet());
    for (String in : a.rest) b.addProgramFiles(Paths.get(in));
    b.addSpecialLibraryConfiguration(Files.readString(Paths.get(a.one("--desugared-lib-config")), StandardCharsets.UTF_8));
    b.addLibraryFiles(Paths.get(a.one("--lib")));
    b.setMinApiLevel(Integer.parseInt(a.one("--min-api")));
    b.setMode(mode(a));
    b.setProgramConsumer(out);
    L8.run(b.build(), POOL);
    out.write(a.one("--output"), a.has("--store"));
  }
}
