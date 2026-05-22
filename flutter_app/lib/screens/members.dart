import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';

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
  List<dynamic> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    setState(() => _loading = true);
    try {
      final list = await Api(token: auth.token).members(widget.roomId);
      if (!mounted) return;
      setState(() {
        _members = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _inviteByUsername() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Пригласить по username'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(prefixText: '@', hintText: 'username'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Пригласить')),
        ],
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Приглашение отправлено')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Участники · ${widget.roomName}'),
        actions: [
          if (!widget.isPublic)
            IconButton(
              tooltip: 'Пригласить',
              icon: const Icon(Icons.person_add),
              onPressed: _inviteByUsername,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                itemCount: _members.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final m = _members[i] as Map<String, dynamic>;
                  final dn = (m['display_name'] as String?)?.trim();
                  final un = m['username']?.toString() ?? '?';
                  final online = m['online'] == true;
                  final avatar = m['avatar_url'] as String?;
                  return ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                          child: avatar == null ? Text(un.characters.first.toUpperCase()) : null,
                        ),
                        if (online)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                    title: Text(dn?.isNotEmpty == true ? dn! : un),
                    subtitle: Text('@$un · ${m['role'] ?? ''}'),
                  );
                },
              ),
      ),
    );
  }
}
