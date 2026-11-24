import 'package:injectable/injectable.dart';
import 'package:injectable_micro/injectable_micro.dart';

import '../data/http_client.dart';

@injectable
class UserService {
  UserService(this._client, this._logger, @Named('baseUrl') this.baseUrl);

  final HttpClient _client;
  final Logger _logger;
  final String baseUrl;

  Future<String> me() {
    _logger.log('me');
    return _client.get('$baseUrl/me');
  }
}

@lazySingleton
class Session {
  Session(this.users);
  final UserService users;

  @disposeMethod
  void close() {}
}
