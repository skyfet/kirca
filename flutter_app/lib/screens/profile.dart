import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../state.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

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
      setState(() => _profile = p);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сохранено')),
        );
      }
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неподдерживаемый формат')),
      );
      return;
    }
    try {
      final r = await Api(token: auth.token).uploadAvatar(bytes, mime);
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
    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: GlassAppBar(
          title: const Text(
            'Профиль',
            style: TextStyle(color: AppColors.onGlass, fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        body: SafeArea(
          child: _profile == null
              ? const Center(child: GlassProgressIndicator.circular(size: 28))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                            backgroundColor: AppColors.bgMid,
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
                        icon: const Icon(Icons.image_outlined, color: AppColors.onGlassMuted, size: 18),
                        label: const Text('Сменить аватар',
                            style: TextStyle(color: AppColors.onGlassMuted)),
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
                          ),
                          const SizedBox(height: 12),
                          GlassButton.custom(
                            onTap: _saving ? () {} : _saveDisplayName,
                            width: double.infinity,
                            height: 44,
                            glowColor: AppColors.accent,
                            child: Center(
                              child: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.onGlass,
                                      ),
                                    )
                                  : const Text(
                                      'Сохранить',
                                      style: TextStyle(
                                        color: AppColors.onGlass,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    GlassButton.custom(
                      onTap: _logoutAll,
                      width: double.infinity,
                      height: 44,
                      child: const Center(
                        child: Text(
                          'Выйти со всех устройств',
                          style: TextStyle(color: AppColors.onGlass),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassButton.custom(
                      onTap: _delete,
                      width: double.infinity,
                      height: 44,
                      glowColor: AppColors.danger,
                      child: const Center(
                        child: Text(
                          'Удалить аккаунт',
                          style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
