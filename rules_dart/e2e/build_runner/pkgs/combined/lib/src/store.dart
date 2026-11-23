import 'package:injectable/injectable.dart';

import 'models.dart';

@lazySingleton
class NoteStore {
  final List<Note> notes = [];
}

@injectable
class NoteController {
  NoteController(this.store);
  final NoteStore store;
}
