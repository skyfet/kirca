import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api.dart';
import '../config.dart';
import '../state.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  const ChatScreen({super.key, required this.roomId, required this.roomName});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = ref.read(authProvider)!;
    // 1) История из D1
    try {
      final h = await Api(token: auth.token).history(widget.roomId);
      if (!mounted) return;
      setState(() => _messages.addAll(h.cast<Map<String, dynamic>>()));
      _scrollToEnd();
    } catch (_) {}
    // 2) WS
    _connect(auth.token);
  }

  void _connect(String token) {
    final uri = Uri.parse('${Config.wsBase}/rooms/${widget.roomId}/ws?token=$token');
    _ws = WebSocketChannel.connect(uri);
    setState(() => _connected = true);
    _sub = _ws!.stream.listen(
      (raw) {
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'msg') {
            setState(() => _messages.add(m));
            _scrollToEnd();
          }
        } catch (_) {}
      },
      onDone: () { if (mounted) setState(() => _connected = false); },
      onError: (_) { if (mounted) setState(() => _connected = false); },
    );
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _ws == null || !_connected) return;
    _ws!.sink.add(jsonEncode({'type': 'msg', 'text': t}));
    _ctrl.clear();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ws?.sink.close(ws_status.normalClosure);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider)?.userId;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.roomName),
        bottom: _connected
            ? null
            : const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                final mine = m['user_id'] == me;
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: mine ? Colors.indigo.shade400 : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!mine)
                          Text(
                            m['username']?.toString() ?? '',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        Text(
                          m['text']?.toString() ?? '',
                          style: TextStyle(color: mine ? Colors.white : Colors.black87),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        hintText: 'Сообщение...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _connected ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
