// Zip parts and the APK: written here, aligned, and signed with AGP's signer (apksig).
//
// Nothing is compressed twice. Dex archives, the linked resources, asset parts and the jars that carry
// Java resources are zip files whose entries are already compressed; the packer copies those bytes as
// they are and only writes headers, so packaging the whole app after a small edit is a copy and a
// signature, not a compression of everything.
package rules_flutter.android;

import com.android.apksig.ApkSigner;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.PathMatcher;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;
import java.util.zip.CRC32;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

final class Apk {
  static final int STORE = 0;
  static final int DEFLATE_FAST = 1; // what a debug build of AGP packages with
  static final int DEFLATE_DEFAULT = 6; // what a release build packages with

  // The timestamp AGP's packager writes on every entry: 1981-01-01 01:01:02.
  private static final int DOS_TIME = (1 << 11) | (1 << 5) | 1;
  private static final int DOS_DATE = (1 << 9) | (1 << 5) | 1;

  // Extensions the Android packager never compresses (aapt's list), used for assets.
  private static final Set<String> NO_COMPRESS = Set.of(
      "jpg", "jpeg", "png", "gif", "opus", "wav", "mp2", "mp3", "ogg", "aac", "mpg", "mpeg", "mid", "midi", "smf", "jet",
      "rtttl", "imy", "xmf", "mp4", "m4a", "m4v", "3gp", "3gpp", "3g2", "3gpp2", "amr", "awb", "wma", "wmv", "webm", "mkv", "tflite");

  /** One entry of a zip file being read. */
  static final class Entry {
    String name;
    int method;
    long crc;
    long csize;
    long usize;
    long headerOffset;
  }

  /** Reads a zip file's central directory and gives the stored bytes of its entries. */
  static final class ZipIn implements Closeable {
    final Path path;
    final FileChannel ch;
    final List<Entry> entries = new ArrayList<>();

    ZipIn(Path path) throws IOException {
      this.path = path;
      ch = FileChannel.open(path, StandardOpenOption.READ);
      long size = ch.size();
      int tail = (int) Math.min(size, 65557);
      ByteBuffer t = read(size - tail, tail);
      int eocd = -1;
      for (int i = tail - 22; i >= 0; i--) {
        if (t.getInt(i) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw new IOException(path + " is not a zip file");
      int count = t.getShort(eocd + 10) & 0xffff;
      long cdSize = t.getInt(eocd + 12) & 0xffffffffL;
      long cdOffset = t.getInt(eocd + 16) & 0xffffffffL;
      if (count == 0xffff || cdOffset == 0xffffffffL) throw new IOException(path + ": zip64 archives are not supported");
      ByteBuffer cd = read(cdOffset, (int) cdSize);
      int p = 0;
      for (int i = 0; i < count; i++) {
        if (cd.getInt(p) != 0x02014b50) throw new IOException(path + ": bad central directory");
        Entry e = new Entry();
        e.method = cd.getShort(p + 10) & 0xffff;
        e.crc = cd.getInt(p + 16) & 0xffffffffL;
        e.csize = cd.getInt(p + 20) & 0xffffffffL;
        e.usize = cd.getInt(p + 24) & 0xffffffffL;
        int n = cd.getShort(p + 28) & 0xffff;
        int m = cd.getShort(p + 30) & 0xffff;
        int k = cd.getShort(p + 32) & 0xffff;
        e.headerOffset = cd.getInt(p + 42) & 0xffffffffL;
        byte[] name = new byte[n];
        cd.position(p + 46);
        cd.get(name);
        e.name = new String(name, StandardCharsets.UTF_8);
        entries.add(e);
        p += 46 + n + m + k;
      }
    }

    private ByteBuffer read(long offset, int length) throws IOException {
      ByteBuffer b = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN);
      while (b.hasRemaining()) {
        int r = ch.read(b, offset + b.position());
        if (r < 0) throw new IOException(path + ": truncated");
      }
      b.flip();
      return b;
    }

    long dataOffset(Entry e) throws IOException {
      ByteBuffer h = read(e.headerOffset, 30);
      return e.headerOffset + 30 + (h.getShort(26) & 0xffff) + (h.getShort(28) & 0xffff);
    }

    /** The entry's content, uncompressed. */
    byte[] content(Entry e) throws IOException {
      byte[] raw = read(dataOffset(e), (int) e.csize).array();
      return e.method == 0 ? raw : inflate(raw, (int) e.usize);
    }

    @Override
    public void close() throws IOException {
      ch.close();
    }
  }

