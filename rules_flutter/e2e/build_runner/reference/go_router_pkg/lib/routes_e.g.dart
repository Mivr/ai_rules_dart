// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_e.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$eListRoute];

RouteBase get $eListRoute => GoRouteData.$route(
  path: '/e',
  hasOverriddenOnExit: false,
  factory: $EListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $EItemRoute._fromState,
    ),
  ],
);

mixin $EListRoute on GoRouteData {
  static EListRoute _fromState(GoRouterState state) => EListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  EListRoute get _self => this as EListRoute;

  @override
  String get location => GoRouteData.$location(
    '/e',
    queryParams: {if (_self.page != 1) 'page': _self.page.toString()},
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

mixin $EItemRoute on GoRouteData {
  static EItemRoute _fromState(GoRouterState state) =>
      EItemRoute(state.pathParameters['id']!);

  EItemRoute get _self => this as EItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/e/${Uri.encodeComponent(_self.id)}');

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
