import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'dart:convert';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/key_store.dart';
import '../crypto/room_keys.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import '../ws/user_ws.dart';
import 'chat.dart';
import 'friends.dart';
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
    bool e2e = false;
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
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
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
                        // E2E forces private — ignore taps on the public
                        // switch in that mode rather than disabling it (the
                        // glass widget set wants a non-null callback).
                        onChanged: (v) {
                          if (e2e) return;
                          setLocal(() => isPublic = v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          e2e
                              ? '🔒 Сквозное шифрование — сервер видит только шифротекст'
                              : 'Сквозное шифрование выключено',
                          style: const TextStyle(color: AppColors.onGlassMuted, fontSize: 12),
                        ),
                      ),
                      GlassSwitch(
                        value: e2e,
                        onChanged: (v) => setLocal(() {
                          e2e = v;
                          if (v) isPublic = false; // E2E rooms are always private
                        }),
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
        final api = Api(token: auth.token);
        // Block E2E room creation if we don't have a local identity yet —
        // we'd have no public key to wrap the room key for ourselves.
        if (e2e && (await KeyStore.loadIdentity()) == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Сначала настрой ключи шифрования в профиле'),
            ));
          }
          return;
        }
        final r = await api.createRoom(
          ctrl.text.trim(),
          isPublic: e2e ? false : isPublic,
          e2e: e2e,
        );
        await RoomsCache.upsert({...r, 'is_member': true, 'role': 'owner'});

        if (e2e) {
          // Generate the room key, wrap it for ourselves, publish.
          final identity = await KeyStore.loadIdentity();
          if (identity != null) {
            final roomKey = E2E.newRoomKey();
            final sealed = await E2E.sealRoomKey(
              recipientPubKey: identity.publicKey,
              roomKey: roomKey,
            );
            await api.publishRoomKeys(
              r['id'] as String,
              keyVersion: (r['key_version'] as num?)?.toInt() ?? 1,
              keys: [
                {
                  'member_user_id': auth.userId,
                  'sealed': base64Encode(sealed),
                },
              ],
            );
            RoomKeyCache.put(
              r['id'] as String,
              (r['key_version'] as num?)?.toInt() ?? 1,
              roomKey,
            );
          }
        }
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
    final roomsAsync = ref.watch(sortedRoomsProvider);
    final archivedAsync = ref.watch(archivedRoomsProvider);
    final archivedCount = archivedAsync.valueOrNull?.length ?? 0;
    final invitesAsync = ref.watch(invitesProvider);
    final friendReqAsync = ref.watch(friendRequestsProvider);
    final pendingCount = (invitesAsync.valueOrNull?.length ?? 0) +
        (friendReqAsync.valueOrNull?.length ?? 0);
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
              icon: pendingCount > 0
                  ? GlassBadge(
                      count: pendingCount,
                      backgroundColor: AppColors.accent,
                      child: const Icon(Icons.people_alt_outlined,
                          color: AppColors.onGlass),
                    )
                  : const Icon(Icons.people_alt_outlined,
                      color: AppColors.onGlass),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FriendsScreen()),
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
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
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
              Expanded(child: _body(roomsAsync, archivedCount)),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _body(AsyncValue<List<CachedRoom>> roomsAsync, int archivedCount) {
    return roomsAsync.when(
      loading: () => const Center(child: GlassProgressIndicator.circular(size: 28)),
      error: (e, _) => Center(
        child: Text('$e', style: const TextStyle(color: AppColors.danger)),
      ),
      data: (rooms) {
        final filtered = _query.isEmpty
            ? rooms
            : rooms
                .where((r) => _roomMatches(r, _query))
                .toList(growable: false);
        // The Archived entry only shows on the unfiltered list and when there's
        // something archived to see.
        final showArchivedEntry = _query.isEmpty && archivedCount > 0;
        if (filtered.isEmpty && !showArchivedEntry) {
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
        final itemCount = filtered.length + (showArchivedEntry ? 1 : 0);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
          itemCount: itemCount,
          itemBuilder: (_, i) {
            if (showArchivedEntry && i == filtered.length) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ArchivedEntryTile(count: archivedCount),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RoomTile(room: filtered[i]),
            );
          },
        );
      },
    );
  }

  /// Search match: room name, or the resolved DM peer handle for DM rooms.
  static bool _roomMatches(CachedRoom r, String q) {
    if (r.name.toLowerCase().contains(q)) return true;
    if (r.isDm && (r.dmPeerId ?? '').toLowerCase().contains(q)) return true;
    return false;
  }
}

/// Resolve a sensible display label for a room: peer handle for DMs (the
/// rooms payload doesn't carry the peer username, so we derive it from the
/// peer id), otherwise the room name.
String roomDisplayName(CachedRoom room) {
  if (room.isDm) {
    final peer = room.dmPeerId;
    if (peer != null && peer.isNotEmpty) return '@$peer';
    return room.name.isNotEmpty ? room.name : 'Личный чат';
  }
  return room.name;
}

class _RoomTile extends ConsumerWidget {
  final CachedRoom room;
  const _RoomTile({required this.room});

