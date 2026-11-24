import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes_f.g.dart';

@TypedGoRoute<FListRoute>(
  path: '/f',
  routes: [TypedGoRoute<FItemRoute>(path: ':id')],
)
class FListRoute extends GoRouteData with $FListRoute {
  const FListRoute({this.page = 1});

  final int page;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class FItemRoute extends GoRouteData with $FItemRoute {
  const FItemRoute(this.id);

  final String id;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
