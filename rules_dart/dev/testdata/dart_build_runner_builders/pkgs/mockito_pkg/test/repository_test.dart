import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito_pkg/src/repository.dart';
import 'package:test/test.dart';

import 'repository_test.mocks.dart';

@GenerateNiceMocks([MockSpec<Repository<Item>>(as: #MockItemRepository)])
@GenerateMocks([Clock])
void main() {
  test('reads through the repository', () async {
    final repo = MockItemRepository();
    when(repo.byId(1)).thenAnswer((_) async => Item(1, 'one'));
    expect((await repo.byId(1))!.name, 'one');
    final clock = MockClock();
    when(clock.now()).thenReturn(DateTime(2026));
    expect(clock.now().year, 2026);
  });
}
