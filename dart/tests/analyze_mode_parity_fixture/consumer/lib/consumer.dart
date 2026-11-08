import 'package:parity_dep/dep.dart';

/// Consumer implementation extending BaseConfig.
class ConsumerConfig extends BaseConfig {
  @override
  void configure(bool a, bool b) {}
}

/// Helper extracting an integer value from a dynamic map.
int? extractValue(Map<String, dynamic> map) {
  if (map['k'] case final int v) {
    return v;
  }
  return null;
}
