import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_e.g.dart';

@TypedGoRoute<EListRoute>(
  path: '/e',
  routes: [TypedGoRoute<EItemRoute>(path: ':id')],
)
class EListRoute extends GoRouteData with $EListRoute {
  const EListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class EItemRoute extends GoRouteData with $EItemRoute {
  const EItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
