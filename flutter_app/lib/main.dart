import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'state.dart';
import 'screens/login.dart';
import 'screens/rooms.dart';
import 'theme/app_theme.dart';
import 'ws/user_ws.dart';

/// LiquidGlass behaviour per platform.
///
/// - `full`: pre-warm shaders + adaptive-quality scope. The library benchmarks
///   ~180 real frames before settling on a quality tier — worth it on devices
///   where the premium glass path actually runs.
/// - `basic`: pre-warm shaders + plain wrap (no adaptive scope). Phase 1 of
///   the library forces `minimal` quality where shaders are unsupported, so on
///   Skia-only desktop the adaptive benchmark would just measure nothing for
///   3 s before reaching the same answer.
/// - `off`: skip both init and wrap. Glass widgets degrade gracefully.
enum _GlassMode { full, basic, off }

_GlassMode _glassModeForPlatform() {
  if (kIsWeb) return _GlassMode.off;
  if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
    return _GlassMode.full;
  }
  if (Platform.isLinux || Platform.isWindows) return _GlassMode.basic;
  return _GlassMode.off;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  final _GlassMode glass = _glassModeForPlatform();
  if (glass != _GlassMode.off) {
    await LiquidGlassWidgets.initialize(
      enablePerformanceMonitor: glass == _GlassMode.full,
    );
  }

  Widget root = const ProviderScope(child: App());
  switch (glass) {
    case _GlassMode.full:
      root = LiquidGlassWidgets.wrap(adaptiveQuality: true, child: root);
    case _GlassMode.basic:
      root = LiquidGlassWidgets.wrap(adaptiveQuality: false, child: root);
    case _GlassMode.off:
      break;
  }
  runApp(root);
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    // Активируем глобальный WS, пока есть auth.
    if (auth != null) ref.watch(userWsProvider);
    return MaterialApp(
      title: 'Kirca',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: auth == null ? const LoginScreen() : const RoomsScreen(),
    );
  }
}
