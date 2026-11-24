import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_g.g.dart';

@TypedGoRoute<GListRoute>(
  path: '/g',
  routes: [TypedGoRoute<GItemRoute>(path: ':id')],
)
class GListRoute extends GoRouteData with $GListRoute {
  const GListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class GItemRoute extends GoRouteData with $GItemRoute {
  const GItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
