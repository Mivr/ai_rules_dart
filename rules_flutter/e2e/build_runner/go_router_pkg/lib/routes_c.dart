import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_c.g.dart';

@TypedGoRoute<CListRoute>(
  path: '/c',
  routes: [TypedGoRoute<CItemRoute>(path: ':id')],
)
class CListRoute extends GoRouteData with $CListRoute {
  const CListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class CItemRoute extends GoRouteData with $CItemRoute {
  const CItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
