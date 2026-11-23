import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes.g.dart';

@TypedGoRoute<HomeRoute>(
  path: '/',
  routes: [
    TypedGoRoute<FamilyRoute>(
      path: 'family/:fid',
      routes: [TypedGoRoute<PersonRoute>(path: 'person/:pid')],
    ),
  ],
)
class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class FamilyRoute extends GoRouteData with $FamilyRoute {
  const FamilyRoute(this.fid, {this.filter});

  final String fid;
  final String? filter;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

class PersonRoute extends GoRouteData with $PersonRoute {
  const PersonRoute(this.fid, this.pid, {this.details = false});

  final String fid;
  final int pid;
  final bool details;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}

@TypedGoRoute<SettingsRoute>(path: '/settings')
class SettingsRoute extends GoRouteData with $SettingsRoute {
  const SettingsRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox();
}
