import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_theme.dart';

/// Kirca design system — single source of truth for spacing, corner radii,
/// typography and motion. Screens and components must pull values from here
/// rather than hard-coding magic numbers, so the whole app shares one visual
/// rhythm. See `flutter_app/DESIGN.md` for the rationale and usage rules.

/// Spacing scale (4-pt grid). Use these for padding, gaps and margins.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// Corner-radius scale. Three meaningful tiers plus a pill for chips/badges:
///
/// - [sm] — inline chips, badges, small controls.
/// - [md] — list tiles, cards, inputs (the default surface radius).
/// - [lg] — prominent surfaces: dialogs, the login card, FAB.
/// - [pill] — fully rounded.
abstract final class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double pill = 999;

  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);

  /// Liquid-glass superellipse shapes at each tier, for glass widgets that take
  /// a `shape:` argument.
  static const LiquidRoundedSuperellipse glassSm =
      LiquidRoundedSuperellipse(borderRadius: sm);
  static const LiquidRoundedSuperellipse glassMd =
      LiquidRoundedSuperellipse(borderRadius: md);
  static const LiquidRoundedSuperellipse glassLg =
      LiquidRoundedSuperellipse(borderRadius: lg);
}

/// Typography scale. Built once over [AppColors] so colour + weight + size stay
/// consistent. Prefer these over inline `TextStyle(...)`.
abstract final class AppType {
  /// Screen / brand title (e.g. login "Kirca").
  static const display = TextStyle(
    color: AppColors.onGlass,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
  );

  /// App-bar / section title.
  static const title = TextStyle(
    color: AppColors.onGlass,
    fontSize: 18,
    fontWeight: FontWeight.w700,
  );

  /// Dialog / card heading.
  static const heading = TextStyle(
    color: AppColors.onGlass,
    fontSize: 17,
    fontWeight: FontWeight.w700,
  );

  /// Primary item label (room name, friend name).
  static const itemTitle = TextStyle(
    color: AppColors.onGlass,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  /// Default reading text.
  static const body = TextStyle(color: AppColors.onGlass, fontSize: 14);

  /// Secondary supporting text.
  static const bodyMuted =
      TextStyle(color: AppColors.onGlassMuted, fontSize: 13);

  /// Tertiary text — previews, timestamps, hints.
  static const caption =
      TextStyle(color: AppColors.onGlassDim, fontSize: 12);

  /// Smallest text — fine print, helper notes.
  static const fine = TextStyle(
    color: AppColors.onGlassDim,
    fontSize: 11,
    height: 1.4,
  );

  /// Emphasised label for primary buttons.
  static const button = TextStyle(
    color: AppColors.onGlass,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
}

/// Motion tokens. Keep transitions short and uniform so the UI feels calm
/// rather than busy.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOutCubic;
}

/// Standard sizes for recurring controls.
abstract final class AppSize {
  static const double fab = 56;
  static const double iconButton = 36;
  static const double buttonHeight = 48;
  static const double compactButtonHeight = 42;
  static const double avatar = 44; // radius 22
}
