import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  tester.binding.renderViews.first.visitChildren(visit);
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

String _hexColor(Color c) {
  final int v = c.toARGB32();
  return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

String _rectStr(Rect r) {
  return '@[${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} '
      '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}]';
}

String? _formatNode(SemanticsNode node, Rect globalRect) {
  if (node.isMergedIntoParent) return null;

  final SemanticsData data = node.getSemanticsData();
  final ui.SemanticsFlags flags = data.flagsCollection;
  final bool hasContent = data.label.isNotEmpty ||
      data.value.isNotEmpty ||
      data.hint.isNotEmpty ||
      data.tooltip.isNotEmpty;

  if (flags.scopesRoute && !hasContent) return null;
  if (flags.isHidden) return null;

  final List<String> roles = [];
  if (flags.isHeader) roles.add('header');
  if (flags.isButton) roles.add('button');
  if (flags.isTextField) roles.add('input');
  if (flags.isLink) roles.add('link');
  if (flags.isImage) roles.add('image');
  if (flags.isSlider) roles.add('slider');
  if (flags.isInMutuallyExclusiveGroup) roles.add('tab');
  if (flags.hasImplicitScrolling) roles.add('scrollable');
  if (node.role != ui.SemanticsRole.none) roles.add(node.role.name);

  final List<String> states = [];
  if (flags.isSelected == ui.Tristate.isTrue) states.add('selected');
  if (flags.isChecked != ui.CheckedState.none) {
    states.add(flags.isChecked == ui.CheckedState.isTrue
        ? 'checked'
        : flags.isChecked == ui.CheckedState.mixed
            ? 'mixed'
            : 'unchecked');
  }
  if (flags.isToggled != ui.Tristate.none) {
    states.add(flags.isToggled == ui.Tristate.isTrue ? 'on' : 'off');
  }
  if (flags.isEnabled == ui.Tristate.isFalse) states.add('disabled');
  if (flags.isFocused == ui.Tristate.isTrue) states.add('focused');
  if (flags.isObscured) states.add('obscured');
  if (flags.isReadOnly) states.add('readonly');
  if (flags.isRequired == ui.Tristate.isTrue) states.add('required');
  if (flags.isExpanded != ui.Tristate.none) {
    states.add(flags.isExpanded == ui.Tristate.isTrue ? 'expanded' : 'collapsed');
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

  if (flags.hasImplicitScrolling && data.scrollPosition != null) {
    final pos = data.scrollPosition!.toStringAsFixed(0);
    final max = (data.scrollExtentMax ?? 0).toStringAsFixed(0);
    sb.write(' scroll=$pos/$max');
  }

  if (!globalRect.isEmpty) {
    sb.write(' ');
    sb.write(_rectStr(globalRect));
  }

  return sb.toString();
}

void _writeNode(
  StringBuffer buf,
  SemanticsNode node,
  int depth,
  Matrix4 parentTransform,
) {
  final Matrix4 current = node.transform == null
      ? parentTransform
      : (Matrix4.copy(parentTransform)..multiply(node.transform!));
  final Rect globalRect = MatrixUtils.transformRect(current, node.rect);
  final String? line = _formatNode(node, globalRect);
  final int childDepth = line == null ? depth : depth + 1;
  if (line != null) {
    buf.write('  ' * depth);
    buf.writeln(line);
  }
  final children =
      node.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder);
  for (final child in children) {
    _writeNode(buf, child, childDepth, current);
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
      _writeNode(sb, root, 0, Matrix4.identity());
    }
    viewIndex++;
  }

  final f = File('${_outDir.path}/$name.semantics.txt');
  await f.writeAsString(sb.toString());
  // ignore: avoid_print
  print('saved ${f.path}');
}

// ---------------------------------------------------------------------------
// Style dump
//
// Walks the *Element* tree (which has BuildContext and resolved Themes) and
// emits one line per paint-significant widget: Text + its effective style,
// Icon + tint, Container/DecoratedBox/Material backgrounds + radii.
// Every line gets the on-screen rect, so layout is reconstructable.
//
// File: `NN-name.styles.txt`, next to the semantics dump.
// ---------------------------------------------------------------------------

Rect? _globalRect(RenderObject? r) {
  if (r is! RenderBox || !r.hasSize || !r.attached) return null;
  final Offset tl = r.localToGlobal(Offset.zero);
  return tl & r.size;
}

