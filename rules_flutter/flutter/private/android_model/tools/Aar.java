// An AAR that the build itself made (a Flutter module packaged by `flutter_android_aar`), taken apart
// for the app that carries it: its manifest for the merge, its classes for dexing, and one zip part
// with what is packaged as it is (`jni/<abi>/*.so` as `lib/<abi>/*.so`, and `assets/`).
//
//   aarparts --aar in.aar --manifest out.xml --classes out.jar --part out.zip
//
// A Maven AAR is unpacked when it is fetched (see extension.bzl) and can carry resources; an AAR of
// the build cannot, because the resource table is linked from files known before the build.
package rules_flutter.android;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

final class Aar {
  static int parts(List<String> args, PrintStream err) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of());
    Path aar = Paths.get(a.one("--aar"));
    Path manifest = Paths.get(a.one("--manifest"));
    Path classes = Paths.get(a.one("--classes"));
    boolean hasManifest = false;
    boolean hasClasses = false;
    try (Apk.ZipIn in = new Apk.ZipIn(aar); Apk.ZipWriter part = new Apk.ZipWriter(Paths.get(a.one("--part")))) {
      for (Apk.Entry e : in.entries) {
        String n = e.name;
        if (n.endsWith("/")) continue;
        if (n.equals("AndroidManifest.xml")) {
          Files.write(manifest, in.content(e));
          hasManifest = true;
        } else if (n.equals("classes.jar")) {
          Files.write(classes, in.content(e));
          hasClasses = true;
        } else if (n.startsWith("jni/") && n.endsWith(".so")) {
          // Stored: the packer puts a stored library at a page boundary.
          byte[] lib = in.content(e);
          Apk.checkElf("lib/" + n.substring(4), lib);
          part.add("lib/" + n.substring(4), lib, Apk.STORE, 4);
        } else if (n.startsWith("assets/")) {
          part.copy(in, e, n, 4);
        } else if (n.startsWith("res/") || n.startsWith("libs/") || (n.equals("R.txt") && e.usize > 0)) {
          err.println(aar + ": " + n + ": an AAR built in this build can carry a manifest, classes, native libraries and assets, "
              + "not resources or bundled jars. Depend on such a library through the app's Gradle file, so that the pin records it.");
          return 1;
        }
      }
    }
    if (!hasManifest) throw new IOException(aar + " has no AndroidManifest.xml");
    if (!hasClasses) {
      // A library without code: an empty jar.
      try (Apk.ZipWriter z = new Apk.ZipWriter(classes)) {
      }
    }
    return 0;
  }
}
