import 'package:legacy_mixin_fixture_legacy/legacy.dart';
import 'package:legacy_mixin_fixture_mid/mid.dart';

class DirectThing with LegacyMixin, MidMixin {}

class SubChained extends ChainedLegacy {}

void main() {
  final direct = DirectThing()
    ..bump = 5
    ..prefix = 'direct';
  print(direct.decorate(direct.greet('world')));

  final chained = SubChained()..bump = 2;
  print(chained.decorate(chained.greet('chain')));

  try {
    direct.failInLegacy();
  } catch (e, st) {
    final frame = st
        .toString()
        .split('\n')
        .firstWhere((l) => l.contains('failInLegacy'))
        .trim();
    print('$e|$frame');
  }
}
