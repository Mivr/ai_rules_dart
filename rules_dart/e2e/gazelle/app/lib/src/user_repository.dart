import 'models/user.dart';

abstract class UserRepository {
  Future<User?> byId(int id);
  Future<void> save(User user);
}
