import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../crypto/phrase.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';

/// Modal shown immediately after registration: the user must save the 24-word
/// recovery phrase or they lose access to E2E history on every future device.
/// Returns when the user explicitly acknowledges they've written it down.
class RecoveryPhraseScreen extends StatelessWidget {
  final List<String> phrase;
  const RecoveryPhraseScreen({super.key, required this.phrase});

  @override
  Widget build(BuildContext context) {
    final groups = <List<String>>[];
    for (var i = 0; i < phrase.length; i += 6) {
      groups.add(phrase.sublist(i, i + 6));
    }
    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Ключ восстановления',
                    style: TextStyle(
                      color: AppColors.onGlass,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Запиши эти 24 слова. Без них на новом устройстве ты не '
                    'сможешь прочитать переписку в шифрованных чатах. Сервер '
                    'не хранит твой пароль шифрования — только ты.',
                    style: TextStyle(color: AppColors.onGlassMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: GlassCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: List<Widget>.generate(groups.length, (gi) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Часть ${gi + 1}',
                                    style: const TextStyle(
                                      color: AppColors.onGlassMuted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: List<Widget>.generate(
                                      groups[gi].length,
                                      (wi) => _WordChip(
                                        index: gi * 6 + wi + 1,
                                        word: groups[gi][wi],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassButton.custom(
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: Phrase.format(phrase)),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')),
                      );
                    },
                    width: double.infinity,
                    height: 44,
                    useOwnLayer: true,
                    shape: LiquidRoundedSuperellipse(borderRadius: 12),
                    child: const Center(
                      child: Text(
                        'Скопировать',
                        style: TextStyle(color: AppColors.onGlass),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GlassButton.custom(
                    onTap: () => Navigator.pop(context, true),
                    glowColor: AppColors.accent,
                    width: double.infinity,
                    height: 48,
                    useOwnLayer: true,
                    shape: LiquidRoundedSuperellipse(borderRadius: 14),
                    child: const Center(
                      child: Text(
                        'Я записал, продолжить',
                        style: TextStyle(
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
    );
  }
}

class _WordChip extends StatelessWidget {
  final int index;
  final String word;
  const _WordChip({required this.index, required this.word});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x18FFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$index.',
              style: const TextStyle(
                color: AppColors.onGlassMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const TextSpan(text: ' '),
            TextSpan(
              text: word,
              style: const TextStyle(
                color: AppColors.onGlass,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: 'Menlo',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prompt the user for their 24-word phrase. Accepts any whitespace; returns
/// the trimmed list on submit, or null if the user backs out.
class RecoveryRestoreScreen extends StatefulWidget {
  const RecoveryRestoreScreen({super.key});
  @override
  State<RecoveryRestoreScreen> createState() => _RecoveryRestoreScreenState();
}

class _RecoveryRestoreScreenState extends State<RecoveryRestoreScreen> {
  final _ctrl = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final words = Phrase.parse(_ctrl.text);
    if (words.length != 24) {
      setState(() => _err = 'Нужно ровно 24 слова, ввёл ${words.length}');
      return;
    }
    Navigator.pop(context, words);
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
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: AppColors.onGlass,
            elevation: 0,
            title: const Text('Восстановление'),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Введи 24 слова (любые пробелы / переводы строк) в том же '
                    'порядке, в котором они показывались при регистрации.',
                    style: TextStyle(color: AppColors.onGlassMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: GlassTextField(
                      controller: _ctrl,
                      autofocus: true,
                      minLines: 6,
                      maxLines: 8,
                      placeholder: 'genesis exodus … revelation',
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                  if (_err != null) ...[
                    const SizedBox(height: 10),
                    Text(_err!, style: const TextStyle(color: AppColors.danger)),
                  ],
                  const SizedBox(height: 14),
                  GlassButton.custom(
                    onTap: _submit,
                    glowColor: AppColors.accent,
                    width: double.infinity,
                    height: 48,
                    useOwnLayer: true,
                    shape: LiquidRoundedSuperellipse(borderRadius: 14),
                    child: const Center(
                      child: Text(
                        'Восстановить',
                        style: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
