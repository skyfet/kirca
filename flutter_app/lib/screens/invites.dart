import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

class InvitesScreen extends ConsumerStatefulWidget {
  const InvitesScreen({super.key});

  @override
  ConsumerState<InvitesScreen> createState() => _InvitesScreenState();
}

class _InvitesScreenState extends ConsumerState<InvitesScreen> {
  Future<void> _accept(String id) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    try {
      await Api(token: auth.token).acceptInvite(id);
      await InvitesCache.remove(id);
      // Триггернуть рефреш списка комнат — там появится новая.
      try {
        final list = await Api(token: auth.token).rooms();
        await RoomsCache.replaceAll(list.cast<Map<String, dynamic>>());
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вступили в комнату')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _decline(String id) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    try {
      await Api(token: auth.token).declineInvite(id);
      await InvitesCache.remove(id);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(invitesProvider);
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
          title: const Text(
            'Приглашения',
            style: TextStyle(color: AppColors.onGlass, fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        body: SafeArea(
          child: async.when(
            loading: () => const Center(child: GlassProgressIndicator.circular(size: 28)),
            error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: AppColors.danger))),
            data: (items) {
              if (items.isEmpty) {
                return const Center(
                  child: Text('Нет входящих приглашений',
                      style: TextStyle(color: AppColors.onGlassMuted)),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                itemCount: items.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _InviteCard(
                    invite: items[i],
                    onAccept: () => _accept(items[i].id),
                    onDecline: () => _decline(items[i].id),
                  ),
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

class _InviteCard extends StatelessWidget {
  final CachedInvite invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _InviteCard({required this.invite, required this.onAccept, required this.onDecline});

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
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text('Приглашает @$inviter',
                    style: const TextStyle(color: AppColors.onGlassDim, fontSize: 12)),
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
