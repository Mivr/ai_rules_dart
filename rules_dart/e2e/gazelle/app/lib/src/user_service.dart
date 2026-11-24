import 'models/user.dart';
import 'user_repository.dart';

class UserService {
  UserService(this._users);

  final UserRepository _users;

  Future<String> greet(int id) async {
    final user = await _users.byId(id);
    return user == null ? 'Hello, stranger' : 'Hello, ${user.displayName}';
  }

  Future<void> rename(int id, String name) async {
    final user = await _users.byId(id);
    if (user == null) throw StateError('no user $id');
    await _users.save(User(id: id, displayName: name, email: user.email));
  }
}
