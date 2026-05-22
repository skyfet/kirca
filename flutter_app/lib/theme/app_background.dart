import 'package:flutter/material.dart';

import 'app_theme.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: AppColors.background);
  }
}
