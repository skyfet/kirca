import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../state.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import '../theme/design.dart';
import 'friends.dart';
import 'profile.dart';
import 'rooms.dart';

/// The authenticated home: a single glass shell hosting the three top-level
/// sections behind one persistent [GlassBottomBar]. Previously these were
/// reached through scattered icon buttons in the Rooms app-bar (plus a
/// dangerous one-tap logout); consolidating them into a tab bar gives the app
/// a stable navigation spine and frees the top bar for per-section actions.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _sections = [
    RoomsScreen(),
    FriendsScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Badge on the Друзья tab: pending friend requests + room invites.
    final invites = ref.watch(invitesProvider).valueOrNull?.length ?? 0;
    final requests = ref.watch(friendRequestsProvider).valueOrNull?.length ?? 0;
    final pending = invites + requests;

    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          extendBodyBehindAppBar: true,
          body: IndexedStack(index: _index, children: _sections),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.md, 0, AppSpace.md, AppSpace.sm),
              child: GlassBottomBar(
                selectedIndex: _index,
                onTabSelected: (i) => setState(() => _index = i),
                selectedIconColor: AppColors.onGlass,
                unselectedIconColor: AppColors.onGlassDim,
                indicatorColor: AppColors.accent.withOpacity(0.28),
                tabs: [
                  const GlassBottomBarTab(
                    icon: Icon(Icons.chat_bubble_outline),
                    activeIcon: Icon(Icons.chat_bubble),
                    label: 'Комнаты',
                    glowColor: AppColors.accent,
                  ),
                  GlassBottomBarTab(
                    icon: _maybeBadge(
                        const Icon(Icons.people_alt_outlined), pending),
                    activeIcon:
                        _maybeBadge(const Icon(Icons.people_alt), pending),
                    label: 'Друзья',
                    glowColor: AppColors.accent,
                  ),
                  const GlassBottomBarTab(
                    icon: Icon(Icons.account_circle_outlined),
                    activeIcon: Icon(Icons.account_circle),
                    label: 'Профиль',
                    glowColor: AppColors.accent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _maybeBadge(Widget icon, int count) {
    if (count <= 0) return icon;
    return GlassBadge(
      count: count,
      backgroundColor: AppColors.accent,
      child: icon,
    );
  }
}
