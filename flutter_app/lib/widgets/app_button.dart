import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/app_theme.dart';
import '../theme/design.dart';

/// Visual weight of an action, so the user can read importance at a glance:
///
/// - [primary] — the one affirmative action on a surface (accent glow, bold).
/// - [secondary] — neutral / dismiss actions (no glow).
/// - [danger] — destructive actions (red glow + red label).
enum AppButtonVariant { primary, secondary, danger }

/// The single button used across the app. Replaces hand-rolled
/// `GlassButton.custom(... LiquidRoundedSuperellipse(borderRadius: X) ...)`
/// blocks so radius, height, glow and typography stay consistent and action
/// hierarchy is explicit via [variant].
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onTap,
    this.variant = AppButtonVariant.primary,
    this.busy = false,
    this.width = double.infinity,
    this.height = AppSize.buttonHeight,
    this.icon,
  });

  const AppButton.primary({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.width = double.infinity,
    this.height = AppSize.buttonHeight,
    this.icon,
  }) : variant = AppButtonVariant.primary;

  const AppButton.secondary({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.width = double.infinity,
    this.height = AppSize.buttonHeight,
    this.icon,
  }) : variant = AppButtonVariant.secondary;

  const AppButton.danger({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.width = double.infinity,
    this.height = AppSize.buttonHeight,
    this.icon,
  }) : variant = AppButtonVariant.danger;

  final String label;
  final VoidCallback? onTap;
  final AppButtonVariant variant;
  final bool busy;
  final double width;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color? glow = switch (variant) {
      AppButtonVariant.primary => AppColors.accent,
      AppButtonVariant.secondary => null,
      AppButtonVariant.danger => AppColors.danger,
    };
    final Color fg = variant == AppButtonVariant.danger
        ? AppColors.danger
        : AppColors.onGlass;
    final TextStyle textStyle = (variant == AppButtonVariant.secondary
            ? AppType.body
            : AppType.button)
        .copyWith(color: fg);

    final disabled = onTap == null || busy;

    return GlassButton.custom(
      onTap: disabled ? () {} : onTap!,
      width: width,
      height: height,
      glowColor: glow,
      useOwnLayer: true,
      shape: AppRadius.glassMd,
      child: Center(
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.onGlass,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: fg, size: 18),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  Text(label, style: textStyle),
                ],
              ),
      ),
    );
  }
}
