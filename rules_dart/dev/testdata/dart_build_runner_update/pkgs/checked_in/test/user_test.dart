import 'package:checked_in/user.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() => test('user', () => expect(User.fromJson(fixture).name, 'a'));
