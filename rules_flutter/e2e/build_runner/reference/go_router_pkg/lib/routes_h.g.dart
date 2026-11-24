// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_h.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$hListRoute];

RouteBase get $hListRoute => GoRouteData.$route(
  path: '/h',
  hasOverriddenOnExit: false,
  factory: $HListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $HItemRoute._fromState,
    ),
  ],
);

mixin $HListRoute on GoRouteData {
  static HListRoute _fromState(GoRouterState state) => HListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  HListRoute get _self => this as HListRoute;

  @override
  String get location => GoRouteData.$location(
    '/h',
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

mixin $HItemRoute on GoRouteData {
  static HItemRoute _fromState(GoRouterState state) =>
      HItemRoute(state.pathParameters['id']!);

  HItemRoute get _self => this as HItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/h/${Uri.encodeComponent(_self.id)}');

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
