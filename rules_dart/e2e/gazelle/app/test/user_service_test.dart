import 'package:app/src/models/user.dart';
import 'package:app/src/user_repository.dart';
import 'package:app/src/user_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'user_service_test.mocks.dart';

@GenerateNiceMocks([MockSpec<UserRepository>()])
void main() {
  late MockUserRepository users;
  late UserService service;

  setUp(() {
    users = MockUserRepository();
    service = UserService(users);
  });

  test('greets a known user', () async {
    when(users.byId(1)).thenAnswer((_) async => User(id: 1, displayName: 'Ada'));
    expect(await service.greet(1), 'Hello, Ada');
  });

  test('greets a stranger', () async {
    expect(await service.greet(2), 'Hello, stranger');
  });

  test('renames through the repository', () async {
    when(users.byId(3)).thenAnswer((_) async => User(id: 3, displayName: 'Old', email: 'a@b.c'));
    await service.rename(3, 'New');
    final saved = verify(users.save(captureAny)).captured.single as User;
    expect(saved.displayName, 'New');
    expect(saved.email, 'a@b.c');
  });
}
