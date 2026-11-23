import 'package:mockito/mockito.dart';
import 'package:mockito_fixture/mock_targets.mocks.dart';
import 'package:test/test.dart';

void main() {
  test(
    'mockito_library generates a mock beside the annotated library',
    () async {
      final mock = MockApi();
      when(mock.fetch('answer')).thenAnswer((_) async => '42');
      expect(await mock.fetch('answer'), '42');
      verify(mock.fetch('answer')).called(1);
    },
  );
}
