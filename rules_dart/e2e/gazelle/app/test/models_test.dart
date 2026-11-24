import 'package:app/src/models/settings.dart';
import 'package:app/src/models/user.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('user round-trips through JSON with snake_case keys', () {
    final user = User.fromJson(userJson);
    expect(user.displayName, 'Ada');
    expect(user.toJson(), userJson);
  });

  test('settings have defaults and copyWith', () {
    const settings = Settings();
    expect(settings.theme, Theme.system);
    final bigger = settings.copyWith(fontSize: 18);
    expect(bigger.fontSize, 18);
    expect(Settings.fromJson(bigger.toJson()), bigger);
  });
}
