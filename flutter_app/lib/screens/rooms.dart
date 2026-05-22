import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';
import 'chat.dart';
import 'invites.dart';
import 'profile.dart';

class RoomsScreen extends ConsumerStatefulWidget {
  const RoomsScreen({super.key});
  @override
  ConsumerState<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends ConsumerState<RoomsScreen> {
  List<dynamic> _rooms = [];
  int _invitesCount = 0;
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    setState(() { _loading = true; _err = null; });
    try {
      final api = Api(token: auth.token);
      final list = await api.rooms();
      // Параллельно подгрузим число пришедших приглашений — для бейджа.
      api.invites().then((inv) {
        if (!mounted) return;
        setState(() => _invitesCount = inv.length);
      }).catchError((_) {});
      setState(() { _rooms = list; _loading = false; });
    } on ApiException catch (e) {
      if (e.status == 401) return;
      setState(() { _err = e.message; _loading = false; });
    } catch (_) {
      setState(() { _err = 'Не удалось подключиться'; _loading = false; });
    }
  }

  Future<void> _newRoom() async {
    final ctrl = TextEditingController();
    bool isPublic = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Новая комната'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Название')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Публичная'),
                subtitle: const Text('Видна всем; в приватную пускают по приглашению'),
                value: isPublic,
                onChanged: (v) => setLocal(() => isPublic = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await Api(token: ref.read(authProvider)!.token)
            .createRoom(ctrl.text.trim(), isPublic: isPublic);
        _load();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('Комнаты · ${auth?.username ?? ""}'),
        actions: [
          IconButton(
            tooltip: 'Приглашения',
            icon: _invitesCount > 0
                ? Badge(label: Text('$_invitesCount'), child: const Icon(Icons.mail_outline))
                : const Icon(Icons.mail_outline),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const InvitesScreen()),
              );
              _load();
            },
          ),
          IconButton(
            tooltip: 'Профиль',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newRoom,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? ListView(children: [
                    const SizedBox(height: 60),
                    Center(child: Text(_err!, style: const TextStyle(color: Colors.red))),
                    TextButton(onPressed: _load, child: const Text('Повторить')),
                  ])
                : _rooms.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 80),
                        Center(child: Text('Пока ни одной комнаты.\nНажми + чтобы создать.', textAlign: TextAlign.center)),
                      ])
                    : ListView.separated(
                        itemCount: _rooms.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = _rooms[i] as Map<String, dynamic>;
                          final isPublic = (r['is_public'] as num?)?.toInt() == 1
                              || r['is_public'] == true;
                          final unread = (r['unread'] as num?)?.toInt() ?? 0;
                          final muted = (r['muted'] as num?)?.toInt() == 1
                              || r['muted'] == true;
                          return ListTile(
                            leading: Icon(isPublic ? Icons.public : Icons.lock_outline),
                            title: Row(
                              children: [
                                Expanded(child: Text(r['name']?.toString() ?? '')),
                                if (muted)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4),
                                    child: Icon(Icons.notifications_off, size: 16, color: Colors.black45),
                                  ),
                              ],
                            ),
                            trailing: unread > 0
                                ? Badge(
                                    backgroundColor: muted ? Colors.grey : Colors.indigo,
                                    label: Text('$unread'),
                                  )
                                : null,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    roomId: r['id'].toString(),
                                    roomName: r['name'].toString(),
                                    isPublic: isPublic,
                                    muted: muted,
                                  ),
                                ),
                              );
                              _load();
                            },
                          );
                        },
                      ),
      ),
    );
  }
}