  /** Writes a zip file: fixed timestamps, entries in the order given, stored entries aligned. */
  static final class ZipWriter implements Closeable {
    private final FileChannel ch;
    private final ByteArrayOutputStream central = new ByteArrayOutputStream();
    private final Map<String, Boolean> names = new HashMap<>();
    private long pos = 0;
    private int count = 0;

    ZipWriter(Path out) throws IOException {
      ch = FileChannel.open(out, StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    boolean has(String name) {
      return names.containsKey(name);
    }

    private void write(ByteBuffer b) throws IOException {
      pos += b.remaining();
      while (b.hasRemaining()) ch.write(b);
    }

    private void header(String name, int method, long crc, long csize, long usize, int align) throws IOException {
      if (names.put(name, true) != null) throw new IOException("duplicate entry " + name);
      byte[] n = name.getBytes(StandardCharsets.UTF_8);
      int flags = n.length == name.length() ? 0 : 0x0800;
      // Stored data starts at a multiple of `align`; the padding is an extra field, as zipalign and
      // AGP's packager write it (header 0xd935: the alignment, then zeros).
      int extra = 0;
      if (method == 0 && align > 1) {
        long data = pos + 30 + n.length;
        int pad = (int) ((align - (data % align)) % align);
        if (pad > 0) {
          while (pad < 6) pad += align;
          extra = pad;
        }
      }
      ByteBuffer h = ByteBuffer.allocate(30 + n.length + extra).order(ByteOrder.LITTLE_ENDIAN);
      h.putInt(0x04034b50).putShort((short) 20).putShort((short) flags).putShort((short) method);
      h.putShort((short) DOS_TIME).putShort((short) DOS_DATE);
      h.putInt((int) crc).putInt((int) csize).putInt((int) usize);
      h.putShort((short) n.length).putShort((short) extra).put(n);
      if (extra > 0) {
        h.putShort((short) 0xd935).putShort((short) (extra - 4)).putShort((short) align);
        h.position(h.capacity());
      }
      ByteBuffer c = ByteBuffer.allocate(46 + n.length).order(ByteOrder.LITTLE_ENDIAN);
      c.putInt(0x02014b50).putShort((short) 20).putShort((short) 20).putShort((short) flags).putShort((short) method);
      c.putShort((short) DOS_TIME).putShort((short) DOS_DATE);
      c.putInt((int) crc).putInt((int) csize).putInt((int) usize);
      c.putShort((short) n.length).putShort((short) 0).putShort((short) 0).putShort((short) 0).putShort((short) 0);
      c.putInt(0).putInt((int) pos).put(n);
      central.write(c.array());
      count++;
      h.flip();
      write(h);
    }

    /** Adds content; `how` is STORE or a deflate level. Content that deflate does not shrink is stored. */
    void add(String name, byte[] data, int how, int align) throws IOException {
      CRC32 crc = new CRC32();
      crc.update(data);
      byte[] packed = how == STORE ? null : deflate(data, how);
      if (packed != null && packed.length < data.length) {
        header(name, 8, crc.getValue(), packed.length, data.length, 1);
        write(ByteBuffer.wrap(packed));
      } else {
        header(name, 0, crc.getValue(), data.length, data.length, align);
        write(ByteBuffer.wrap(data));
      }
    }

    /** Copies an entry of another zip file without touching its bytes. */
    void copy(ZipIn in, Entry e, String name, int align) throws IOException {
      header(name, e.method, e.crc, e.csize, e.usize, align);
      long from = in.dataOffset(e);
      long left = e.csize;
      while (left > 0) {
        long n = in.ch.transferTo(from, left, ch);
        if (n <= 0) throw new IOException("short copy from " + in.path);
        from += n;
        left -= n;
      }
      pos += e.csize;
      ch.position(pos);
    }

    /** Adds a file from disk, stored and aligned, without reading it into memory. */
    void store(String name, Path file, int align) throws IOException {
      try (FileChannel src = FileChannel.open(file, StandardOpenOption.READ)) {
        long size = src.size();
        CRC32 crc = new CRC32();
        ByteBuffer buf = ByteBuffer.allocate(1 << 20);
        long at = 0;
        while (at < size) {
          buf.clear();
          int r = src.read(buf, at);
          if (r < 0) break;
          crc.update(buf.array(), 0, r);
          at += r;
        }
        header(name, 0, crc.getValue(), size, size, align);
        long from = 0;
        while (from < size) {
          long n = src.transferTo(from, size - from, ch);
          if (n <= 0) throw new IOException("short copy from " + file);
          from += n;
        }
        pos += size;
        ch.position(pos);
      }
    }

    @Override
    public void close() throws IOException {
      byte[] cd = central.toByteArray();
      long cdOffset = pos;
      write(ByteBuffer.wrap(cd));
      ByteBuffer e = ByteBuffer.allocate(22).order(ByteOrder.LITTLE_ENDIAN);
      e.putInt(0x06054b50).putShort((short) 0).putShort((short) 0).putShort((short) count).putShort((short) count);
      e.putInt(cd.length).putInt((int) cdOffset).putShort((short) 0);
      e.flip();
      write(e);
      ch.close();
    }
  }

  static byte[] deflate(byte[] data, int level) {
    Deflater d = new Deflater(level, true);
    try {
      d.setInput(data);
      d.finish();
      ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(64, data.length / 2));
      byte[] buf = new byte[1 << 16];
      while (!d.finished()) out.write(buf, 0, d.deflate(buf));
      return out.toByteArray();
    } finally {
      d.end();
    }
  }

