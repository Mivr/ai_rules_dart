import 'package:corpus/corpus.dart';
import 'package:corpus_source_set/source_set_fixture.dart';

void main() {
  assert(
    corpusValue + sourceSetFixture == 2,
    'the corpus values must stay one each',
  );
}
