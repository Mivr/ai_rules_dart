import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

enum Theme { light, dark, system }

@freezed
abstract class Settings with _$Settings {
  const factory Settings({
    @Default(Theme.system) Theme theme,
    @Default(14) int fontSize,
    @Default(<String>[]) List<String> pinned,
  }) = _Settings;

  factory Settings.fromJson(Map<String, dynamic> json) =>
      _$SettingsFromJson(json);
}
