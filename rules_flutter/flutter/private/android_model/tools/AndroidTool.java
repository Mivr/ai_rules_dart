// The build-side tool of the Android model: every action that runs one of AGP's own libraries (D8 and
// L8 from R8, the manifest merger, the R class writer, the APK signer) goes through this program, as a
// one-shot process or as a Bazel persistent worker (JSON protocol), so that an edit pays no JVM start.
//
//   AndroidTool --persistent_worker        worker mode: one JSON request per line on stdin
//   AndroidTool <command> <arguments>      one shot; `@file` arguments are read as one argument per line
//
// The libraries come from the pin file (`tool_classpaths`), at the versions the stock build uses.
package rules_flutter.android;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class AndroidTool {
  /** Arguments of one command: `--name value` pairs (repeatable) and positional arguments. */
  static final class Args {
    final Map<String, List<String>> named = new LinkedHashMap<>();
    final List<String> rest = new ArrayList<>();

    Args(List<String> args, List<String> booleans) {
      for (int i = 0; i < args.size(); i++) {
        String a = args.get(i);
        if (booleans.contains(a)) {
          named.computeIfAbsent(a, k -> new ArrayList<>()).add("true");
        } else if (a.startsWith("--")) {
          if (i + 1 >= args.size()) throw new IllegalArgumentException("missing value of " + a);
          named.computeIfAbsent(a, k -> new ArrayList<>()).add(args.get(++i));
        } else {
          rest.add(a);
        }
      }
    }

    boolean has(String name) {
      return named.containsKey(name);
    }

    String one(String name) {
      List<String> v = named.get(name);
      if (v == null) throw new IllegalArgumentException("missing " + name);
      return v.get(v.size() - 1);
    }

    String opt(String name) {
      List<String> v = named.get(name);
      return v == null ? null : v.get(v.size() - 1);
    }

    List<String> all(String name) {
      return named.getOrDefault(name, List.of());
    }
  }

  public static void main(String[] args) throws Exception {
    boolean worker = false;
    for (String a : args) {
      if (a.equals("--persistent_worker")) worker = true;
    }
    if (!worker) {
      System.exit(run(expand(List.of(args)), System.err));
    }
    PrintStream realOut = System.out;
    BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    Gson gson = new Gson();
    String line;
    while ((line = in.readLine()) != null) {
      if (line.isBlank()) continue;
      JsonObject req = gson.fromJson(line, JsonObject.class);
      List<String> a = new ArrayList<>();
      JsonArray arr = req.getAsJsonArray("arguments");
      if (arr != null) for (JsonElement e : arr) a.add(e.getAsString());
      ByteArrayOutputStream buf = new ByteArrayOutputStream();
      PrintStream ps = new PrintStream(buf, true, StandardCharsets.UTF_8);
      int code;
      System.setOut(ps);
      System.setErr(ps);
      try {
        code = run(expand(a), ps);
      } catch (Throwable t) {
        t.printStackTrace(ps);
        code = 1;
      }
      JsonObject resp = new JsonObject();
      resp.addProperty("exitCode", code);
      resp.addProperty("output", buf.toString(StandardCharsets.UTF_8));
      if (req.has("requestId")) resp.add("requestId", req.get("requestId"));
      realOut.println(gson.toJson(resp));
      realOut.flush();
    }
  }

  private static List<String> expand(List<String> args) throws Exception {
    List<String> out = new ArrayList<>();
    for (String a : args) {
      if (a.startsWith("@")) {
        out.addAll(Files.readAllLines(Paths.get(a.substring(1)), StandardCharsets.UTF_8));
      } else {
        out.add(a);
      }
    }
    return out;
  }

  static int run(List<String> args, PrintStream err) {
    String tool = args.isEmpty() ? "" : args.get(0);
    List<String> rest = args.subList(Math.min(1, args.size()), args.size());
    try {
      switch (tool) {
        case "dex": Dexing.dex(rest, err); return 0;
        case "dexmerge": Dexing.merge(rest, err); return 0;
        case "l8": Dexing.l8(rest, err); return 0;
        case "r8": return Release.r8(rest, err);
        case "artprofile": return Release.artProfile(rest, err);
        case "bundle": return Bundle.run(rest, err);
        case "manifest": return Resources.manifest(rest, err);
        case "rescompile": return Resources.rescompile(rest, err);
        case "symbols": Resources.symbols(rest); return 0;
        case "rjar": Resources.rjar(rest); return 0;
        case "pack": Apk.pack(rest); return 0;
        case "zip": Apk.zip(rest); return 0;
        case "pincheck": return PinCheck.run(rest, err);
        case "gradle-aar": return GradleAar.run(rest, err);
        default:
          err.println("unknown command " + tool);
          return 2;
      }
    } catch (Throwable t) {
      err.println(tool + " failed: " + t);
      for (Throwable c = t.getCause(); c != null; c = c.getCause()) err.println("  cause: " + c);
      if (System.getenv("RDF_ANDROID_TOOL_TRACE") != null) t.printStackTrace(err);
      return 1;
    }
  }
}
