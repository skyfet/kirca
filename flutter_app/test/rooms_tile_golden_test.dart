import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:kirca/screens/rooms.dart';
import 'package:kirca/storage/cache.dart';
import 'package:kirca/theme/app_background.dart';
import 'package:kirca/theme/app_theme.dart';

CachedRoom _room({
  String name = 'Комната',
  bool isPublic = true,
  bool muted = false,
  int unread = 0,
  String? lastText,
}) =>
    CachedRoom(
      id: 'r1',
      name: name,
      isPublic: isPublic,
      isMember: true,
      role: 'member',
      muted: muted,
      unread: unread,
      lastText: lastText,
    );

Widget _harness({required Widget child, Size size = const Size(360, 96)}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: AppBackground()),
          Center(
            child: SizedBox.fromSize(
              size: size,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: child,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _tile(CachedRoom room) {
  final radius = BorderRadius.circular(14);
  return Stack(
    children: [
      GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: RoomTileContent(room: room),
      ),
      Positioned.fill(
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: () {}, borderRadius: radius),
        ),
      ),
    ],
  );
}

void main() {
  testWidgets('room tile · public, no unread', (tester) async {
    await tester.pumpWidget(_harness(
      child: _tile(_room(name: 'comet', lastText: 'hi')),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/room_tile_public.png'),
    );
  });

  testWidgets('room tile · private + unread', (tester) async {
    await tester.pumpWidget(_harness(
      child: _tile(_room(
        name: 'private room',
        isPublic: false,
        unread: 7,
        lastText: 'new msgs',
      )),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/room_tile_private_unread.png'),
    );
  });

  testWidgets('room tile · muted + unread', (tester) async {
    await tester.pumpWidget(_harness(
      child: _tile(_room(
        name: 'muted room',
        muted: true,
        unread: 12,
        lastText: 'last',
      )),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/room_tile_muted.png'),
    );
  });

  testWidgets('dialog buttons · rounded (not pill)', (tester) async {
    await tester.pumpWidget(_harness(
      size: const Size(360, 80),
      child: Row(
        children: [
          Expanded(
            child: GlassButton.custom(
              onTap: () {},
              height: 42,
              width: double.infinity,
              useOwnLayer: true,
              shape: LiquidRoundedSuperellipse(borderRadius: 12),
              child: const Center(
                child: Text('cancel', style: TextStyle(color: AppColors.onGlass)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GlassButton.custom(
              onTap: () {},
              glowColor: AppColors.accent,
              height: 42,
              width: double.infinity,
              useOwnLayer: true,
              shape: LiquidRoundedSuperellipse(borderRadius: 12),
              child: const Center(
                child: Text('create',
                    style: TextStyle(
                        color: AppColors.onGlass, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/dialog_buttons_rounded.png'),
    );
  });

  testWidgets('FAB · circular GlassButton', (tester) async {
    await tester.pumpWidget(_harness(
      size: const Size(120, 120),
      child: Center(
        child: GlassButton(
          icon: const Icon(Icons.add, color: AppColors.onGlass),
          onTap: () {},
          width: 56,
          height: 56,
          glowColor: AppColors.accent,
          useOwnLayer: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/fab_circular.png'),
    );
  });

  testWidgets('app background · solid palette', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(width: 360, height: 200, child: AppBackground()),
    ));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/app_background.png'),
    );
  });
}
