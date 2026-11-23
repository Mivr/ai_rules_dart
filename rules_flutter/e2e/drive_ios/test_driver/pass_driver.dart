import 'dart:convert';
import 'dart:io';

/// Host driver that connects to the launched app's VM service and exits 0.
Future<void> main() async {
  final rawUri = Platform.environment['VM_SERVICE_URL'];
  if (rawUri == null || rawUri.isEmpty) {
    stderr.writeln('DRIVE_PASS_NO_VM_SERVICE: VM_SERVICE_URL is not set');
    exit(2);
  }
  final httpUri = Uri.parse(rawUri);
  final wsPath = httpUri.path.endsWith('/')
      ? '${httpUri.path}ws'
      : '${httpUri.path}/ws';
  final wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: wsPath,
  );
  final ws = await WebSocket.connect(wsUri.toString());
  try {
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': '1', 'method': 'getVM'}));
    final reply = await ws
        .map((raw) => jsonDecode(raw as String) as Map<String, Object?>)
        .firstWhere((msg) => msg['id'] == '1');
    if (reply['result'] is! Map<String, Object?>) {
      stderr.writeln('DRIVE_PASS_BAD_VM_REPLY: $reply');
      exit(3);
    }
    stdout.writeln('DRIVE_PASS_OK: $rawUri');
  } finally {
    await ws.close();
  }
}
