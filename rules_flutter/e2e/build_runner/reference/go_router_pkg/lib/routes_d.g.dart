// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_d.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$dListRoute];

RouteBase get $dListRoute => GoRouteData.$route(
  path: '/d',
  hasOverriddenOnExit: false,
  factory: $DListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $DItemRoute._fromState,
    ),
  ],
);

mixin $DListRoute on GoRouteData {
  static DListRoute _fromState(GoRouterState state) => DListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  DListRoute get _self => this as DListRoute;

  @override
  String get location => GoRouteData.$location(
    '/d',
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

mixin $DItemRoute on GoRouteData {
  static DItemRoute _fromState(GoRouterState state) =>
      DItemRoute(state.pathParameters['id']!);

  DItemRoute get _self => this as DItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/d/${Uri.encodeComponent(_self.id)}');

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
