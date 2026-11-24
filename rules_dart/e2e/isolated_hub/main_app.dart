import 'package:analyzer/dart/analysis/utilities.dart';

void main() {
  final result = parseString(content: 'void main() {}');
  print('app: ${result.errors.length} errors');
}
