/// Writes or checks the plan of a `pubspec.lock`.
///
///     bazel run @rules_dart//dart/pub/plan -- write --lock <pubspec.lock> --out <plan.json>
///     bazel run @rules_dart//dart/pub/plan -- check --lock <pubspec.lock> --plan <plan.json>
///
/// `write` asks each hosted package's server for its listing
/// (`<url>/api/packages/<name>`, what `dart pub` reads), one request at a time
/// and at most four a second, and writes the plan the `pub` extension would
/// record, so it needs the network. `--server <url>` sends the requests to
/// another server (a mirror) while the plan keeps naming the lock's own
/// server. `check` exits non-zero when the plan does not plan exactly the
/// lock's hosted entries; it reads no network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_dart_pub_plan/plan.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 1; i + 1 < args.length; i += 2) {
    options[args[i].replaceFirst(RegExp('^--'), '')] = args[i + 1];
  }
  final String command = args.isEmpty ? '' : args.first;
  final String? cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
  String path(String p) => cwd == null || p.startsWith('/') ? p : '$cwd/$p';
  final String? lock = options['lock'];
  if (command == 'write' && lock != null && options['out'] != null) {
    final Map<String, Map<String, Object>> plans = await _plan(
      File(path(lock)).readAsStringSync(),
      options['server'],
    );
    File(path(options['out']!)).writeAsStringSync(renderPlan(plans));
    stdout.writeln('wrote ${plans.length} plans to ${options['out']}');
    return;
  }
  if (command == 'check' && lock != null && options['plan'] != null) {
    final List<String> problems = planProblems(
      File(path(lock)).readAsStringSync(),
      File(path(options['plan']!)).readAsStringSync(),
    );
    problems.forEach(stderr.writeln);
    if (problems.isNotEmpty) {
      stderr.writeln(
        'regenerate the plan: bazel run @rules_dart//dart/pub/plan -- write --lock $lock --out ${options['plan']}',
      );
      exitCode = 1;
    }
    return;
  }
  stderr.writeln(
    'usage: plan write --lock <pubspec.lock> --out <plan.json> [--server <url>]\n'
    '       plan check --lock <pubspec.lock> --plan <plan.json>',
  );
  exitCode = 2;
}

/// At most four requests a second to any server.
const _spacing = Duration(milliseconds: 250);

Future<Map<String, Map<String, Object>>> _plan(
  String lockText,
  String? server,
) async {
  final client = HttpClient()..userAgent = 'rules_dart pub plan';
  final plans = <String, Map<String, Object>>{};
  try {
    final List<HostedEntry> entries = hostedEntries(lockText).values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final entry in entries) {
      final started = Stopwatch()..start();
      final HttpClientRequest request = await client.getUrl(
        entry.listingUri(server),
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.pub.v2+json',
      );
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException(
          '${entry.listingUri(server)}: HTTP ${response.statusCode}',
        );
      }
      plans[entry.key] = planFromListing(
        jsonDecode(body) as Map<String, Object?>,
        entry,
      );
      final Duration left = _spacing - started.elapsed;
      if (left > Duration.zero) await Future<void>.delayed(left);
    }
  } finally {
    client.close();
  }
  return plans;
}
