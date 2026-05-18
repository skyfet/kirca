import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api.dart';
import '../state.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  bool _isRegister = false;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _u.dispose();
    _p.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_u.text.trim().isEmpty || _p.text.isEmpty) {
      setState(() => _err = 'Заполни оба поля');
      return;
    }
    setState(() { _busy = true; _err = null; });
    try {
      final api = Api();
      final res = _isRegister
          ? await api.register(_u.text.trim(), _p.text)
          : await api.login(_u.text.trim(), _p.text);
      await ref.read(authProvider.notifier).set(
            Auth(
              res['token'] as String,
              (res['user'] as Map)['id'] as String,
              (res['user'] as Map)['username'] as String,
            ),
          );
    } on ApiException catch (e) {
      setState(() => _err = e.message);
    } catch (e) {
      setState(() => _err = 'Не удалось подключиться к серверу');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isRegister ? 'Регистрация' : 'Вход')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _u,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Имя пользователя'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _p,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Пароль'),
              ),
              const SizedBox(height: 16),
              if (_err != null)
                Text(_err!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isRegister ? 'Создать аккаунт' : 'Войти'),
              ),
              TextButton(
                onPressed: () => setState(() => _isRegister = !_isRegister),
                child: Text(_isRegister
                    ? 'У меня уже есть аккаунт'
                    : 'Создать новый аккаунт'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
