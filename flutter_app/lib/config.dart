/// Адреса бэкенда.
///
/// Переопределяются на сборке через `--dart-define`:
///   flutter run --dart-define=KIRCA_API_BASE=https://kirca-api.gdetemka.workers.dev
///   flutter build ios --dart-define=KIRCA_API_BASE=https://kirca-api.gdetemka.workers.dev
///
/// WS-URL получается из `KIRCA_API_BASE` автоматической заменой `http(s)://` → `ws(s)://`.
/// При необходимости можно задать `KIRCA_WS_BASE` явно.
class Config {
  static const String _defaultApiBase = 'https://kirca-api.gdetemka.workers.dev';

  static const String apiBase =
      String.fromEnvironment('KIRCA_API_BASE', defaultValue: _defaultApiBase);

  static const String _wsBaseOverride =
      String.fromEnvironment('KIRCA_WS_BASE', defaultValue: '');

  static String get wsBase {
    if (_wsBaseOverride.isNotEmpty) return _wsBaseOverride;
    if (apiBase.startsWith('https://')) return 'wss://${apiBase.substring(8)}';
    if (apiBase.startsWith('http://')) return 'ws://${apiBase.substring(7)}';
    return apiBase;
  }
}
