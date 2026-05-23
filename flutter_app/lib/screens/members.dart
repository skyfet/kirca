import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

class MembersScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final bool isPublic;
  const MembersScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.isPublic,
  });

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  Future<void> _inviteByUsername() async {
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
                  'Пригласить по username',
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                        child: const Center(child: Text('Отмена', style: TextStyle(color: AppColors.onGlass))),
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
                          child: Text('Пригласить',
                              style: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600)),
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
    if (ok != true) return;
    final name = ctrl.text.trim().replaceAll(RegExp(r'^@+'), '');
    if (name.isEmpty) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;
    try {
      await Api(token: auth.token).invite(widget.roomId, username: name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Приглашение отправлено')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
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
              icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.onGlass, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          title: Text(
            'Участники · ${widget.roomName}',
            style: const TextStyle(color: AppColors.onGlass, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (!widget.isPublic)
              GlassIconButton(
                size: 36,
                icon: const Icon(Icons.person_add_alt_1, color: AppColors.onGlass),
                onPressed: _inviteByUsername,
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: async.when(
            loading: () => const Center(child: GlassProgressIndicator.circular(size: 28)),
            error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: AppColors.danger))),
            data: (members) {
              if (members.isEmpty) {
                return const Center(
                  child: Text('Пока пусто', style: TextStyle(color: AppColors.onGlassMuted)),
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
                        style: const TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w700),
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
                      border: Border.all(color: const Color(0xFF1B1546), width: 2),
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
                  style: const TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600),
                ),
                Text(
                  '@$un${member.role.isNotEmpty ? " · ${member.role}" : ""}',
                  style: const TextStyle(color: AppColors.onGlassDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
