import 'package:combined/src/store.dart';
import 'package:mockito/annotations.dart';
import 'package:test/test.dart';

import 'store_test.mocks.dart';

@GenerateNiceMocks([MockSpec<NoteStore>()])
void main() {
  test('mock store', () {
    final store = MockNoteStore();
    expect(store.notes, isEmpty);
  });
}
