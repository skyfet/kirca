import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:kirca/main.dart' as app;

late final Directory _outDir;

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  RenderRepaintBoundary? rb;
  void visit(RenderObject node) {
    if (rb != null) return;
    if (node is RenderRepaintBoundary) {
      rb = node;
      return;
    }
    node.visitChildren(visit);
  }
  WidgetsBinding.instance.renderViewElement!
      .findRenderObject()!
      .visitChildren(visit);
  if (rb == null) {
    // ignore: avoid_print
    print('no RenderRepaintBoundary for $name');
    return;
  }
  final image = await rb!.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) return;
  final f = File('${_outDir.path}/$name.png');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('saved ${f.path}');
}

Future<void> _settle(WidgetTester tester,
    {Duration timeout = const Duration(seconds: 5)}) async {
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, timeout);
  } catch (_) {
    // pump several frames to drain pending animations / streams.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f, warnIfMissed: false);
  await _settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _outDir = Directory('integration_test/screenshots');
    if (!_outDir.existsSync()) _outDir.createSync(recursive: true);
  });

  testWidgets('e2e flow: login → rooms → chat → members → profile',
      (tester) async {
    app.main();
    await _settle(tester);
    await _shot(tester, '01-login');

    // Switch to "Регистрация" tab.
    final regTab = find.text('Регистрация');
    expect(regTab, findsAtLeastNWidgets(1));
    await _tap(tester, regTab.first);
    await _shot(tester, '02-login-register-tab');

    // Fill credentials.
    final tf = find.byType(EditableText);
    expect(tf, findsAtLeastNWidgets(2));
    final username = 'demo${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(tf.at(0), username);
    await tester.enterText(tf.at(1), 'testpass1');
    await _settle(tester);
    await _shot(tester, '03-login-filled');

    // Submit — primary button is now "Создать аккаунт".
    await _tap(tester, find.text('Создать аккаунт').first);
    await _settle(tester, timeout: const Duration(seconds: 10));
    await _shot(tester, '04-rooms-empty');

    // FAB → new room.
    final fab = find.byIcon(Icons.add);
    if (fab.evaluate().isNotEmpty) {
      await _tap(tester, fab.first);
      await _shot(tester, '05-new-room-dialog');

      final dialogField = find.byType(EditableText).last;
      await tester.enterText(dialogField, 'Демо-комната');
      await _settle(tester);
      await _shot(tester, '06-new-room-filled');

      final create = find.text('Создать');
      if (create.evaluate().isNotEmpty) {
        await _tap(tester, create.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _shot(tester, '07-rooms-with-tile');
      }
    }

    // Open chat.
    final tile = find.text('Демо-комната');
    if (tile.evaluate().isNotEmpty) {
      await _tap(tester, tile.first);
      await _settle(tester, timeout: const Duration(seconds: 10));
      await _shot(tester, '08-chat-empty');

      final input = find.byType(EditableText).last;
      await tester.enterText(input, 'Привет, мир!');
      await _settle(tester);
      await _shot(tester, '09-chat-typing');

      final send = find.byIcon(Icons.send_rounded);
      if (send.evaluate().isNotEmpty) {
        await _tap(tester, send.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _shot(tester, '10-chat-with-message');
      }

      // Members.
      final members = find.byIcon(Icons.people_outline);
      if (members.evaluate().isNotEmpty) {
        await _tap(tester, members.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _shot(tester, '11-members');
        final back = find.byIcon(Icons.arrow_back_ios_new);
        if (back.evaluate().isNotEmpty) {
          await _tap(tester, back.first);
        }
      }

      // Back to rooms.
      final back = find.byIcon(Icons.arrow_back_ios_new);
      if (back.evaluate().isNotEmpty) {
        await _tap(tester, back.first);
      }
    }

    // Profile.
    final profileBtn = find.byIcon(Icons.account_circle_outlined);
    if (profileBtn.evaluate().isNotEmpty) {
      await _tap(tester, profileBtn.first);
      await _settle(tester, timeout: const Duration(seconds: 10));
      await _shot(tester, '12-profile');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
