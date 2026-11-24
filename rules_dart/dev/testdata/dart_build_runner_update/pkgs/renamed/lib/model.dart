import 'package:freezed_annotation/freezed_annotation.dart';

part 'model.freezed.dart';

@freezed
abstract class Model with _$Model {
  const factory Model(int id) = _Model;
}
