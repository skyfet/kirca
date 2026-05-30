import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../theme/app_theme.dart';
import '../theme/design.dart';
import '../widgets/app_button.dart';
import '../widgets/app_scaffold.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Map<String, dynamic>? _profile;
  final _displayCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _displayCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    try {
      final p = await Api(token: auth.token).me();
      if (!mounted) return;
      _displayCtrl.text = (p['display_name'] as String?) ?? '';
      setState(() => _profile = p);
    } catch (_) {}
  }

  Future<void> _saveDisplayName() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    setState(() => _saving = true);
    try {
      final p = await Api(token: auth.token).updateProfile(
        displayName: _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() => _profile = p);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сохранено')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
    if (picked == null) return;
    final bytes = await File(picked.path).readAsBytes();
    final mime = _mimeFromPath(picked.path);
    if (mime == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неподдерживаемый формат')),
      );
      return;
    }
    try {
      final r = await Api(token: auth.token).uploadAvatar(bytes, mime);
      if (!mounted) return;
      setState(() {
        if (_profile != null) {
          _profile = {..._profile!, 'avatar_url': r['avatar_url']};
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _logoutAll() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ok = await _confirm('Выйти со всех устройств?');
    if (!ok) return;
    try {
      await Api(token: auth.token).logoutAll();
    } catch (_) {}
    await ref.read(authProvider.notifier).forceLogout();
  }

  Future<void> _delete() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ok = await _confirm('Удалить аккаунт навсегда?');
    if (!ok) return;
    try {
      await Api(token: auth.token).deleteAccount();
    } catch (_) {}
    await ref.read(authProvider.notifier).forceLogout();
  }

  Future<bool> _confirm(String text) async {
    final r = await GlassDialog.show<bool>(
      context: context,
      title: text,
      actions: [
        GlassDialogAction(label: 'Отмена', onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(label: 'Да', isDestructive: true, onPressed: () => Navigator.pop(context, true)),
      ],
    );
    return r == true;
  }

  String? _mimeFromPath(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.heic')) return 'image/heic';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final avatar = _profile?['avatar_url'] as String?;
    return AppScaffold(
      glass: false,
      extendBody: false,
      appBar: const GlassAppBar(
        centerTitle: false,
        title: Text('Профиль', style: AppType.title),
      ),
      body: SafeArea(
          child: _profile == null
              ? const Center(child: GlassProgressIndicator.circular(size: 28))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.xxl),
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: _pickAvatar,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [AppColors.blobIndigo, AppColors.blobViolet],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: CircleAvatar(
                            radius: 50,
                            backgroundColor: AppColors.surface,
                            backgroundImage:
                                avatar != null ? NetworkImage(avatar) : null,
                            child: avatar == null
                                ? Text(
                                    (auth?.username ?? '?')
                                        .characters
                                        .first
                                        .toUpperCase(),
                                    style: const TextStyle(
                                      fontSize: 30,
                                      color: AppColors.onGlass,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton.icon(
                        onPressed: _pickAvatar,
                        icon: const Icon(Icons.image_outlined, color: AppColors.onGlassMuted, size: 16),
                        label: const Text('Сменить аватар',
                            style: TextStyle(color: AppColors.onGlassMuted, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        '@${auth?.username ?? ""}',
                        style: const TextStyle(color: AppColors.onGlassMuted),
                      ),
                    ),
                    const SizedBox(height: 24),
                    GlassPanel(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Имя для отображения',
                            style: TextStyle(color: AppColors.onGlassMuted, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          GlassTextField(
                            controller: _displayCtrl,
                            placeholder: 'Как тебя называть',
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                          ),
                          const SizedBox(height: AppSpace.md),
                          AppButton.primary(
                            label: 'Сохранить',
                            busy: _saving,
                            height: AppSize.compactButtonHeight,
                            onTap: _saveDisplayName,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    _BlockedUsersRow(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BlockedUsersScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.xxl),
                    AppButton.secondary(
                      label: 'Выйти',
                      icon: Icons.logout,
                      height: AppSize.compactButtonHeight,
                      onTap: () => ref.read(authProvider.notifier).logout(),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    AppButton.secondary(
                      label: 'Выйти со всех устройств',
                      height: AppSize.compactButtonHeight,
                      onTap: _logoutAll,
                    ),
                    const SizedBox(height: AppSpace.lg),
                    AppButton.danger(
                      label: 'Удалить аккаунт',
                      height: AppSize.compactButtonHeight,
                      onTap: _delete,
                    ),
                  ],
                ),
        ),
    );
  }
}

/// Profile row that opens the blocked-users management subpage. Shows the
/// current count as a trailing badge, driven by [blockedUsersProvider].
class _BlockedUsersRow extends ConsumerWidget {
  const _BlockedUsersRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(blockedUsersProvider).maybeWhen(
          data: (list) => list.length,
          orElse: () => 0,
        );
    return GlassButton.custom(
      onTap: onTap,
      width: double.infinity,
      height: 56,
      useOwnLayer: true,
      shape: LiquidRoundedSuperellipse(borderRadius: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.block, color: AppColors.onGlassMuted, size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Заблокированные',
                style: TextStyle(
                  color: AppColors.onGlass,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (count > 0)
              Text(
                '$count',
                style: const TextStyle(color: AppColors.onGlassMuted),
              ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: AppColors.onGlassMuted, size: 20),
          ],
        ),
      ),
    );
  }
}

/// F8: blocked-users management. Lists every blocked user (avatar / display
/// name / username) and lets the user unblock them. Mirrors the unblock into
/// [BlocksCache] so the [blockedUsersProvider] stream refreshes the UI.
class BlockedUsersScreen extends ConsumerStatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  ConsumerState<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends ConsumerState<BlockedUsersScreen> {
  final _pending = <String>{};

  Future<void> _unblock(CachedBlockedUser u) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    setState(() => _pending.add(u.userId));
    try {
      await Api(token: auth.token).removeBlock(u.userId);
      await BlocksCache.remove(u.userId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _pending.remove(u.userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = ref.watch(blockedUsersProvider);
    return AppScaffold(
      appBar: const GlassAppBar(
        centerTitle: false,
        title: Text('Заблокированные', style: AppType.title),
      ),
      body: SafeArea(
        child: blocked.when(
          loading: () => const Center(child: GlassProgressIndicator.circular(size: 28)),
          error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: AppColors.onGlassMuted)),
          ),
          data: (users) {
            if (users.isEmpty) {
              return const _BlockedEmptyState();
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.xxl),
              itemCount: users.length,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpace.sm),
              itemBuilder: (_, i) => _BlockedUserTile(
                user: users[i],
                busy: _pending.contains(users[i].userId),
                onUnblock: () => _unblock(users[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BlockedUserTile extends StatelessWidget {
  const _BlockedUserTile({
    required this.user,
    required this.busy,
    required this.onUnblock,
  });

  final CachedBlockedUser user;
  final bool busy;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final avatar = user.avatarUrl;
    final title = (user.displayName?.isNotEmpty ?? false)
        ? user.displayName!
        : (user.username ?? user.userId);
    final subtitle = (user.username?.isNotEmpty ?? false) ? '@${user.username}' : null;
    return GlassPanel(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.surface,
            backgroundImage: avatar != null ? NetworkImage(avatar) : null,
            child: avatar == null
                ? Text(
                    title.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.onGlass,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.onGlass,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.onGlassMuted, fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GlassButton.custom(
            onTap: busy ? () {} : onUnblock,
            height: 36,
            width: 110,
            glowColor: AppColors.accent,
            useOwnLayer: true,
            shape: LiquidRoundedSuperellipse(borderRadius: 10),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onGlass,
                      ),
                    )
                  : const Text(
                      'Разблокировать',
                      style: TextStyle(
                        color: AppColors.onGlass,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockedEmptyState extends StatelessWidget {
  const _BlockedEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: AppColors.onGlassMuted, size: 48),
            SizedBox(height: 16),
            Text(
              'Нет заблокированных',
              style: TextStyle(
                color: AppColors.onGlass,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Заблокированные пользователи появятся здесь',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.onGlassMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
