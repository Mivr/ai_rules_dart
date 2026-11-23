import 'package:freezed_annotation/freezed_annotation.dart';

import 'shape.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

@freezed
abstract class Settings with _$Settings {
  const Settings._();

  const factory Settings({
    @Default(false) bool darkMode,
    @JsonKey(name: 'favourite_shape') Shape? favouriteShape,
    @Default(<String, int>{}) Map<String, int> counters,
  }) = _Settings;

  factory Settings.fromJson(Map<String, dynamic> json) =>
      _$SettingsFromJson(json);

  bool get hasShape => favouriteShape != null;
}

/// freezed only, no JSON.
@freezed
abstract class Draft with _$Draft {
  const factory Draft(String title, {String? body}) = _Draft;
}
