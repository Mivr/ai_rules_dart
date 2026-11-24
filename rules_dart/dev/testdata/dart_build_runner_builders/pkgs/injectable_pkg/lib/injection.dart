import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:injectable_micro/injectable_micro.dart';

import 'injection.config.dart';

final getIt = GetIt.instance;

@InjectableInit(
  externalPackageModulesBefore: [ExternalModule(InjectableMicroPackageModule)],
)
Future<void> configureDependencies(String environment) =>
    getIt.init(environment: environment);
