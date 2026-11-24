// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_g.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$gListRoute];

RouteBase get $gListRoute => GoRouteData.$route(
  path: '/g',
  hasOverriddenOnExit: false,
  factory: $GListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $GItemRoute._fromState,
    ),
  ],
);

mixin $GListRoute on GoRouteData {
  static GListRoute _fromState(GoRouterState state) => GListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  GListRoute get _self => this as GListRoute;

  @override
  String get location => GoRouteData.$location(
    '/g',
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

mixin $GItemRoute on GoRouteData {
  static GItemRoute _fromState(GoRouterState state) =>
      GItemRoute(state.pathParameters['id']!);

  GItemRoute get _self => this as GItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/g/${Uri.encodeComponent(_self.id)}');

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