String _textStyleSummary(TextStyle s) {
  final parts = <String>[];
  if (s.fontFamily != null && s.fontFamily!.isNotEmpty) parts.add(s.fontFamily!);
  if (s.fontSize != null) parts.add('${s.fontSize!.toStringAsFixed(0)}px');
  final FontWeight? w = s.fontWeight;
  if (w != null && w != FontWeight.normal) parts.add('w${w.value}');
  if (s.fontStyle == FontStyle.italic) parts.add('italic');
  if (s.color != null) parts.add(_hexColor(s.color!));
  if (s.decoration != null && s.decoration != TextDecoration.none) {
    parts.add(s.decoration.toString().replaceAll('TextDecoration.', ''));
  }
  if (s.height != null) parts.add('lh${s.height!.toStringAsFixed(2)}');
  if (s.letterSpacing != null && s.letterSpacing != 0) {
    parts.add('ls${s.letterSpacing!.toStringAsFixed(1)}');
  }
  return parts.isEmpty ? '' : ' ${parts.join(' ')}';
}

String? _formatBorderRadius(BorderRadiusGeometry? br) {
  if (br == null) return null;
  if (br is BorderRadius) {
    final r = br.topLeft.x;
    if (br.topLeft == br.topRight &&
        br.topLeft == br.bottomLeft &&
        br.topLeft == br.bottomRight) {
      return 'radius=${r.toStringAsFixed(0)}';
    }
    return 'radius=${br.topLeft.x.toStringAsFixed(0)}/${br.topRight.x.toStringAsFixed(0)}/'
        '${br.bottomRight.x.toStringAsFixed(0)}/${br.bottomLeft.x.toStringAsFixed(0)}';
  }
  return 'radius=$br';
}

String? _formatStyleLine(Element el) {
  final Widget widget = el.widget;
  final Rect? rect = _globalRect(el.findRenderObject());

  if (widget is Text) {
    final String text = widget.data ?? '';
    if (text.isEmpty || rect == null || rect.isEmpty) return null;
    final TextStyle base = DefaultTextStyle.of(el).style;
    final TextStyle effective =
        widget.style == null ? base : base.merge(widget.style);
    return 'Text "${_escape(text)}"${_textStyleSummary(effective)} ${_rectStr(rect)}';
  }

  if (widget is RichText) {
    if (rect == null || rect.isEmpty) return null;
    final String text = widget.text.toPlainText().trim();
    if (text.isEmpty) return null;
    final TextStyle? style = widget.text.style;
    return 'RichText "${_escape(text)}"${style == null ? '' : _textStyleSummary(style)} ${_rectStr(rect)}';
  }

  if (widget is Icon) {
    final List<String> parts = ['Icon'];
    final IconData? ic = widget.icon;
    if (ic != null) {
      parts.add('${ic.fontFamily ?? "?"}/0x${ic.codePoint.toRadixString(16)}');
    }
    if (widget.size != null) parts.add('${widget.size!.toStringAsFixed(0)}px');
    if (widget.color != null) parts.add(_hexColor(widget.color!));
    var line = parts.join(' ');
    if (rect != null && !rect.isEmpty) line += ' ${_rectStr(rect)}';
    return line;
  }

  if (widget is Container) {
    final parts = <String>['Container'];
    final Decoration? dec = widget.decoration;
    if (dec is BoxDecoration) {
      if (dec.color != null) parts.add('bg=${_hexColor(dec.color!)}');
      final String? br = _formatBorderRadius(dec.borderRadius);
      if (br != null) parts.add(br);
      if (dec.border != null) parts.add('border');
      if (dec.boxShadow != null && dec.boxShadow!.isNotEmpty) parts.add('shadow');
      if (dec.gradient != null) parts.add('gradient');
    } else if (widget.color != null) {
      parts.add('bg=${_hexColor(widget.color!)}');
    }
    if (parts.length == 1) return null;
    if (rect != null && !rect.isEmpty) parts.add(_rectStr(rect));
    return parts.join(' ');
  }

  if (widget is DecoratedBox) {
    final Decoration dec = widget.decoration;
    if (dec is! BoxDecoration) return null;
    final parts = <String>['DecoratedBox'];
    if (dec.color != null) parts.add('bg=${_hexColor(dec.color!)}');
    final String? br = _formatBorderRadius(dec.borderRadius);
    if (br != null) parts.add(br);
    if (dec.border != null) parts.add('border');
    if (dec.boxShadow != null && dec.boxShadow!.isNotEmpty) parts.add('shadow');
    if (dec.gradient != null) parts.add('gradient');
    if (parts.length == 1) return null;
    if (rect != null && !rect.isEmpty) parts.add(_rectStr(rect));
    return parts.join(' ');
  }

  if (widget is Material) {
    final parts = <String>['Material'];
    if (widget.color != null) parts.add('bg=${_hexColor(widget.color!)}');
    if (widget.elevation != 0) {
      parts.add('elev=${widget.elevation.toStringAsFixed(0)}');
    }
    final ShapeBorder? shape = widget.shape;
    if (shape is RoundedRectangleBorder) {
      final String? br = _formatBorderRadius(shape.borderRadius);
      if (br != null) parts.add(br);
    } else if (shape is CircleBorder) {
      parts.add('circle');
    }
    if (parts.length == 1) return null;
    if (rect != null && !rect.isEmpty) parts.add(_rectStr(rect));
    return parts.join(' ');
  }

  if (widget is Card) {
    final parts = <String>['Card'];
    if (widget.color != null) parts.add('bg=${_hexColor(widget.color!)}');
    if (widget.elevation != null) {
      parts.add('elev=${widget.elevation!.toStringAsFixed(0)}');
    }
    if (rect != null && !rect.isEmpty) parts.add(_rectStr(rect));
    return parts.join(' ');
  }

  if (widget is ColoredBox) {
    if (rect == null || rect.isEmpty) return null;
    return 'ColoredBox bg=${_hexColor(widget.color)} ${_rectStr(rect)}';
  }

  return null;
}

