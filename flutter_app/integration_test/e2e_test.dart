import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:kirca/main.dart' as app;

late final Directory _outDir;

Future<void> _shot(WidgetTester tester, String name) async {
  // Drain paint debt before snapshotting.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
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
  // Escape test framework's frame control so toImage can run a real paint.
  final bytes = await tester.runAsync<Uint8List?>(() async {
    final image = await rb!.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  });
  if (bytes == null) return;
  final f = File('${_outDir.path}/$name.png');
  await f.writeAsBytes(bytes);
  // ignore: avoid_print
  print('saved ${f.path}');
}

// ---------------------------------------------------------------------------
// Semantics tree dump
//
// Compact, line-per-node format optimised for reading by an LLM. Indent = depth
// inside the *visible* (post-filter) tree. Mirrors the filter used by
// SemanticsController.simulatedAccessibilityTraversal: drops merged-up nodes,
// drops route-scoping containers, keeps anything with label/value/hint/tooltip,
// an interactive flag or a non-scroll action.
//
// One file per step, e.g. `01-login.semantics.txt`, next to the PNG.
// ---------------------------------------------------------------------------

const _kActionsToHide = <SemanticsAction>{
  SemanticsAction.didGainAccessibilityFocus,
  SemanticsAction.didLoseAccessibilityFocus,
  SemanticsAction.showOnScreen,
  SemanticsAction.scrollUp,
  SemanticsAction.scrollDown,
  SemanticsAction.scrollLeft,
  SemanticsAction.scrollRight,
  SemanticsAction.scrollToOffset,
};

String _escape(String s) =>
    s.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

String? _formatNode(SemanticsNode node) {
  if (node.isMergedIntoParent) return null;

  final SemanticsData data = node.getSemanticsData();
  final bool isRoute = data.hasFlag(SemanticsFlag.scopesRoute);
  final bool hasContent = data.label.isNotEmpty ||
      data.value.isNotEmpty ||
      data.hint.isNotEmpty ||
      data.tooltip.isNotEmpty;

  if (isRoute && !hasContent) return null;
  if (data.hasFlag(SemanticsFlag.isHidden)) return null;

  final List<String> roles = [];
  if (data.hasFlag(SemanticsFlag.isHeader)) roles.add('header');
  if (data.hasFlag(SemanticsFlag.isButton)) roles.add('button');
  if (data.hasFlag(SemanticsFlag.isTextField)) roles.add('input');
  if (data.hasFlag(SemanticsFlag.isLink)) roles.add('link');
  if (data.hasFlag(SemanticsFlag.isImage)) roles.add('image');
  if (data.hasFlag(SemanticsFlag.isSlider)) roles.add('slider');
  if (data.hasFlag(SemanticsFlag.isInMutuallyExclusiveGroup)) roles.add('tab');
  if (data.hasFlag(SemanticsFlag.hasImplicitScrolling)) roles.add('scrollable');
  if (node.role != SemanticsRole.none) roles.add(node.role.name);

  final List<String> states = [];
  if (data.hasFlag(SemanticsFlag.isSelected)) states.add('selected');
  if (data.hasFlag(SemanticsFlag.hasCheckedState)) {
    states.add(data.hasFlag(SemanticsFlag.isChecked) ? 'checked' : 'unchecked');
  }
  if (data.hasFlag(SemanticsFlag.hasToggledState)) {
    states.add(data.hasFlag(SemanticsFlag.isToggled) ? 'on' : 'off');
  }
  if (data.hasFlag(SemanticsFlag.hasEnabledState) &&
      !data.hasFlag(SemanticsFlag.isEnabled)) {
    states.add('disabled');
  }
  if (data.hasFlag(SemanticsFlag.isFocused)) states.add('focused');
  if (data.hasFlag(SemanticsFlag.isObscured)) states.add('obscured');
  if (data.hasFlag(SemanticsFlag.isReadOnly)) states.add('readonly');
  if (data.hasFlag(SemanticsFlag.isRequired)) states.add('required');
  if (data.hasFlag(SemanticsFlag.hasExpandedState)) {
    states.add(data.hasFlag(SemanticsFlag.isExpanded) ? 'expanded' : 'collapsed');
  }

  final List<String> actions = [];
  for (final SemanticsAction a in SemanticsAction.values) {
    if (_kActionsToHide.contains(a)) continue;
    if (!data.hasAction(a)) continue;
    actions.add(a.name);
  }

  final bool hasSignal =
      roles.isNotEmpty || states.isNotEmpty || actions.isNotEmpty;
  if (!hasContent && !hasSignal) return null;

  final sb = StringBuffer();
  if (roles.isNotEmpty) sb.write(roles.join('+'));
  if (data.label.isNotEmpty) {
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('"${_escape(data.label)}"');
  }
  if (data.value.isNotEmpty) sb.write(' value="${_escape(data.value)}"');
  if (data.hint.isNotEmpty) sb.write(' hint="${_escape(data.hint)}"');
  if (data.tooltip.isNotEmpty) sb.write(' tooltip="${_escape(data.tooltip)}"');
  if (data.identifier.isNotEmpty) sb.write(' id=${data.identifier}');
  if (states.isNotEmpty) sb.write(' [${states.join(',')}]');
  if (actions.isNotEmpty) sb.write(' {${actions.join(',')}}');

  if (data.hasFlag(SemanticsFlag.hasImplicitScrolling) &&
      data.scrollPosition != null) {
    final pos = data.scrollPosition!.toStringAsFixed(0);
    final max = (data.scrollExtentMax ?? 0).toStringAsFixed(0);
    sb.write(' scroll=$pos/$max');
  }

  return sb.toString();
}

