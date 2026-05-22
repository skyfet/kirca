import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Тёмный фон с диагональным градиентом и тремя размытыми цветными
/// «blob»-кругами. Поверх этого фона glass-эффекты получают выраженный
/// blur/refraction.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.bgTop, AppColors.bgMid, AppColors.bgBottom],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        Positioned(
          top: -120,
          left: -80,
          child: _Blob(color: AppColors.blobIndigo.withOpacity(0.55), size: 360),
        ),
        Positioned(
          top: 180,
          right: -120,
          child: _Blob(color: AppColors.blobViolet.withOpacity(0.45), size: 320),
        ),
        Positioned(
          bottom: -100,
          left: 40,
          child: _Blob(color: AppColors.blobTeal.withOpacity(0.30), size: 280),
        ),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
