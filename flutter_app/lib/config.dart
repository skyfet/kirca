/// Адреса бэкенда.
/// Меняй для прод-деплоя на свой workers.dev домен.
class Config {
  // Локальная разработка (wrangler dev по умолчанию на 8787):
  // - iOS Simulator: 127.0.0.1 работает
  // - реальный iPhone: используй IP мака в локальной сети (например 192.168.1.10)
  static const String apiBase = 'http://127.0.0.1:8787';
  static const String wsBase = 'ws://127.0.0.1:8787';

  // После деплоя:
  // static const String apiBase = 'https://kirca-api.<твой>.workers.dev';
  // static const String wsBase  = 'wss://kirca-api.<твой>.workers.dev';
}