void _writeNode(StringBuffer buf, SemanticsNode node, int depth) {
  final String? line = _formatNode(node);
  final int childDepth = line == null ? depth : depth + 1;
  if (line != null) {
    buf.write('  ' * depth);
    buf.writeln(line);
  }
  final children =
      node.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder);
  for (final child in children) {
    _writeNode(buf, child, childDepth);
  }
}

Future<void> _dumpSemantics(WidgetTester tester, String name) async {
  // Give the semantics owner a frame to flush any pending updates.
  await tester.pump();

  final sb = StringBuffer()..writeln('# $name');
  var viewIndex = 0;
  for (final RenderView rv in tester.binding.renderViews) {
    final SemanticsNode? root = rv.owner?.semanticsOwner?.rootSemanticsNode;
    final Size size = rv.size;
    sb.writeln(
      '## view $viewIndex  ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}',
    );
    if (root == null) {
      sb.writeln('(no semantics tree — handle inactive?)');
    } else {
      _writeNode(sb, root, 0);
    }
    viewIndex++;
  }

  final f = File('${_outDir.path}/$name.semantics.txt');
  await f.writeAsString(sb.toString());
  // ignore: avoid_print
  print('saved ${f.path}');
}

Future<void> _capture(WidgetTester tester, String name) async {
  await _shot(tester, name);
  await _dumpSemantics(tester, name);
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
    await _capture(tester, '01-login');

    // Switch to "Регистрация" tab.
    final regTab = find.text('Регистрация');
    expect(regTab, findsAtLeastNWidgets(1));
    await _tap(tester, regTab.first);
    await _capture(tester, '02-login-register-tab');

    // Fill credentials.
    final tf = find.byType(EditableText);
    expect(tf, findsAtLeastNWidgets(2));
    final username = 'demo${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(tf.at(0), username);
    await tester.enterText(tf.at(1), 'testpass1');
    await _settle(tester);
    await _capture(tester, '03-login-filled');

    // Submit — primary button is now "Создать аккаунт".
    await _tap(tester, find.text('Создать аккаунт').first);
    await _settle(tester, timeout: const Duration(seconds: 10));
    await _capture(tester, '04-rooms-empty');

    // FAB → new room.
    final fab = find.byIcon(Icons.add);
    if (fab.evaluate().isNotEmpty) {
      await _tap(tester, fab.first);
      await _capture(tester, '05-new-room-dialog');

      final dialogField = find.byType(EditableText).last;
      await tester.enterText(dialogField, 'Демо-комната');
      await _settle(tester);
      await _capture(tester, '06-new-room-filled');

      final create = find.text('Создать');
      if (create.evaluate().isNotEmpty) {
        await _tap(tester, create.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _capture(tester, '07-rooms-with-tile');
      }
    }

    // Open chat.
    final tile = find.text('Демо-комната');
    if (tile.evaluate().isNotEmpty) {
      await _tap(tester, tile.first);
      await _settle(tester, timeout: const Duration(seconds: 10));
      await _capture(tester, '08-chat-empty');

      final input = find.byType(EditableText).last;
      await tester.enterText(input, 'Привет, мир!');
      await _settle(tester);
      await _capture(tester, '09-chat-typing');

      final send = find.byIcon(Icons.send_rounded);
      if (send.evaluate().isNotEmpty) {
        await _tap(tester, send.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _capture(tester, '10-chat-with-message');
      }

      // Members.
      final members = find.byIcon(Icons.people_outline);
      if (members.evaluate().isNotEmpty) {
        await _tap(tester, members.first);
        await _settle(tester, timeout: const Duration(seconds: 10));
        await _capture(tester, '11-members');
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
      await _capture(tester, '12-profile');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
