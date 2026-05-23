import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import '../ws/user_ws.dart';
import 'chat.dart';
import 'invites.dart';
import 'profile.dart';

class RoomsScreen extends ConsumerStatefulWidget {
  const RoomsScreen({super.key});
  @override
  ConsumerState<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends ConsumerState<RoomsScreen> {
  String _query = '';

  Future<void> _newRoom() async {
    final ctrl = TextEditingController();
    bool isPublic = true;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: GlassCard(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Новая комната',
                    style: TextStyle(
                      color: AppColors.onGlass,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassTextField(
                    controller: ctrl,
                    placeholder: 'Название',
                    autofocus: true,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          isPublic
                              ? 'Публичная — видна всем'
                              : 'Приватная — по приглашению',
                          style: const TextStyle(color: AppColors.onGlassMuted, fontSize: 12),
                        ),
                      ),
                      GlassSwitch(
                        value: isPublic,
                        onChanged: (v) => setLocal(() => isPublic = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton.custom(
                          onTap: () => Navigator.pop(ctx, false),
                          height: 42,
                          width: double.infinity,
                          useOwnLayer: true,
                          shape: LiquidRoundedSuperellipse(borderRadius: 12),
                          child: const Center(
                            child: Text(
                              'Отмена',
                              style: TextStyle(color: AppColors.onGlass),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassButton.custom(
                          onTap: () => Navigator.pop(ctx, true),
                          glowColor: AppColors.accent,
                          height: 42,
                          width: double.infinity,
                          useOwnLayer: true,
                          shape: LiquidRoundedSuperellipse(borderRadius: 12),
                          child: const Center(
                            child: Text(
                              'Создать',
                              style: TextStyle(
                                color: AppColors.onGlass,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      final auth = ref.read(authProvider);
      if (auth == null) return;
      try {
        final r = await Api(token: auth.token)
            .createRoom(ctrl.text.trim(), isPublic: isPublic);
        await RoomsCache.upsert({...r, 'is_member': true, 'role': 'owner'});
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final roomsAsync = ref.watch(roomsProvider);
    final invitesAsync = ref.watch(invitesProvider);
    final invitesCount = invitesAsync.valueOrNull?.length ?? 0;
    final connected = ref.watch(userWsConnectedProvider).valueOrNull ?? false;

    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: GlassAppBar(
          centerTitle: false,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Комнаты',
                style: TextStyle(
                  color: AppColors.onGlass,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected ? const Color(0xFF34D399) : const Color(0xFFFF8A65),
                  boxShadow: connected
                      ? [
                          BoxShadow(
                            color: const Color(0xFF34D399).withOpacity(0.6),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
            ],
          ),
          actions: [
            GlassIconButton(
              size: 36,
              icon: invitesCount > 0
                  ? GlassBadge(
                      count: invitesCount,
                      backgroundColor: AppColors.accent,
                      child: const Icon(Icons.mail_outline, color: AppColors.onGlass),
                    )
                  : const Icon(Icons.mail_outline, color: AppColors.onGlass),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const InvitesScreen()),
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              size: 36,
              icon: const Icon(Icons.account_circle_outlined, color: AppColors.onGlass),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              size: 36,
              icon: const Icon(Icons.logout, color: AppColors.onGlass),
              onPressed: () => ref.read(authProvider.notifier).logout(),
            ),
            const SizedBox(width: 8),
          ],
        ),
        floatingActionButton: GlassButton(
          icon: const Icon(Icons.add, color: AppColors.onGlass),
          onTap: _newRoom,
          width: 56,
          height: 56,
          glowColor: AppColors.accent,
          useOwnLayer: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: GlassSearchBar(
                  placeholder: 'Поиск по комнатам',
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
              if (auth != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '@${auth.username}',
                      style: const TextStyle(color: AppColors.onGlassDim, fontSize: 12),
                    ),
                  ),
                ),
              Expanded(child: _body(roomsAsync)),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _body(AsyncValue<List<CachedRoom>> roomsAsync) {
    return roomsAsync.when(
      loading: () => const Center(child: GlassProgressIndicator.circular(size: 28)),
      error: (e, _) => Center(
        child: Text('$e', style: const TextStyle(color: AppColors.danger)),
      ),
      data: (rooms) {
        final filtered = _query.isEmpty
            ? rooms
            : rooms
                .where((r) => r.name.toLowerCase().contains(_query))
                .toList(growable: false);
        if (filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _query.isEmpty
                    ? 'Пока ни одной комнаты.\nНажми + чтобы создать.'
                    : 'Ничего не нашлось.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.onGlassMuted),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
          itemCount: filtered.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _RoomTile(room: filtered[i]),
          ),
        );
      },
    );
  }
}

class _RoomTile extends ConsumerWidget {
  final CachedRoom room;
  const _RoomTile({required this.room});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    roomId: room.id,
                    roomName: room.name,
                    isPublic: room.isPublic,
                    muted: room.muted,
                  ),
                ),
              ),
              borderRadius: radius,
              splashColor: const Color(0x1FFFFFFF),
              highlightColor: const Color(0x0FFFFFFF),
              hoverColor: const Color(0x0AFFFFFF),
            ),
          ),
        ),
      ],
    );
  }
}

class RoomTileContent extends StatelessWidget {
  final CachedRoom room;
  const RoomTileContent({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: room.isPublic
              ? AppColors.blobIndigo.withOpacity(0.55)
              : AppColors.blobViolet.withOpacity(0.55),
          child: Icon(
            room.isPublic ? Icons.public : Icons.lock_outline,
            color: AppColors.onGlass,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.onGlass,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (room.muted)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.notifications_off,
                          size: 14, color: AppColors.onGlassDim),
                    ),
                ],
              ),
              if ((room.lastText ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    room.lastText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.onGlassDim, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (room.unread > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: room.muted ? const Color(0x33FFFFFF) : AppColors.accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${room.unread}',
              style: const TextStyle(
                color: AppColors.onGlass,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