  static byte[] inflate(byte[] raw, int size) throws IOException {
    Inflater i = new Inflater(true);
    try {
      i.setInput(raw);
      byte[] out = new byte[size];
      int n = 0;
      while (n < size) {
        int r = i.inflate(out, n, size - n);
        if (r == 0 && (i.finished() || i.needsInput())) break;
        n += r;
      }
      if (n != size) throw new IOException("bad deflate stream");
      return out;
    } catch (java.util.zip.DataFormatException e) {
      throw new IOException(e);
    } finally {
      i.end();
    }
  }

  private static String extension(String name) {
    int dot = name.lastIndexOf('.');
    int slash = name.lastIndexOf('/');
    return dot > slash ? name.substring(dot + 1).toLowerCase(java.util.Locale.ROOT) : "";
  }

  /** `zip --out part.zip [--store] name=path ...`: files, or whole directories under a prefix, as one zip part. */
  static void zip(List<String> args) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--store", "--release"));
    boolean store = a.has("--store");
    int level = a.has("--release") ? DEFLATE_DEFAULT : DEFLATE_FAST;
    try (ZipWriter z = new ZipWriter(Paths.get(a.one("--out")))) {
      for (String spec : a.rest) {
        int eq = spec.indexOf('=');
        String name = spec.substring(0, eq);
        Path path = Paths.get(spec.substring(eq + 1));
        List<Path> files;
        if (Files.isDirectory(path)) {
          try (Stream<Path> s = Files.walk(path, java.nio.file.FileVisitOption.FOLLOW_LINKS)) {
            files = s.filter(Files::isRegularFile).sorted().toList();
          }
        } else {
          files = List.of(path);
        }
        for (Path f : files) {
          String entry = f.equals(path) ? name : name + "/" + path.relativize(f).toString().replace(File.separatorChar, '/');
          if (z.has(entry)) continue;
          if (store || NO_COMPRESS.contains(extension(entry))) {
            z.store(entry, f, 4);
          } else {
            z.add(entry, Files.readAllBytes(f), level, 4);
          }
        }
      }
    }
  }

  /** AGP's packaging rules: glob patterns matched against the entry path with a leading slash. */
  static final class Patterns {
    final List<PathMatcher> matchers = new ArrayList<>();

    Patterns(List<String> globs) {
      for (String g : globs) matchers.add(FileSystems.getDefault().getPathMatcher("glob:" + g));
    }

    boolean matches(String name) {
      if (matchers.isEmpty()) return false;
      Path p = Paths.get("/" + name);
      for (PathMatcher m : matchers) {
        if (m.matches(p)) return true;
      }
      return false;
    }
  }

  private static final class JavaResource {
    ZipIn zip;
    Entry entry;
    List<byte[]> merged; // set when the path is merged from several jars
  }

