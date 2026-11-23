import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('dio constructs against the merged cycle', () {
    final dio = Dio()
      ..options.baseUrl = 'https://pub.dev'
      ..interceptors.add(LogInterceptor());
    expect(dio.options.baseUrl, 'https://pub.dev');
    expect(
      dio.interceptors.whereType<LogInterceptor>(),
      hasLength(1),
      reason: 'the LogInterceptor added above must be present',
    );
  });
}
