import 'dart:io' show Platform;

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  await LiquidGlassWidgets.initialize();
  runApp(
    LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      child: const ProviderScope(child: App()),
    ),
  );
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
