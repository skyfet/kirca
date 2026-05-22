import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';

class InvitesScreen extends ConsumerStatefulWidget {
  const InvitesScreen({super.key});

  @override
  ConsumerState<InvitesScreen> createState() => _InvitesScreenState();
}

class _InvitesScreenState extends ConsumerState<InvitesScreen> {
  List<dynamic> _invites = [];
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
      final list = await Api(token: auth.token).invites();
      if (!mounted) return;
      setState(() {
        _invites = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept(String id) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    try {
      await Api(token: auth.token).acceptInvite(id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Вступили в комнату')));
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
      await _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Приглашения')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _invites.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 80),
                    Center(child: Text('Нет входящих приглашений')),
                  ])
                : ListView.separated(
                    itemCount: _invites.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final inv = _invites[i] as Map<String, dynamic>;
                      final inviter = (inv['inviter_display_name'] as String?)?.trim().isNotEmpty == true
                          ? inv['inviter_display_name'] as String
                          : inv['inviter_username'] as String? ?? '?';
                      return ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text(inv['room_name']?.toString() ?? ''),
                        subtitle: Text('Приглашает @$inviter'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Принять',
                              icon: const Icon(Icons.check, color: Colors.green),
                              onPressed: () => _accept(inv['id'].toString()),
                            ),
                            IconButton(
                              tooltip: 'Отклонить',
                              icon: const Icon(Icons.close, color: Colors.red),
                              onPressed: () => _decline(inv['id'].toString()),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
