import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'screens/connection_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/barrel_explorer_screen.dart';
import 'screens/query_screen.dart';
import 'screens/barrel_stats_screen.dart';
import 'screens/traversal_screen.dart';
import 'theme/app_theme.dart';

class BitBarrelAdminApp extends StatelessWidget {
  BitBarrelAdminApp({super.key});

  final _router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => ConnectionScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => DashboardScreen(),
      ),
      GoRoute(
        path: '/explorer',
        builder: (context, state) => const BarrelExplorerScreen(),
      ),
      GoRoute(
        path: '/query',
        builder: (context, state) => const QueryScreen(),
      ),
      GoRoute(
        path: '/stats',
        builder: (context, state) => const BarrelStatsScreen(),
      ),
      GoRoute(
        path: '/traversal',
        builder: (context, state) => const TraversalScreen(),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BitBarrel Admin Console',
      theme: AppTheme.lightTheme,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
