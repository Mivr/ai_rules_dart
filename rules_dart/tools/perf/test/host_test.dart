import 'dart:io';

import 'package:perf/src/host.dart';
import 'package:test/test.dart';

/// A process table with a Bazel server (10) with a worker (11) under a
/// sandbox (12), another server (20), and a shell (30).
Directory _proc() {
  final dir = Directory.systemTemp.createTempSync('proc');
  void proc(int pid, int ppid, List<String> argv, {int rssPages = 1}) {
    final d = Directory('${dir.path}/$pid')..createSync();
    File('${d.path}/cmdline').writeAsStringSync('${argv.join('\u0000')}\u0000');
    File('${d.path}/stat').writeAsStringSync('$pid (some name) S $ppid 1 1 0');
    File('${d.path}/statm').writeAsStringSync('100 $rssPages 0 0 0 0 0');
  }

  proc(10, 1, [
    'bazel(ws)',
    '-jar',
    '/ob/install/x/A-server.jar',
    '--output_base=/ob/a',
  ]);
  proc(12, 10, ['linux-sandbox'], rssPages: 2);
  proc(11, 12, ['java', 'Worker', '--persistent_worker'], rssPages: 3);
  proc(20, 1, [
    'bazel(ws2)',
    '-jar',
    '/ob/install/x/A-server.jar',
    '--output_base=/ob/b',
  ]);
  proc(30, 1, ['bash']);
  File('${dir.path}/loadavg').writeAsStringSync('7.25 6.00 5.00 2/300 1234\n');
  return dir;
}

void main() {
  late Directory dir;
  late Host host;
  setUp(() {
    dir = _proc();
    host = Host(procRoot: dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('the load average', () => expect(host.load1(), 7.25));

  test('Bazel servers by output base, others than the measured one', () {
    expect(host.bazelServers(), {10: '/ob/a', 20: '/ob/b'});
    expect(host.otherBazelServers('/ob/a'), 1);
    expect(host.otherBazelServers(null), 2);
  });

  test('the persistent workers below a server', () {
    expect(host.tree(10), {10, 11, 12});
    expect(host.workers(10), {11});
    expect(host.workers(20), isEmpty);
  });

  test('the resident set of a tree, sampled', () async {
    final s = RssSampler(
      () => 10,
      host: host,
      every: const Duration(milliseconds: 5),
    )..start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(s.stop(), (1 + 2 + 3) * 4096 / (1 << 20));
  });

  test('KILLED_UNKNOWN lines across the rotated server logs', () {
    final ob = Directory('${dir.path}/ob')..createSync();
    File('${ob.path}/java.log.host.user.log.java.1')
        .writeAsStringSync('a\nDestroying worker KILLED_UNKNOWN\n');
    File('${ob.path}/java.log.host.user.log.java.2')
        .writeAsStringSync('KILLED_UNKNOWN\nKILLED_UNKNOWN x\n');
    File('${ob.path}/other.log').writeAsStringSync('KILLED_UNKNOWN\n');
    expect(killedUnknown(ob.path), 3);
    expect(killedUnknown('${dir.path}/none'), 0);
  });
}
