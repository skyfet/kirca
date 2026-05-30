import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../services/room_invite.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_theme.dart';
import '../theme/design.dart';
import '../widgets/app_scaffold.dart';
import 'chat.dart';

/// Combined "Друзья" screen — three tabs in one place:
///
/// - **Друзья** — confirmed friendships. Tile shows username and "remove".
/// - **Запросы** — incoming friend requests (accept / decline).
/// - **Приглашения** — incoming room invites (the old InvitesScreen).
///
/// Floating "+" sends a friend request by username. Replaces the standalone
/// InvitesScreen so users don't have to context-switch between contact lists
/// and outstanding invitations.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Api? get _api {
    final t = ref.read(authProvider)?.token;
    return t == null ? null : Api(token: t);
  }

  Future<void> _addFriend() async {
    final username = await _promptUsername();
    if (username == null) return;
    final api = _api;
    if (api == null) return;
    try {
      final res = await api.sendFriendRequest(username: username);
      if (res['friendship'] == true) {
        await FriendsCache.upsert(
          userId: res['user_id']?.toString() ?? '',
          username: res['username']?.toString() ?? username,
        );
        _toast('Теперь вы друзья');
      } else {
        _toast('Запрос отправлен');
      }
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _acceptRequest(CachedFriendRequest r) async {
    final auth = ref.read(authProvider);
    final api = _api;
    if (api == null || auth == null) return;
    try {
      await api.acceptFriendRequest(r.id);
      await FriendRequestsCache.remove(r.id);
      await FriendsCache.upsert(
        userId: r.fromUserId,
        username: r.fromUsername,
        displayName: r.fromDisplayName,
        avatarUrl: r.fromAvatarUrl,
      );
      // F20: the server has auto-created the E2E DM room for this friendship
      // but hasn't sealed any room keys. We accepted, so we're the one holding
      // the key — seal it for both members. The friendship already stands;
      // sealing failures are surfaced softly.
      await _pairDmKeys(api, auth.userId, r.fromUserId);
    } catch (e) {
      _toast('$e');
    }
  }

  /// F20: find the freshly-provisioned DM room for [friendId] and seal its key
  /// for both members. Refreshes the rooms cache first so the just-created DM
  /// room is visible even if the `room_added` WS event hasn't landed yet.
  Future<void> _pairDmKeys(Api api, String myUserId, String friendId) async {
    try {
      // Refresh rooms so the new DM room is present (accept() awaits server-side
      // provisioning, so a single GET /rooms reliably includes it).
      try {
        final list = await api.rooms();
        await RoomsCache.replaceAll(
          list.cast<Map<String, dynamic>>(),
          currentUserId: myUserId,
        );
      } catch (_) {
        // offline — fall through to whatever's already cached.
      }

      final dm = await _findDmRoom(friendId);
      if (dm == null) {
        // No DM room yet (e.g. server lag / older friendship). Non-destructive:
        // the peer or a later refresh can seal; just note it.
        _toast('Личный чат появится чуть позже');
        return;
      }

      final result = await RoomInviteService(api).sealDmKeyForFriendship(
        dmRoomId: dm.id,
        keyVersion: dm.keyVersion == 0 ? 1 : dm.keyVersion,
        myUserId: myUserId,
        friendUserId: friendId,
      );
      switch (result) {
        case DmKeyPairingResult.noLocalIdentity:
          _toast('Настрой ключи шифрования в профиле, чтобы писать сообщения');
          break;
        case DmKeyPairingResult.sealedForSelfOnly:
        case DmKeyPairingResult.sealedForBoth:
          break;
      }
    } catch (e) {
      // Friendship still succeeded; sealing is best-effort.
      _toast('Не удалось подготовить ключи чата: $e');
    }
  }

  /// Locate the E2E DM [CachedRoom] whose peer is [friendId].
  Future<CachedRoom?> _findDmRoom(String friendId) async {
    final rooms = await RoomsCache.snapshot();
    for (final room in rooms) {
      if (room.isDm && room.dmPeerId == friendId) return room;
    }
    return null;
  }

  /// F20: open the friend's DM room in [ChatScreen]. If no DM room exists yet
  /// (a friendship predating this feature, or pre-WS-fanout), refresh once and
  /// retry; if still absent show a soft note and do nothing destructive.
  Future<void> _messageFriend(CachedFriend f) async {
    final auth = ref.read(authProvider);
    final api = _api;
    if (api == null || auth == null) return;

    var dm = await _findDmRoom(f.userId);
    if (dm == null) {
      // Try a refresh — the DM room may simply not be cached yet.
      try {
        final list = await api.rooms();
        await RoomsCache.replaceAll(
          list.cast<Map<String, dynamic>>(),
          currentUserId: auth.userId,
        );
        dm = await _findDmRoom(f.userId);
      } catch (_) {}
    }
    if (dm == null) {
      _toast('Личный чат с @${f.username} появится чуть позже');
      return;
    }
    if (!mounted) return;
    final dn = (f.displayName ?? '').trim();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          roomId: dm!.id,
          roomName: dn.isNotEmpty ? dn : '@${f.username}',
          isPublic: dm.isPublic,
          muted: dm.muted,
          e2e: dm.e2e,
          keyVersion: dm.keyVersion,
        ),
      ),
    );
  }

  Future<void> _declineRequest(CachedFriendRequest r) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.declineFriendRequest(r.id);
      await FriendRequestsCache.remove(r.id);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _removeFriend(CachedFriend f) async {
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Удалить из друзей?',
      content: Text('@${f.username}',
          style: const TextStyle(color: AppColors.onGlassMuted)),
      actions: [
        GlassDialogAction(
            label: 'Отмена', onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(
            label: 'Удалить',
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return;
    final api = _api;
    if (api == null) return;
    await FriendsCache.remove(f.userId);
    try {
      await api.removeFriend(f.userId);
    } catch (e) {
      _toast('$e');
    }
  }

  /// F8: block [userId]. Server-side this also stops them from sending the
  /// current user friend requests. Mirrors into [BlocksCache] for instant UI.
  Future<void> _block(String userId, {String? username}) async {
    final api = _api;
    if (api == null) return;
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Заблокировать?',
      content: Text(
        username != null
            ? '@$username больше не сможет писать вам или отправлять запросы.'
            : 'Пользователь больше не сможет писать вам или отправлять запросы.',
        style: const TextStyle(color: AppColors.onGlassMuted),
      ),
      actions: [
        GlassDialogAction(
            label: 'Отмена', onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(
            label: 'Заблокировать',
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return;
    await BlocksCache.add(userId, username: username);
    try {
      await api.addBlock(userId: userId, username: username);
      _toast(username != null ? '@$username заблокирован' : 'Заблокировано');
    } catch (e) {
      // Roll back the optimistic local change on failure.
      await BlocksCache.remove(userId);
      _toast('$e');
    }
  }

  /// F8: unblock [userId].
  Future<void> _unblock(String userId, {String? username}) async {
    final api = _api;
    if (api == null) return;
    await BlocksCache.remove(userId);
    try {
      await api.removeBlock(userId);
      _toast(username != null ? '@$username разблокирован' : 'Разблокировано');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _acceptInvite(CachedInvite inv) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.acceptInvite(inv.id);
      await InvitesCache.remove(inv.id);
      try {
        final list = await api.rooms();
        await RoomsCache.replaceAll(list.cast<Map<String, dynamic>>());
      } catch (_) {}
      _toast('Вступили в комнату');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _declineInvite(CachedInvite inv) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.declineInvite(inv.id);
      await InvitesCache.remove(inv.id);
    } catch (_) {}
  }

  Future<String?> _promptUsername() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Добавить в друзья',
                  style: TextStyle(
                    color: AppColors.onGlass,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                GlassTextField(
                  controller: ctrl,
                  placeholder: 'username',
                  prefixIcon: const Icon(Icons.alternate_email, size: 18),
                  autofocus: true,
                  height: 36,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
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
                          child: Text('Отмена',
                              style: TextStyle(color: AppColors.onGlass)),
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
                          child: Text('Отправить',
                              style: TextStyle(
                                  color: AppColors.onGlass,
                                  fontWeight: FontWeight.w600)),
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
    );
    if (ok != true) return null;
    final name = ctrl.text.trim().replaceAll(RegExp(r'^@+'), '');
    return name.isEmpty ? null : name;
  }

  @override
  Widget build(BuildContext context) {
    final friendsAsync = ref.watch(friendsProvider);
    final requestsAsync = ref.watch(friendRequestsProvider);
    final invitesAsync = ref.watch(invitesProvider);
    final blockedIds = ref
            .watch(blockedUsersProvider)
            .valueOrNull
            ?.map((b) => b.userId)
            .toSet() ??
        const <String>{};

    final requestsCount = requestsAsync.valueOrNull?.length ?? 0;
    final invitesCount = invitesAsync.valueOrNull?.length ?? 0;

    return AppScaffold(
      glass: false,
      appBar: const GlassAppBar(
        centerTitle: false,
        title: Text('Друзья', style: AppType.title),
      ),
      floatingActionButton: GlassButton(
        icon: const Icon(Icons.person_add_alt_1, color: AppColors.onGlass),
        onTap: _addFriend,
        width: AppSize.fab,
        height: AppSize.fab,
        glowColor: AppColors.accent,
        useOwnLayer: true,
        shape: AppRadius.glassLg,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.md, AppSpace.xs, AppSpace.md, AppSpace.xs),
              child: TabBar(
                controller: _tabs,
                labelColor: AppColors.onGlass,
                unselectedLabelColor: AppColors.onGlassMuted,
                indicatorColor: AppColors.accent,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: [
                  const Tab(text: 'Друзья'),
                  _tabWithBadge('Запросы', requestsCount),
                  _tabWithBadge('Приглашения', invitesCount),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _friendsList(friendsAsync, blockedIds),
                  _requestsList(requestsAsync, blockedIds),
                  _invitesList(invitesAsync),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabWithBadge(String label, int count) {
    if (count == 0) return Tab(text: label);
    return Tab(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$count',
                style: const TextStyle(
                    color: AppColors.onGlass,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _friendsList(
    AsyncValue<List<CachedFriend>> async,
    Set<String> blockedIds,
  ) =>
      async.when(
        loading: () =>
            const Center(child: GlassProgressIndicator.circular(size: 28)),
        error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: AppColors.danger))),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyHint('Пока никого. Нажми + чтобы добавить друга.');
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final f = list[i];
              final blocked = blockedIds.contains(f.userId);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _FriendCard(
                  friend: f,
                  blocked: blocked,
                  onRemove: () => _removeFriend(f),
                  onMessage: () => _messageFriend(f),
                  onBlockToggle: () => blocked
                      ? _unblock(f.userId, username: f.username)
                      : _block(f.userId, username: f.username),
                ),
              );
            },
          );
        },
      );

  Widget _requestsList(
    AsyncValue<List<CachedFriendRequest>> async,
    Set<String> blockedIds,
  ) =>
      async.when(
        loading: () =>
            const Center(child: GlassProgressIndicator.circular(size: 28)),
        error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: AppColors.danger))),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyHint('Нет входящих запросов.');
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final r = list[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RequestCard(
                  request: r,
                  onAccept: () => _acceptRequest(r),
                  onDecline: () => _declineRequest(r),
                  onBlock: () =>
                      _block(r.fromUserId, username: r.fromUsername),
                ),
              );
            },
          );
        },
      );

  Widget _invitesList(AsyncValue<List<CachedInvite>> async) => async.when(
        loading: () =>
            const Center(child: GlassProgressIndicator.circular(size: 28)),
        error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: AppColors.danger))),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyHint('Нет приглашений в комнаты.');
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: list.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _InviteCard(
                invite: list[i],
                onAccept: () => _acceptInvite(list[i]),
                onDecline: () => _declineInvite(list[i]),
              ),
            ),
          );
        },
      );
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.onGlassMuted),
          ),
        ),
      );
}

