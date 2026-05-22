import 'package:flutter/material.dart';

class AppColors {
  static const seed = Color(0xFF6E6BFF);
  static const accent = Color(0xFFB46CFF);
  static const danger = Color(0xFFFF5C7A);

  static const background = Color(0xFF111128);
  static const surface = Color(0xFF1A1A33);

  static const blobIndigo = Color(0xFF5B5BFF);
  static const blobViolet = Color(0xFFB46CFF);
  static const blobTeal = Color(0xFF3DDCC1);

  static const onGlass = Colors.white;
  static const onGlassMuted = Color(0xCCFFFFFF);
  static const onGlassDim = Color(0x80FFFFFF);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.dark,
  ).copyWith(
    surface: Colors.transparent,
    onSurface: AppColors.onGlass,
    error: AppColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    textTheme: const TextTheme(
      bodySmall: TextStyle(color: AppColors.onGlassMuted),
      bodyMedium: TextStyle(color: AppColors.onGlass),
      bodyLarge: TextStyle(color: AppColors.onGlass),
      titleSmall: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w700),
      labelLarge: TextStyle(color: AppColors.onGlass, fontWeight: FontWeight.w600),
    ).apply(
      bodyColor: AppColors.onGlass,
      displayColor: AppColors.onGlass,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: false,
      hintStyle: TextStyle(color: AppColors.onGlassDim),
      labelStyle: TextStyle(color: AppColors.onGlassMuted),
      border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.onGlassDim)),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.onGlassDim)),
      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.onGlass)),
    ),
    iconTheme: const IconThemeData(color: AppColors.onGlass),
    dividerColor: const Color(0x1FFFFFFF),
  );
}