  /**
   * Java resources: everything in the runtime jars that is not a class, under the app's
   * `packaging { resources { excludes, pickFirsts, merges } }`, in classpath order.
   */
  static void writeJavaResources(ZipWriter z, List<ZipIn> open, List<String> jars, Patterns excludes, Patterns pickFirsts, Patterns merges, int level, String prefix) throws IOException {
    Map<String, JavaResource> resources = new LinkedHashMap<>();
    for (String jar : jars) {
      ZipIn in = new ZipIn(Paths.get(jar));
      open.add(in);
      for (Entry e : in.entries) {
        String n = e.name;
        if (n.endsWith("/") || n.endsWith(".class") || (n.startsWith("lib/") && n.endsWith(".so"))) continue;
        if (excludes.matches(n)) continue;
        JavaResource r = resources.get(n);
        if (r == null) {
          r = new JavaResource();
          r.zip = in;
          r.entry = e;
          resources.put(n, r);
        } else if (pickFirsts.matches(n)) {
          continue;
        } else if (merges.matches(n)) {
          if (r.merged == null) {
            r.merged = new ArrayList<>();
            r.merged.add(r.zip.content(r.entry));
          }
          r.merged.add(in.content(e));
        } else if (r.entry.crc != e.crc || r.entry.usize != e.usize || !Arrays.equals(r.zip.content(r.entry), in.content(e))) {
          throw new IOException(n + " is in " + r.zip.path + " and in " + in.path + " with different content; "
              + "choose with `packaging { resources { pickFirsts += \"" + n + "\" } }` (or `merges`, `excludes`) in the app's Gradle file and pin again");
        }
      }
    }
    for (Map.Entry<String, JavaResource> r : resources.entrySet()) {
      JavaResource v = r.getValue();
      String name = prefix + r.getKey();
      if (z.has(name)) continue;
      if (v.merged != null) {
        ByteArrayOutputStream all = new ByteArrayOutputStream();
        for (byte[] part : v.merged) {
          if (all.size() > 0 && all.toByteArray()[all.size() - 1] != '\n') all.write('\n');
          all.write(part);
        }
        z.add(name, all.toByteArray(), level, 4);
      } else if (v.entry.method == 0 && v.entry.usize > 0) {
        z.add(name, v.zip.content(v.entry), level, 4);
      } else {
        z.copy(v.zip, v.entry, name, 4);
      }
    }
  }

  /** The Java resources of the runtime jars as one jar, merged as AGP's mergeJavaResource merges them. */
  static void mergeJavaResources(Path out, List<String> jars, List<String> excludes, List<String> pickFirsts, List<String> merges, int level) throws IOException {
    List<ZipIn> open = new ArrayList<>();
    try (ZipWriter z = new ZipWriter(out)) {
      writeJavaResources(z, open, jars, new Patterns(excludes), new Patterns(pickFirsts), new Patterns(merges), level, "");
    } finally {
      for (ZipIn in : open) in.close();
    }
  }

  private static final Map<String, ApkSigner.SignerConfig> SIGNERS = new HashMap<>();

  static synchronized ApkSigner.SignerConfig signer(String keystore, String storePass, String alias, String keyPass) throws Exception {
    String key = keystore + "\n" + alias;
    ApkSigner.SignerConfig c = SIGNERS.get(key);
    if (c == null) {
      KeyStore ks = KeyStore.getInstance(new File(keystore), storePass.toCharArray());
      PrivateKey pk = (PrivateKey) ks.getKey(alias, keyPass.toCharArray());
      if (pk == null) throw new IOException("no key " + alias + " in " + keystore);
      List<X509Certificate> certs = new ArrayList<>();
      for (Certificate cert : ks.getCertificateChain(alias)) certs.add((X509Certificate) cert);
      c = new ApkSigner.SignerConfig.Builder(alias.toUpperCase(java.util.Locale.ROOT), pk, certs).build();
      SIGNERS.put(key, c);
    }
    return c;
  }

