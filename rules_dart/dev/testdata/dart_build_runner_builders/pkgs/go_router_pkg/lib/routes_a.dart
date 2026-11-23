import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_a.g.dart';

@TypedGoRoute<AListRoute>(
  path: '/a',
  routes: [TypedGoRoute<AItemRoute>(path: ':id')],
)
class AListRoute extends GoRouteData with $AListRoute {
  const AListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class AItemRoute extends GoRouteData with $AItemRoute {
  const AItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
