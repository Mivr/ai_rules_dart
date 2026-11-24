import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_b.g.dart';

@TypedGoRoute<BListRoute>(
  path: '/b',
  routes: [TypedGoRoute<BItemRoute>(path: ':id')],
)
class BListRoute extends GoRouteData with $BListRoute {
  const BListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class BItemRoute extends GoRouteData with $BItemRoute {
  const BItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
