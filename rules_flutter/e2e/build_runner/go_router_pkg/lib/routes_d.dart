import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_d.g.dart';

@TypedGoRoute<DListRoute>(
  path: '/d',
  routes: [TypedGoRoute<DItemRoute>(path: ':id')],
)
class DListRoute extends GoRouteData with $DListRoute {
  const DListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class DItemRoute extends GoRouteData with $DItemRoute {
  const DItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
