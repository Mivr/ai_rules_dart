// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_b.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$bListRoute];

RouteBase get $bListRoute => GoRouteData.$route(
  path: '/b',
  hasOverriddenOnExit: false,
  factory: $BListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $BItemRoute._fromState,
    ),
  ],
);

mixin $BListRoute on GoRouteData {
  static BListRoute _fromState(GoRouterState state) => BListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  BListRoute get _self => this as BListRoute;

  @override
  String get location => GoRouteData.$location(
    '/b',
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

mixin $BItemRoute on GoRouteData {
  static BItemRoute _fromState(GoRouterState state) =>
      BItemRoute(state.pathParameters['id']!);

  BItemRoute get _self => this as BItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/b/${Uri.encodeComponent(_self.id)}');

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
