/// Quality checks for one documentation string.
library;

const _minWords = 3;
const _minCharacters = 15;

final _forbidden = RegExp(
  r'\b(TODO|TBD|FIXME|XXX)\b|see above',
  caseSensitive: false,
);

/// Words that add nothing when a doc only restates a symbol's name.
const _noise = {
  'the',
  'a',
  'an',
  'of',
  'for',
  'this',
  'is',
  'rule',
  'macro',
  'function',
  'attribute',
  'parameter',
  'param',
  'provider',
  'field',
  'aspect',
  'target',
  'tag',
  'class',
  'extension',
  'module',
  'repository',
};

/// The first quality rule [doc] breaks, or null when it passes.
///
/// [name] is the bare name of the symbol, attribute, field or parameter the
/// doc describes.
String? docQualityRule(String doc, String name) {
  final String text = doc.trim();
  if (text.split(RegExp(r'\s+')).length < _minWords ||
      text.length < _minCharacters) {
    return 'too-short';
  }
  if (_forbidden.hasMatch(text)) return 'forbidden-phrase';
  if (_restates(text, name)) return 'restates-name';
  return null;
}

List<String> _words(String text) => [
  for (final word in RegExp('[A-Za-z0-9]+').allMatches(
    text.replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}'),
  ))
    word[0]!.toLowerCase(),
].where((word) => !_noise.contains(word)).toList();

bool _restates(String doc, String name) {
  final List<String> docWords = _words(doc);
  final List<String> nameWords = _words(name);
  if (nameWords.isEmpty) return false;
  return docWords.join(' ') == nameWords.join(' ');
}
