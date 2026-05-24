import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../crypto/setup.dart';
import '../state.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import 'recovery_phrase.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  int _mode = 0; // 0 = login, 1 = register
  bool _busy = false;
  String? _err;

  bool get _isRegister => _mode == 1;

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
      final token = res['token'] as String;
      final userMap = res['user'] as Map;
      final auth = Auth(
        token,
        userMap['id'] as String,
        userMap['username'] as String,
      );

      // After register: bootstrap E2E identity + show recovery phrase.
      // After login: probe whether keys need restoring on this device.
      final tokenedApi = Api(token: token);
      if (_isRegister) {
        try {
          final phrase = await IdentitySetup.initialize(tokenedApi);
          if (!mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RecoveryPhraseScreen(phrase: phrase),
            ),
          );
        } catch (e) {
          // Identity setup is best-effort during signup; failing it shouldn't
          // block the login flow. The user can re-derive later from profile.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Ключи шифрования не настроены: $e')),
            );
          }
        }
      } else {
        try {
          final status = await IdentitySetup.probeIdentity(tokenedApi);
          if (status == IdentityStatus.needsRestore && mounted) {
            final words = await Navigator.push<List<String>>(
              context,
              MaterialPageRoute(
                builder: (_) => const RecoveryRestoreScreen(),
              ),
            );
            if (words != null) {
              try {
                await IdentitySetup.restore(tokenedApi, words);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Не удалось восстановить ключ: $e')),
                  );
                }
              }
            }
          } else if (status == IdentityStatus.absent && mounted) {
            // Old account with no E2E identity yet — bootstrap one now.
            final phrase = await IdentitySetup.initialize(tokenedApi);
            if (!mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecoveryPhraseScreen(phrase: phrase),
              ),
            );
          }
        } catch (_) { /* network → defer to next launch */ }
      }

      await ref.read(authProvider.notifier).set(auth);
    } on ApiException catch (e) {
      if (mounted) setState(() => _err = e.message);
    } catch (_) {
      if (mounted) setState(() => _err = 'Не удалось подключиться к серверу');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: GlassCard(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Kirca',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: AppColors.onGlass,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'тихий чат',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.onGlassMuted, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    GlassSegmentedControl(
                      segments: const ['Вход', 'Регистрация'],
                      selectedIndex: _mode,
                      onSegmentSelected: (i) => setState(() => _mode = i),
                    ),
                    const SizedBox(height: 20),
                    GlassTextField(
                      controller: _u,
                      placeholder: 'Имя пользователя',
                      prefixIcon: const Icon(Icons.alternate_email, size: 18),
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    ),
                    const SizedBox(height: 10),
                    GlassPasswordField(
                      controller: _p,
                      placeholder: 'Пароль',
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    if (_err != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _err!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.danger),
                      ),
                    ],
                    const SizedBox(height: 20),
                    GlassButton.custom(
                      onTap: _busy ? () {} : _submit,
                      width: double.infinity,
                      height: 48,
                      useOwnLayer: true,
                      shape: LiquidRoundedSuperellipse(borderRadius: 14),
                      child: Center(
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.onGlass,
                                ),
                              )
                            : Text(
                                _isRegister ? 'Создать аккаунт' : 'Войти',
                                style: const TextStyle(
                                  color: AppColors.onGlass,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
