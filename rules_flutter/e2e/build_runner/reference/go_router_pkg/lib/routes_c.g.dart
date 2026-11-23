// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_c.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$cListRoute];

RouteBase get $cListRoute => GoRouteData.$route(
  path: '/c',
  hasOverriddenOnExit: false,
  factory: $CListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $CItemRoute._fromState,
    ),
  ],
);

mixin $CListRoute on GoRouteData {
  static CListRoute _fromState(GoRouterState state) => CListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  CListRoute get _self => this as CListRoute;

  @override
  String get location => GoRouteData.$location(
    '/c',
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

mixin $CItemRoute on GoRouteData {
  static CItemRoute _fromState(GoRouterState state) =>
      CItemRoute(state.pathParameters['id']!);

  CItemRoute get _self => this as CItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/c/${Uri.encodeComponent(_self.id)}');

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
