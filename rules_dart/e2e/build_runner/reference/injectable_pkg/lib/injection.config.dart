// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;
import 'package:injectable_micro/injectable_micro.dart' as _i410;
import 'package:injectable_pkg/src/data/http_client.dart' as _i900;
import 'package:injectable_pkg/src/domain/user_service.dart' as _i423;

const String _dev = 'dev';
const String _test = 'test';
const String _prod = 'prod';

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  Future<_i174.GetIt> init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) async {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    await _i410.InjectableMicroPackageModule().init(gh);
    final configModule = _$ConfigModule();
    await gh.factoryAsync<DateTime>(
      () => configModule.startedAt,
      preResolve: true,
    );
    gh.singleton<_i900.HttpClient>(
      () => _i900.FakeHttpClient(),
      registerFor: {_dev, _test},
    );
    gh.factory<String>(() => configModule.baseUrl, instanceName: 'baseUrl');
    gh.singleton<_i900.HttpClient>(
      () => _i900.RealHttpClient(),
      registerFor: {_prod},
    );
    gh.factory<_i423.UserService>(
      () => _i423.UserService(
        gh<_i900.HttpClient>(),
        gh<_i410.Logger>(),
        gh<String>(instanceName: 'baseUrl'),
      ),
    );
    gh.lazySingleton<_i423.Session>(
      () => _i423.Session(gh<_i423.UserService>()),
      dispose: (i) => i.close(),
    );
    return this;
  }
}

class _$ConfigModule extends _i900.ConfigModule {}
