import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';
import 'chat.dart';

class RoomsScreen extends ConsumerStatefulWidget {
  const RoomsScreen({super.key});
  @override
  ConsumerState<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends ConsumerState<RoomsScreen> {
  List<dynamic> _rooms = [];
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
      final list = await Api(token: auth.token).rooms();
      setState(() { _rooms = list; _loading = false; });
    } on ApiException catch (e) {
      // 401 уже обработан глобальным хуком в Api — нас выкинет на логин.
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
                subtitle: const Text('Видна всем; в приватную пускают только участников'),
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
                          return ListTile(
                            leading: Icon(isPublic ? Icons.public : Icons.lock_outline),
                            title: Text(r['name']?.toString() ?? ''),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  roomId: r['id'].toString(),
                                  roomName: r['name'].toString(),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
