import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_h.g.dart';

@TypedGoRoute<HListRoute>(
  path: '/h',
  routes: [TypedGoRoute<HItemRoute>(path: ':id')],
)
class HListRoute extends GoRouteData with $HListRoute {
  const HListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class HItemRoute extends GoRouteData with $HItemRoute {
  const HItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
