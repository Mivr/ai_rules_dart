// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$homeRoute, $settingsRoute];

RouteBase get $homeRoute => GoRouteData.$route(
  path: '/',
  hasOverriddenOnExit: false,
  factory: $HomeRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: 'family/:fid',
      hasOverriddenOnExit: false,
      factory: $FamilyRoute._fromState,
      routes: [
        GoRouteData.$route(
          path: 'person/:pid',
          hasOverriddenOnExit: false,
          factory: $PersonRoute._fromState,
        ),
      ],
    ),
  ],
);

mixin $HomeRoute on GoRouteData {
  static HomeRoute _fromState(GoRouterState state) => const HomeRoute();

  @override
  String get location => GoRouteData.$location('/');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $FamilyRoute on GoRouteData {
  static FamilyRoute _fromState(GoRouterState state) => FamilyRoute(
    state.pathParameters['fid']!,
    filter: state.uri.queryParameters['filter'],
  );

  FamilyRoute get _self => this as FamilyRoute;

  @override
  String get location => GoRouteData.$location(
    '/family/${Uri.encodeComponent(_self.fid)}',
    queryParams: {if (_self.filter != null) 'filter': _self.filter},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $PersonRoute on GoRouteData {
  static PersonRoute _fromState(GoRouterState state) => PersonRoute(
    state.pathParameters['fid']!,
    int.parse(state.pathParameters['pid']!),
    details:
        _$convertMapValue(
          'details',
          state.uri.queryParameters,
          _$boolConverter,
        ) ??
        false,
  );

  PersonRoute get _self => this as PersonRoute;

  @override
  String get location => GoRouteData.$location(
    '/family/${Uri.encodeComponent(_self.fid)}/person/${Uri.encodeComponent(_self.pid.toString())}',
    queryParams: {
      if (_self.details != false) 'details': _self.details.toString(),
    },
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

T? _$convertMapValue<T>(
  String key,
  Map<String, String> map,
  T? Function(String) converter,
) {
  final value = map[key];
  return value == null ? null : converter(value);
}

bool _$boolConverter(String value) {
  switch (value) {
    case 'true':
      return true;
    case 'false':
      return false;
    default:
      throw UnsupportedError('Cannot convert "$value" into a bool.');
  }
}

RouteBase get $settingsRoute => GoRouteData.$route(
  path: '/settings',
  hasOverriddenOnExit: false,
  factory: $SettingsRoute._fromState,
);

mixin $SettingsRoute on GoRouteData {
  static SettingsRoute _fromState(GoRouterState state) => const SettingsRoute();

  @override
  String get location => GoRouteData.$location('/settings');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}
