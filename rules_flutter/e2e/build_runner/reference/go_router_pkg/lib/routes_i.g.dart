// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'routes_i.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$iListRoute];

RouteBase get $iListRoute => GoRouteData.$route(
  path: '/i',
  hasOverriddenOnExit: false,
  factory: $IListRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: ':id',
      hasOverriddenOnExit: false,
      factory: $IItemRoute._fromState,
    ),
  ],
);

mixin $IListRoute on GoRouteData {
  static IListRoute _fromState(GoRouterState state) => IListRoute(
    page: _$convertMapValue('page', state.uri.queryParameters, int.parse) ?? 1,
  );

  IListRoute get _self => this as IListRoute;

  @override
  String get location => GoRouteData.$location(
    '/i',
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

mixin $IItemRoute on GoRouteData {
  static IItemRoute _fromState(GoRouterState state) =>
      IItemRoute(state.pathParameters['id']!);

  IItemRoute get _self => this as IItemRoute;

  @override
  String get location =>
      GoRouteData.$location('/i/${Uri.encodeComponent(_self.id)}');

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
