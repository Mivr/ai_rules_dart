import 'package:injectable/injectable.dart';

abstract class Logger {
  void log(String message);
}

@LazySingleton(as: Logger)
class PrintLogger implements Logger {
  @override
  void log(String message) {}
}