class _FriendCard extends StatelessWidget {
  final CachedFriend friend;
  final bool blocked;
  final VoidCallback onRemove;
  final VoidCallback onMessage;
  final VoidCallback onBlockToggle;
  const _FriendCard({
    required this.friend,
    required this.blocked,
    required this.onRemove,
    required this.onMessage,
    required this.onBlockToggle,
  });

  @override
  Widget build(BuildContext context) {
    final dn = (friend.displayName ?? '').trim();
    final un = friend.username;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.blobIndigo.withOpacity(0.5),
            backgroundImage: friend.avatarUrl != null
                ? NetworkImage(friend.avatarUrl!)
                : null,
            child: friend.avatarUrl == null
                ? Text(
                    un.isNotEmpty ? un.characters.first.toUpperCase() : '?',
                    style: const TextStyle(
                        color: AppColors.onGlass,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dn.isNotEmpty ? dn : un,
                  style: const TextStyle(
                      color: AppColors.onGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                    blocked ? '@$un · заблокирован' : '@$un',
                    style: TextStyle(
                        color: blocked
                            ? AppColors.danger
                            : AppColors.onGlassDim,
                        fontSize: 12)),
              ],
            ),
          ),
          // F20: open the E2E DM with this friend.
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.chat_bubble_outline,
                color: AppColors.onGlass, size: 18),
            onPressed: onMessage,
          ),
          const SizedBox(width: 4),
          // F8: block / unblock.
          GlassIconButton(
            size: 34,
            icon: Icon(blocked ? Icons.lock_open : Icons.block,
                color: blocked ? const Color(0xFF34D399) : AppColors.danger,
                size: 18),
            onPressed: onBlockToggle,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.person_remove,
                color: AppColors.danger, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final CachedFriendRequest request;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onBlock;
  const _RequestCard({
    required this.request,
    required this.onAccept,
    required this.onDecline,
    required this.onBlock,
  });

  @override
  Widget build(BuildContext context) {
    final dn = (request.fromDisplayName ?? '').trim();
    final un = request.fromUsername;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: const Color(0x55B46CFF),
            backgroundImage: request.fromAvatarUrl != null
                ? NetworkImage(request.fromAvatarUrl!)
                : null,
            child: request.fromAvatarUrl == null
                ? const Icon(Icons.person_add_alt_1,
                    color: AppColors.onGlass, size: 20)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dn.isNotEmpty ? dn : un,
                  style: const TextStyle(
                      color: AppColors.onGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text('@$un · хочет добавить вас',
                    style: const TextStyle(
                        color: AppColors.onGlassDim, fontSize: 12)),
              ],
            ),
          ),
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.check,
                color: Color(0xFF34D399), size: 18),
            onPressed: onAccept,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.close, color: AppColors.danger, size: 18),
            onPressed: onDecline,
          ),
          const SizedBox(width: 4),
          // F8: block the sender (also stops further requests server-side).
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.block, color: AppColors.danger, size: 18),
            onPressed: onBlock,
          ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final CachedInvite invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _InviteCard({
    required this.invite,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final inviter = (invite.inviterDisplayName?.trim().isNotEmpty == true)
        ? invite.inviterDisplayName!
        : (invite.inviterUsername ?? '?');
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 20,
            backgroundColor: Color(0x55B46CFF),
            child: Icon(Icons.mail_outline, color: AppColors.onGlass, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invite.roomName,
                  style: const TextStyle(
                    color: AppColors.onGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text('приглашает @$inviter',
                    style: const TextStyle(
                        color: AppColors.onGlassDim, fontSize: 12)),
              ],
            ),
          ),
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.check, color: Color(0xFF34D399), size: 18),
            onPressed: onAccept,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            size: 34,
            icon: const Icon(Icons.close, color: AppColors.danger, size: 18),
            onPressed: onDecline,
          ),
        ],
      ),
    );
  }
}
