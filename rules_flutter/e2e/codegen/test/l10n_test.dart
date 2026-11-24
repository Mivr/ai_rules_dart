// Exercises: what gen-l10n writes from l10n.yaml, compiled and executed
// against package:flutter: the generated Dart is valid against the real
// framework and the ICU messages evaluate correctly.
//
// The es/es_419 pair is deliberate: gen-l10n emits one file per primary
// language subtag, so both classes live in app_localizations_es.dart.

import 'package:codegen_e2e/l10n/app_localizations.dart';
import 'package:codegen_e2e/l10n/app_localizations_es.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generated Spanish localizations', () {
    final es = AppLocalizationsEs();

    test('interpolates a placeholder', () {
      expect(es.greeting('Ana'), '¡Hola, Ana!');
    });

    test('evaluates ICU plural branches', () {
      expect(es.bookCount(0), 'Sin libros');
      expect(es.bookCount(1), '1 libro');
      expect(es.bookCount(5), '5 libros');
    });

    test('evaluates ICU select branches', () {
      expect(es.pronoun('male'), 'Él lee');
      expect(es.pronoun('female'), 'Ella lee');
      expect(es.pronoun('other'), 'Elle lee');
    });
  });

  test('es_419 subclasses es rather than getting its own file', () {
    final es419 = AppLocalizationsEs419();
    expect(es419, isA<AppLocalizationsEs>());
    expect(es419.greeting('Ana'), '¡Hola, Ana!');
  });

  test(
    'supportedLocales carries every arb of arb-dir, region variants too',
    () {
      expect(AppLocalizations.supportedLocales, contains(const Locale('en')));
      expect(AppLocalizations.supportedLocales, contains(const Locale('es')));
      expect(
        AppLocalizations.supportedLocales,
        contains(const Locale('es', '419')),
      );
      expect(
        AppLocalizations.supportedLocales,
        contains(const Locale('en', 'US')),
      );
      expect(
        lookupAppLocalizations(const Locale('en', 'US')).greeting('Ana'),
        'Howdy, Ana!',
      );
    },
  );
}
