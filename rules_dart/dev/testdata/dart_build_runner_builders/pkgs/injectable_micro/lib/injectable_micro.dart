import 'package:injectable/injectable.dart';

export 'injectable_micro.module.dart';
export 'src/logger.dart';

@InjectableInit.microPackage()
void initMicroPackage() {}
