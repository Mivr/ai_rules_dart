// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_f.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$fListRoute];

RouteBase get $fListRoute => GoRouteData.$route(
  path: '/f',
  hasOverriddenOnExit: false,
  factory: $FListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $FItemRoute._fromState,
    ),
  ],
);

mixin $FListRoute on GoRouteData {
  static FListRoute _fromState(GoRouterState state) => FListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  FListRoute get _self => this as FListRoute;

  @override
  String get location => GoRouteData.$location(
    '/f',
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

mixin $FItemRoute on GoRouteData {
  static FItemRoute _fromState(GoRouterState state) =>
      FItemRoute(state.pathParameters['id']!);

  FItemRoute get _self => this as FItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/f/${Uri.encodeComponent(_self.id)}');

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
