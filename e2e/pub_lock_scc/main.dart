import 'dart:io';

import 'package:dio/dio.dart';

void main() {
  const url = 'https://pub.dev';
  final dio = Dio()
    ..options.baseUrl = url
    ..interceptors.add(LogInterceptor());

  // The interceptor list is dio-specific API surface: resolving it proves
  // the package's own libraries compiled, not just its pubspec.
  stdout.writeln('dio $url ready');
  // The cascade above builds the client; reading the result back needs the
  // receiver again, which cannot join the building cascade.
  // ignore: cascade_invocations, the read cannot join the building cascade.
  stdout.writeln('interceptors: ${dio.interceptors.length}');
}
