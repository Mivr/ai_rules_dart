import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_i.g.dart';

@TypedGoRoute<IListRoute>(
  path: '/i',
  routes: [TypedGoRoute<IItemRoute>(path: ':id')],
)
class IListRoute extends GoRouteData with $IListRoute {
  const IListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class IItemRoute extends GoRouteData with $IItemRoute {
  const IItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
