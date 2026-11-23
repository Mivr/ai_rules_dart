// An app bundle (.aab): the base module put together as AGP's module task does it, then bundletool
// (the version AGP builds bundles with, from the pin), configured as AGP's bundle task configures it.
//
//   base.zip   manifest/AndroidManifest.xml and resources.pb, res/  the linked resources, proto format
//              dex/classes.dex, ...                                the final dex files
//              lib/<abi>/*.so                                      native libraries
//              assets/...                                          assets and the Flutter payload
//              root/...                                            Java resources
//   BUNDLE-METADATA/<directory>/<name>                             the mapping file, the baseline profile, ...
package rules_flutter.android;

import com.android.bundle.Config;
import com.android.tools.build.bundletool.commands.BuildBundleCommand;
import com.google.common.collect.ImmutableList;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class Bundle {
  static int run(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--uncompressed-native-libs", "--unsigned", "--no-store-archive"));
    Path out = Paths.get(a.one("--out")).toAbsolutePath();
    Path work = Files.createTempDirectory(out.getParent(), "bundle");
    List<Apk.ZipIn> open = new ArrayList<>();
    try {
      Path module = work.resolve("base.zip");
      try (Apk.ZipWriter z = new Apk.ZipWriter(module)) {
        Apk.ZipIn res = new Apk.ZipIn(Paths.get(a.one("--resources")));
        open.add(res);
        for (Apk.Entry e : res.entries) {
          if (e.name.endsWith("/")) continue;
          z.copy(res, e, e.name.equals("AndroidManifest.xml") ? "manifest/AndroidManifest.xml" : e.name, 1);
        }
        int dex = 0;
        for (String d : a.all("--dex")) {
          Apk.ZipIn in = new Apk.ZipIn(Paths.get(d));
          open.add(in);
          List<Apk.Entry> es = new ArrayList<>(in.entries);
          es.removeIf(e -> !e.name.endsWith(".dex"));
          es.sort((x, y) -> {
            int c = Integer.compare(x.name.length(), y.name.length());
            return c != 0 ? c : x.name.compareTo(y.name);
          });
          for (Apk.Entry e : es) {
            dex++;
            z.copy(in, e, dex == 1 ? "dex/classes.dex" : "dex/classes" + dex + ".dex", 1);
          }
        }
        Apk.Patterns jniExcludes = new Apk.Patterns(a.all("--jni-exclude"));
        Apk.Patterns jniPickFirsts = new Apk.Patterns(a.all("--jni-pick-first"));
        Map<String, Path> natives = new LinkedHashMap<>();
        for (String spec : a.all("--native")) {
          int eq = spec.indexOf('=');
          Path file = Paths.get(spec.substring(eq + 1));
          String name = "lib/" + spec.substring(0, eq) + "/" + file.getFileName();
          if (jniExcludes.matches(name)) continue;
          Path first = natives.get(name);
          if (first == null) {
            natives.put(name, file);
          } else if (!jniPickFirsts.matches(name) && Files.mismatch(first, file) != -1) {
            throw new IOException(name + " comes from " + first + " and from " + file + " with different content; "
                + "choose one with `packaging { jniLibs { pickFirsts += \"" + name + "\" } }` in the app's Gradle file and pin again");
          }
        }
        for (Map.Entry<String, Path> n : natives.entrySet()) z.store(n.getKey(), n.getValue(), 1);
        for (String part : a.all("--zip")) {
          Apk.ZipIn in = new Apk.ZipIn(Paths.get(part));
          open.add(in);
          for (Apk.Entry e : in.entries) {
            if (!e.name.endsWith("/") && !z.has(e.name)) z.copy(in, e, e.name, 1);
          }
        }
        for (String spec : a.all("--root-entry")) {
          int eq = spec.indexOf('=');
          z.add("root/" + spec.substring(0, eq), Files.readAllBytes(Paths.get(spec.substring(eq + 1))), Apk.DEFLATE_DEFAULT, 1);
        }
        Apk.writeJavaResources(z, open, a.all("--java-res"), new Apk.Patterns(a.all("--exclude")), new Apk.Patterns(a.all("--pick-first")),
            new Apk.Patterns(a.all("--merge")), Apk.DEFLATE_DEFAULT, "root/");
      }

      // AGP's PackageBundleTask: a split dimension is named only to switch it off; native libraries
      // stay uncompressed (at 16 KB boundaries) in the APKs unless the app packages them the legacy way.
      Config.SplitsConfig.Builder splits = Config.SplitsConfig.newBuilder();
      for (String dimension : a.all("--no-split")) {
        splits.addSplitDimension(Config.SplitDimension.newBuilder().setValue(Config.SplitDimension.Value.valueOf(dimension)).setNegate(true));
      }
      Config.Optimizations.Builder optimizations = Config.Optimizations.newBuilder()
          .setSplitsConfig(splits)
          .setUncompressNativeLibraries(Config.UncompressNativeLibraries.newBuilder()
              .setEnabled(a.has("--uncompressed-native-libs"))
              .setAlignment(Config.UncompressNativeLibraries.PageAlignment.PAGE_ALIGNMENT_16K))
          .setStoreArchive(Config.StoreArchive.newBuilder().setEnabled(!a.has("--no-store-archive")));
      Config.BundleConfig config = Config.BundleConfig.newBuilder()
          .setType(Config.BundleConfig.BundleType.REGULAR)
          .setCompression(Config.Compression.newBuilder().addAllUncompressedGlob(a.all("--uncompressed-glob")))
          .setOptimizations(optimizations)
          .build();
      Path unsigned = work.resolve("unsigned.aab");
      BuildBundleCommand.Builder command = BuildBundleCommand.builder()
          .setUncompressedBundle(false)
          .setBundleConfig(config)
          .setOutputPath(unsigned)
          .setModulesPaths(ImmutableList.of(module));
      for (String spec : a.all("--metadata")) {
        int eq = spec.indexOf('=');
        String name = spec.substring(0, eq);
        int slash = name.lastIndexOf('/');
        Path file = Paths.get(spec.substring(eq + 1)).toAbsolutePath();
        if (Files.size(file) > 0) command.addMetadataFile(name.substring(0, slash), name.substring(slash + 1), file);
      }
      command.build().execute();

      if (a.has("--unsigned")) {
        // Signed outside the build (see Sign.java).
        Files.move(unsigned, out, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
      } else {
        // The debug key; a bundle is signed as a jar.
        new com.android.apksig.ApkSigner.Builder(List.of(Apk.signer(a.one("--keystore"), "android", "androiddebugkey", "android")))
            .setInputApk(unsigned.toFile())
            .setOutputApk(out.toFile())
            .setMinSdkVersion(Integer.parseInt(a.one("--min-sdk")))
            .setV1SigningEnabled(true)
            .setV2SigningEnabled(false)
            .setV3SigningEnabled(false)
            .setV4SigningEnabled(false)
            .build()
            .sign();
      }
      return 0;
    } finally {
      for (Apk.ZipIn in : open) in.close();
      Release.deleteTree(work);
    }
  }
}
