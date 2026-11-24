import 'package:dio/dio.dart';
import 'package:dio_web_adapter/dio_web_adapter.dart';

void main() {
  // Naming `package:dio_web_adapter` outright proves the member's own root
  // resolves on web — the acceptance this binary exists for. The marker
  // string survives dart2js minification so the output test can find it.
  final adapter = createAdapter();
  final dio = Dio()..httpClientAdapter = adapter;

  // The marker string survives dart2js minification so the output test can
  // find it in the bundle.
  // ignore: avoid_print, this program's only output is the marker.
  print('dio web adapter ready: ${identical(dio.httpClientAdapter, adapter)}');
}
