import 'package:json_annotation/json_annotation.dart';

/// Outside `generate_for`: json_serializable must not run here.
@JsonSerializable()
class NotGenerated {
  NotGenerated(this.value);
  final int value;
}
