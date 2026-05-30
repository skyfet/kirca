import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/app_background.dart';

/// One place for the page chrome that used to be copy-pasted into every screen:
/// `GlassPage → AdaptiveLiquidGlassLayer → Scaffold`, all transparent and
/// edge-to-edge.
///
/// Two modes:
///
/// - **Standalone** (default, `glass: true`) — owns the background, the status
///   bar style and the liquid-glass layer. Use for pushed routes (login,
///   archive, members, …).
/// - **Hosted** (`glass: false`) — renders only the transparent inner
///   `Scaffold`, inheriting the background and glass layer from an ancestor
///   (the [HomeShell]). Use for the bottom-bar tab screens so the whole shell
///   shares a single glass layer.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.glass = true,
    this.extendBodyBehindAppBar = true,
    this.extendBody = true,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  /// When false, skips the [GlassPage] + [AdaptiveLiquidGlassLayer] wrappers and
  /// returns just the transparent [Scaffold] (for use inside a host that
  /// already provides them).
  final bool glass;
  final bool extendBodyBehindAppBar;
  final bool extendBody;

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      extendBody: extendBody,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: body,
    );

    if (!glass) return scaffold;

    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: scaffold,
      ),
    );
  }
}
