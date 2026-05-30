import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/design.dart';

/// A [GlassCard] with a tap/long-press ripple on top — the pattern that was
/// duplicated as `Stack( GlassCard, Positioned.fill( Material( InkWell ) ) )`
/// in the room and friend lists. Centralised so the ink colours, radius and
/// content padding match everywhere.
class TappableCard extends StatelessWidget {
  const TappableCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding =
        const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
    this.radius = AppRadius.md,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);
    return Stack(
      children: [
        GlassCard(padding: padding, child: child),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            borderRadius: br,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: br,
              splashColor: const Color(0x1FFFFFFF),
              highlightColor: const Color(0x0FFFFFFF),
              hoverColor: const Color(0x0AFFFFFF),
            ),
          ),
        ),
      ],
    );
  }
}
