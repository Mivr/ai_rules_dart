// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_a.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$aListRoute];

RouteBase get $aListRoute => GoRouteData.$route(
  path: '/a',
  hasOverriddenOnExit: false,
  factory: $AListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $AItemRoute._fromState,
    ),
  ],
);

mixin $AListRoute on GoRouteData {
  static AListRoute _fromState(GoRouterState state) => AListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  AListRoute get _self => this as AListRoute;

  @override
  String get location => GoRouteData.$location(
    '/a',
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

mixin $AItemRoute on GoRouteData {
  static AItemRoute _fromState(GoRouterState state) =>
      AItemRoute(state.pathParameters['id']!);

  AItemRoute get _self => this as AItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/a/${Uri.encodeComponent(_self.id)}');

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
