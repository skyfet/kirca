import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

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
    final api = _api;
    if (api == null) return;
    try {
      await api.acceptFriendRequest(r.id);
      await FriendRequestsCache.remove(r.id);
      await FriendsCache.upsert(
        userId: r.fromUserId,
        username: r.fromUsername,
        displayName: r.fromDisplayName,
        avatarUrl: r.fromAvatarUrl,
      );
    } catch (e) {
      _toast('$e');
    }
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

    final requestsCount = requestsAsync.valueOrNull?.length ?? 0;
    final invitesCount = invitesAsync.valueOrNull?.length ?? 0;

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
            leading: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: GlassIconButton(
                size: 36,
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: AppColors.onGlass, size: 18),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            title: const Text(
              'Друзья',
              style: TextStyle(
                color: AppColors.onGlass,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: const [SizedBox(width: 8)],
          ),
          floatingActionButton: GlassButton(
            icon: const Icon(Icons.person_add_alt_1, color: AppColors.onGlass),
            onTap: _addFriend,
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
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
                      _friendsList(friendsAsync),
                      _requestsList(requestsAsync),
                      _invitesList(invitesAsync),
                    ],
                  ),
                ),
              ],
            ),
          ),
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

  Widget _friendsList(AsyncValue<List<CachedFriend>> async) =>
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
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _FriendCard(
                friend: list[i],
                onRemove: () => _removeFriend(list[i]),
              ),
            ),
          );
        },
      );

  Widget _requestsList(AsyncValue<List<CachedFriendRequest>> async) =>
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
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RequestCard(
                request: list[i],
                onAccept: () => _acceptRequest(list[i]),
                onDecline: () => _declineRequest(list[i]),
              ),
            ),
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
  final VoidCallback onRemove;
  const _FriendCard({required this.friend, required this.onRemove});

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
                Text('@$un',
                    style: const TextStyle(
                        color: AppColors.onGlassDim, fontSize: 12)),
              ],
            ),
          ),
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
  const _RequestCard({
    required this.request,
    required this.onAccept,
    required this.onDecline,
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
