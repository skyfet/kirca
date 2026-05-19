import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Тонкая обёртка над нативным каналом APNs.
/// На стороне iOS — AppDelegate.swift, который запрашивает разрешение,
/// регистрирует устройство в Apple и вызывает invokeMethod('onToken', hex).
class Push {
  static const _channel = MethodChannel('kirca/apns');
  static Completer<String?>? _pending;
  static bool _initialized = false;

  static void _ensure() {
    if (_initialized) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onToken') {
        final t = call.arguments as String?;
        _pending?.complete(t);
        _pending = null;
      }
    });
    _initialized = true;
  }

  /// Запрашивает у системы разрешение и возвращает device-token (hex).
  /// На не-iOS возвращает null.
  /// На отказе/таймауте — тоже null.
  static Future<String?> requestToken({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!Platform.isIOS) return null;
    _ensure();
    _pending = Completer<String?>();
    try {
      await _channel.invokeMethod('requestPermissions');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    try {
      return await _pending!.future.timeout(timeout);
    } catch (_) {
      _pending = null;
      return null;
    }
  }
}
