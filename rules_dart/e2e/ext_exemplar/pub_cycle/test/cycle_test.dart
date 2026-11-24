import 'package:alpha/alpha.dart';
import 'package:beta/beta.dart';
import 'package:test/test.dart';

void main() {
  test('dart_package_member keeps two cyclic packages in one library', () {
    expect(alphaGreeting(), 'alpha greets beta');
    expect(betaGreeting(), 'beta greets alpha');
  });
}
