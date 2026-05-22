import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../state.dart';

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
      final p = await Api(token: auth.token)
          .updateProfile(displayName: _displayCtrl.text.trim().isEmpty ? null : _displayCtrl.text.trim());
      setState(() => _profile = p);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено')));
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Неподдерживаемый формат')));
      return;
    }
    try {
      final r = await Api(token: auth.token).uploadAvatar(bytes, mime);
      setState(() {
        if (_profile != null) _profile = {..._profile!, 'avatar_url': r['avatar_url']};
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
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Да'),
          ),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final avatar = _profile?['avatar_url'] as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: _profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: GestureDetector(
                    onTap: _pickAvatar,
                    child: CircleAvatar(
                      radius: 48,
                      backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                      child: avatar == null
                          ? Text(
                              (auth?.username ?? '?').characters.first.toUpperCase(),
                              style: const TextStyle(fontSize: 28),
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(child: TextButton.icon(onPressed: _pickAvatar, icon: const Icon(Icons.image), label: const Text('Сменить аватар'))),
                const SizedBox(height: 24),
                Text('@${auth?.username ?? ""}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _displayCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Имя для отображения',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _saving ? null : _saveDisplayName,
                  child: Text(_saving ? '...' : 'Сохранить'),
                ),
                const Divider(height: 40),
                OutlinedButton.icon(
                  onPressed: _logoutAll,
                  icon: const Icon(Icons.logout),
                  label: const Text('Выйти со всех устройств'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_forever, color: Colors.red),
                  label: const Text('Удалить аккаунт', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
    );
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
}
