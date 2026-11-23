import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'di.config.dart';
import 'store.dart';

export 'store.dart';

@InjectableInit(preferRelativeImports: true)
GetIt configure(GetIt getIt) => getIt.init();