bool _isStyleLeaf(Widget w) =>
    w is Text || w is RichText || w is Icon || w is ColoredBox;

void _walkForStyle(StringBuffer buf, Element el, int depth) {
  final String? line = _formatStyleLine(el);
  final int childDepth = line == null ? depth : depth + 1;
  if (line != null) {
    buf.write('  ' * depth);
    buf.writeln(line);
  }
  // Skip children of leaf widgets — Text and Icon both wrap a RichText that
  // would otherwise emit a near-duplicate line.
  if (_isStyleLeaf(el.widget)) return;
  el.visitChildren((child) => _walkForStyle(buf, child, childDepth));
}

Future<void> _dumpStyles(WidgetTester tester, String name) async {
  await tester.pump();

  final sb = StringBuffer()..writeln('# $name (styles)');
  final Element? root = tester.binding.rootElement;
  if (root == null) {
    sb.writeln('(no root element)');
  } else {
    _walkForStyle(sb, root, 0);
  }

  final f = File('${_outDir.path}/$name.styles.txt');
  await f.writeAsString(sb.toString());
  // ignore: avoid_print
  print('saved ${f.path}');
}

Future<void> _capture(WidgetTester tester, String name) async {
  await _shot(tester, name);
  await _dumpSemantics(tester, name);
  await _dumpStyles(tester, name);
}

Future<void> _settle(WidgetTester tester,
    {Duration timeout = const Duration(seconds: 3)}) async {
  // Fixed-frame pump instead of pumpAndSettle: the app's LiquidGlass
  // PerformanceMonitor schedules a frame callback every tick, so under
  // LiveTestWidgetsFlutterBinding pumpAndSettle never converges (and unlike
  // the offline binding it does not reliably throw — the whole test then
  // hangs at the very first _settle call after app.main()).
  const Duration frame = Duration(milliseconds: 50);
  final int frames =
      (timeout.inMilliseconds / frame.inMilliseconds).ceil().clamp(10, 400);
  for (var i = 0; i < frames; i++) {
    await tester.pump(frame);
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

    // flutter_secure_storage on Linux talks to libsecret over D-Bus. In this
    // sandbox there is no session bus, and `.read()` hangs forever (no error,
    // no timeout — AuthNotifier._load() never returns, the first frame never
    // builds, and tester.pump() blocks). Mock the plugin channel to return
    // null for every call; the app then starts with no saved auth.
    const MethodChannel storageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async => null);
  });

  testWidgets('e2e flow: login → rooms → chat → members → profile',
      (tester) async {
    // Mirror app.main() but skip LiquidGlassWidgets.wrap(adaptiveQuality:true).
    // The adaptive scope benchmarks ~180 real frames before settling — under
    // LiveTestWidgetsFlutterBinding that loop never converges and the very
    // first tester.pump() hangs forever (no exception, no timeout).
    WidgetsFlutterBinding.ensureInitialized();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    runApp(const ProviderScope(child: app.App()));
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