  void _openChat(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          roomId: room.id,
          roomName: roomDisplayName(room),
          isPublic: room.isPublic,
          muted: room.muted,
          // DMs are always end-to-end encrypted private chats.
          e2e: room.isDm ? true : room.e2e,
          keyVersion: room.keyVersion,
        ),
      ),
    );
  }

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
              onTap: () => _openChat(context),
              onLongPress: () => _showActions(context, ref),
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

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassListTile.standalone(
                  leading: Icon(
                    room.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                    color: AppColors.onGlass,
                  ),
                  title: Text(room.pinned ? 'Открепить' : 'Закрепить',
                      style: const TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePin(context, ref);
                  },
                ),
                GlassListTile.standalone(
                  leading: const Icon(Icons.notifications_outlined,
                      color: AppColors.onGlass),
                  title: const Text('Уведомления',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMuteMenu(context, ref);
                  },
                ),
                GlassListTile.standalone(
                  leading: Icon(
                    room.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                    color: AppColors.onGlass,
                  ),
                  title: Text(room.archived ? 'Разархивировать' : 'Архивировать',
                      style: const TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleArchive(context, ref);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMuteMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassListTile.standalone(
                  leading: const Icon(Icons.schedule, color: AppColors.onGlass),
                  title: const Text('Без звука 1 час',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _mute(context, ref,
                        DateTime.now().millisecondsSinceEpoch + 3600 * 1000);
                  },
                ),
                GlassListTile.standalone(
                  leading: const Icon(Icons.schedule, color: AppColors.onGlass),
                  title: const Text('Без звука 8 часов',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _mute(context, ref,
                        DateTime.now().millisecondsSinceEpoch + 8 * 3600 * 1000);
                  },
                ),
                GlassListTile.standalone(
                  leading: const Icon(Icons.notifications_off,
                      color: AppColors.onGlass),
                  title: const Text('Без звука, пока не включу',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _mute(context, ref, 0);
                  },
                ),
                if (room.muted)
                  GlassListTile.standalone(
                    leading: const Icon(Icons.notifications_active_outlined,
                        color: AppColors.accent),
                    title: const Text('Включить звук',
                        style: TextStyle(color: AppColors.accent)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _unmute(context, ref);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _togglePin(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final next = !room.pinned;
    await RoomsCache.setPinned(room.id, next);
    try {
      await Api(token: auth.token).patchMembership(room.id, pinned: next);
    } catch (e) {
      await RoomsCache.setPinned(room.id, !next); // rollback
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggleArchive(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final next = !room.archived;
    await RoomsCache.setArchived(room.id, next);
    try {
      await Api(token: auth.token).patchMembership(room.id, archived: next);
    } catch (e) {
      await RoomsCache.setArchived(room.id, !next); // rollback
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _mute(BuildContext context, WidgetRef ref, int mutedUntil) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final prev = room.mutedUntil;
    await RoomsCache.setMutedUntil(room.id, mutedUntil);
    try {
      await Api(token: auth.token).patchMembership(room.id, mutedUntil: mutedUntil);
    } catch (e) {
      await RoomsCache.setMutedUntil(room.id, prev); // rollback
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _unmute(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final prev = room.mutedUntil;
    await RoomsCache.setMutedUntil(room.id, null);
    try {
      await Api(token: auth.token).patchMembership(room.id, clearMute: true);
    } catch (e) {
      await RoomsCache.setMutedUntil(room.id, prev); // rollback
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Tappable entry that opens the archived-rooms view (F6).
class _ArchivedEntryTile extends StatelessWidget {
  final int count;
  const _ArchivedEntryTile({required this.count});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Stack(
      children: [
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.blobIndigo.withOpacity(0.35),
                child: const Icon(Icons.archive_outlined,
                    color: AppColors.onGlass, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Архив',
                  style: TextStyle(
                    color: AppColors.onGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('$count',
                  style: const TextStyle(
                      color: AppColors.onGlassDim, fontSize: 13)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppColors.onGlassDim),
            ],
          ),
        ),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ArchivedRoomsScreen()),
              ),
              borderRadius: radius,
              splashColor: const Color(0x1FFFFFFF),
              highlightColor: const Color(0x0FFFFFFF),
            ),
          ),
        ),
      ],
    );
  }
}

/// F6: separate view listing archived rooms. Reuses [_RoomTile] so the same
/// long-press actions (incl. Unarchive) are available.
class ArchivedRoomsScreen extends ConsumerWidget {
  const ArchivedRoomsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archivedAsync = ref.watch(archivedRoomsProvider);
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
          appBar: const GlassAppBar(
            centerTitle: false,
            title: Text(
              'Архив',
              style: TextStyle(
                color: AppColors.onGlass,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          body: SafeArea(
            child: archivedAsync.when(
              loading: () =>
                  const Center(child: GlassProgressIndicator.circular(size: 28)),
              error: (e, _) => Center(
                child: Text('$e', style: const TextStyle(color: AppColors.danger)),
              ),
              data: (rooms) {
                if (rooms.isEmpty) {
                  return const Center(
                    child: Text('Архив пуст.',
                        style: TextStyle(color: AppColors.onGlassMuted)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: rooms.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _RoomTile(room: rooms[i]),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class RoomTileContent extends StatelessWidget {
  final CachedRoom room;
  const RoomTileContent({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    final isDm = room.isDm;
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: isDm
              ? AppColors.blobViolet.withOpacity(0.55)
              : room.isPublic
                  ? AppColors.blobIndigo.withOpacity(0.55)
                  : AppColors.blobViolet.withOpacity(0.55),
          child: Icon(
            isDm
                ? Icons.person
                : room.isPublic
                    ? Icons.public
                    : Icons.lock_outline,
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
                  if (room.pinned)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.push_pin,
                          size: 13, color: AppColors.onGlassDim),
                    ),
                  Expanded(
                    child: Text(
                      roomDisplayName(room),
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
                          size: 13, color: AppColors.onGlassDim),
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
