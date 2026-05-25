import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../crypto/room_cipher.dart';
import '../services/room_invite.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

class MembersScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final bool isPublic;
  final bool e2e;
  final int keyVersion;
  const MembersScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.isPublic,
    this.e2e = false,
    this.keyVersion = 0,
  });

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  Future<void> _openInviteSheet() async {
    final result = await showModalBottomSheet<_InvitePick>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _InvitePickerSheet(roomId: widget.roomId),
    );
    if (result == null) return;
    final username = result.username;
    if (username == null || username.isEmpty) return;
    await _inviteUsername(username);
  }

  Future<void> _inviteUsername(String username) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final api = Api(token: auth.token);
    final inviter = RoomInviteService(api);
    try {
      await inviter.inviteByUsername(
        roomId: widget.roomId,
        username: username,
        cipherForSealing: widget.e2e
            ? RoomCipher(
                api: api,
                roomId: widget.roomId,
                fallbackVersion: widget.keyVersion,
              )
            : null,
      );
      _toast('Приглашение отправлено');
    } on PeerHasNoIdentity {
      _toast('У пользователя нет ключа шифрования — '
          'попроси его настроить E2E в профиле');
    } catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(membersProvider(widget.roomId));
    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
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
            title: Text(
              'Участники · ${widget.roomName}',
              style: const TextStyle(
                  color: AppColors.onGlass,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            actions: [
              if (!widget.isPublic)
                GlassIconButton(
                  size: 36,
                  icon: const Icon(Icons.person_add,
                      color: AppColors.onGlass),
                  onPressed: _openInviteSheet,
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: async.when(
              loading: () =>
                  const Center(child: GlassProgressIndicator.circular(size: 28)),
              error: (e, _) => Center(
                  child: Text('$e',
                      style: const TextStyle(color: AppColors.danger))),
              data: (members) {
                if (members.isEmpty) {
                  return const Center(
                    child: Text('Пока пусто',
                        style: TextStyle(color: AppColors.onGlassMuted)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: members.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _MemberTile(member: members[i]),
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

class _InvitePick {
  final String? username;
  const _InvitePick(this.username);
}

/// Bottom sheet that lets the user invite a member to the room. Lists their
/// friends (one-tap invite) and falls back to manual username entry for
/// people who aren't in the friends list yet.
class _InvitePickerSheet extends ConsumerStatefulWidget {
  final String roomId;
  const _InvitePickerSheet({required this.roomId});

  @override
  ConsumerState<_InvitePickerSheet> createState() => _InvitePickerSheetState();
}

class _InvitePickerSheetState extends ConsumerState<_InvitePickerSheet> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _pickFriend(CachedFriend f) {
    Navigator.pop(context, _InvitePick(f.username));
  }

  void _submitManual() {
    final raw = _ctrl.text.trim().replaceAll(RegExp(r'^@+'), '');
    if (raw.isEmpty) return;
    Navigator.pop(context, _InvitePick(raw));
  }

  @override
  Widget build(BuildContext context) {
    final friendsAsync = ref.watch(friendsProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassPanel(
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Пригласить',
                  style: TextStyle(
                    color: AppColors.onGlass,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                GlassTextField(
                  controller: _ctrl,
                  placeholder: 'username (или выбери ниже)',
                  prefixIcon: const Icon(Icons.alternate_email, size: 18),
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onSubmitted: (_) => _submitManual(),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: GlassButton.custom(
                    onTap: _submitManual,
                    height: 32,
                    width: 120,
                    useOwnLayer: true,
                    glowColor: AppColors.accent,
                    shape: LiquidRoundedSuperellipse(borderRadius: 10),
                    child: const Center(
                      child: Text(
                        'Отправить',
                        style: TextStyle(
                            color: AppColors.onGlass,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: Color(0x33FFFFFF), height: 1),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Друзья',
                    style: TextStyle(
                        color: AppColors.onGlassMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: friendsAsync.when(
                    loading: () => const Center(
                        child: GlassProgressIndicator.circular(size: 22)),
                    error: (e, _) => Text('$e',
                        style: const TextStyle(color: AppColors.danger)),
                    data: (list) {
                      if (list.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'Список друзей пуст. Введи username вручную.',
                            style: TextStyle(
                                color: AppColors.onGlassDim, fontSize: 12),
                          ),
                        );
                      }
                      return ListView.builder(
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (_, i) => GlassListTile.standalone(
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor:
                                AppColors.blobIndigo.withOpacity(0.5),
                            child: Text(
                              list[i].username.isNotEmpty
                                  ? list[i].username.characters.first.toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  color: AppColors.onGlass,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          title: Text('@${list[i].username}',
                              style: const TextStyle(color: AppColors.onGlass)),
                          onTap: () => _pickFriend(list[i]),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final CachedMember member;
  const _MemberTile({required this.member});

  @override
  Widget build(BuildContext context) {
    final dn = (member.displayName ?? '').trim();
    final un = member.username;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.blobIndigo.withOpacity(0.5),
                backgroundImage: member.avatarUrl != null
                    ? NetworkImage(member.avatarUrl!)
                    : null,
                child: member.avatarUrl == null
                    ? Text(
                        un.isNotEmpty ? un.characters.first.toUpperCase() : '?',
                        style: const TextStyle(
                            color: AppColors.onGlass,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                      )
                    : null,
              ),
              if (member.online)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFF34D399),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFF1B1546), width: 2),
                    ),
                  ),
                ),
            ],
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
                  '@$un${member.role.isNotEmpty ? " · ${member.role}" : ""}',
                  style: const TextStyle(
                      color: AppColors.onGlassDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
