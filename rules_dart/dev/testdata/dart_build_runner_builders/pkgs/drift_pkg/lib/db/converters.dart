import 'package:drift/drift.dart';

class Colour {
  const Colour(this.argb);
  final int argb;
}

class ColourConverter extends TypeConverter<Colour, int> {
  const ColourConverter();

  @override
  Colour fromSql(int fromDb) => Colour(fromDb);

  @override
  int toSql(Colour value) => value.argb;
}