  /**
   * `pack`: one APK (the whole app, the base or a split) from its parts, in the order AGP writes them:
   * literal entries, dex, native libraries, zip parts (assets), the linked resources, Java resources.
   */
  static void pack(List<String> args) throws Exception {
    AndroidTool.Args a = new AndroidTool.Args(args, List.of("--dex-store", "--native-compress", "--v1", "--no-v2", "--v3", "--release", "--unsigned"));
    // A debug build packages fast; a release build with the default level, as AGP does.
    int level = a.has("--release") ? DEFLATE_DEFAULT : DEFLATE_FAST;
    Path out = Paths.get(a.one("--out"));
    Path unsigned = Paths.get(a.one("--out") + ".unsigned");
    Patterns excludes = new Patterns(a.all("--exclude"));
    Patterns pickFirsts = new Patterns(a.all("--pick-first"));
    Patterns merges = new Patterns(a.all("--merge"));
    Patterns jniExcludes = new Patterns(a.all("--jni-exclude"));
    Patterns jniPickFirsts = new Patterns(a.all("--jni-pick-first"));
    List<ZipIn> open = new ArrayList<>();
    try {
      try (ZipWriter z = new ZipWriter(unsigned)) {
        for (String spec : a.all("--entry")) {
          int eq = spec.indexOf('=');
          z.add(spec.substring(0, eq), Files.readAllBytes(Paths.get(spec.substring(eq + 1))), level, 4);
        }
        for (String spec : a.all("--stored-entry")) {
          int eq = spec.indexOf('=');
          z.add(spec.substring(0, eq), Files.readAllBytes(Paths.get(spec.substring(eq + 1))), STORE, 4);
        }
        int dex = 0;
        boolean dexStore = a.has("--dex-store");
        for (String d : a.all("--dex")) {
          ZipIn in = new ZipIn(Paths.get(d));
          open.add(in);
          List<Entry> es = new ArrayList<>(in.entries);
          es.removeIf(e -> !e.name.endsWith(".dex"));
          es.sort((x, y) -> {
            // classes.dex, classes2.dex, ... classes10.dex
            int c = Integer.compare(x.name.length(), y.name.length());
            return c != 0 ? c : x.name.compareTo(y.name);
          });
          for (Entry e : es) {
            dex++;
            String name = dex == 1 ? "classes.dex" : "classes" + dex + ".dex";
            if ((e.method == 0) == dexStore) {
              z.copy(in, e, name, 4);
            } else {
              z.add(name, in.content(e), dexStore ? STORE : level, 4);
            }
          }
        }
        boolean nativeCompress = a.has("--native-compress");
        int pageAlign = Integer.parseInt(a.opt("--page-align") == null ? "16384" : a.opt("--page-align"));
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
        for (Map.Entry<String, Path> n : natives.entrySet()) {
          if (nativeCompress) {
            z.add(n.getKey(), Files.readAllBytes(n.getValue()), level, 4);
          } else {
            z.store(n.getKey(), n.getValue(), pageAlign);
          }
        }
        List<String> abis = a.all("--abi");
        for (String part : a.all("--zip")) {
          ZipIn in = new ZipIn(Paths.get(part));
          open.add(in);
          for (Entry e : in.entries) {
            if (e.name.endsWith("/") || z.has(e.name)) continue;
            // A part can carry native libraries (an AAR of the build): only this APK's ABIs, and a
            // stored library at a page boundary like any other.
            boolean lib = e.name.startsWith("lib/") && e.name.endsWith(".so");
            if (lib && (jniExcludes.matches(e.name) || (!abis.isEmpty() && !abis.contains(e.name.split("/")[1])))) continue;
            z.copy(in, e, e.name, lib && e.method == 0 ? pageAlign : 4);
          }
        }
        for (String ap : a.all("--resources")) {
          ZipIn in = new ZipIn(Paths.get(ap));
          open.add(in);
          for (Entry e : in.entries) {
            if (!e.name.endsWith("/") && !z.has(e.name)) z.copy(in, e, e.name, 4);
          }
        }
        writeJavaResources(z, open, a.all("--java-res"), excludes, pickFirsts, merges, level, "");
      }
    } finally {
      for (ZipIn in : open) in.close();
    }
    if (a.has("--unsigned")) {
      // Signed outside the build (see Sign.java): the aligned, unsigned APK is the build's output.
      Files.move(unsigned, out, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
      return;
    }
    ApkSigner.SignerConfig config = signer(a.one("--keystore"), a.one("--ks-pass"), a.one("--key-alias"), a.one("--key-pass"));
    sign(config, unsigned, out, Integer.parseInt(a.one("--min-sdk")), a.has("--v1"), !a.has("--no-v2"), a.has("--v3"));
    Files.delete(unsigned);
  }

  /** Signs an aligned APK with AGP's signer, keeping the alignment. */
  static void sign(ApkSigner.SignerConfig config, Path unsigned, Path out, int minSdk, boolean v1, boolean v2, boolean v3) throws Exception {
    new ApkSigner.Builder(List.of(config))
        .setInputApk(unsigned.toFile())
        .setOutputApk(out.toFile())
        .setMinSdkVersion(minSdk)
        .setV1SigningEnabled(v1)
        .setV2SigningEnabled(v2)
        .setV3SigningEnabled(v3)
        .setV4SigningEnabled(false)
        .setDebuggableApkPermitted(true)
        .setAlignmentPreserved(true)
        .build()
        .sign();
  }
}
