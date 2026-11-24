import 'package:injectable/injectable.dart';

const dev = Environment('dev');

abstract class HttpClient {
  Future<String> get(String path);
}

@Singleton(as: HttpClient, env: [Environment.prod])
class RealHttpClient implements HttpClient {
  @override
  Future<String> get(String path) async => path;
}

@Singleton(as: HttpClient, env: ['dev', 'test'])
class FakeHttpClient implements HttpClient {
  @override
  Future<String> get(String path) async => 'fake';
}

@module
abstract class ConfigModule {
  @Named('baseUrl')
  String get baseUrl => 'https://example.invalid';

  @preResolve
  Future<DateTime> get startedAt async => DateTime(2026);
}
