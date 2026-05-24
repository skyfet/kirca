# kirca

Простой чат: Cloudflare Worker + Durable Objects + D1 для бэкенда, Flutter — для iOS-клиента.

См. также `LAUNCH.md` (пошаговый чек-лист публичного запуска), `DEPLOY.md` (CI/CD) и `ROADMAP.md` (что улучшать дальше).

```
kirca/
├── backend/           # Cloudflare Worker (TypeScript, Hono) — деплоится как `kirca-api`
│   ├── src/
│   │   ├── index.ts   # HTTP API + WS upgrade
│   │   ├── room.ts    # Durable Object (одна на комнату)
│   │   ├── openapi.ts # OpenAPI 3.1 спека (источник правды для /docs)
│   │   ├── home.ts    # HTML главной (/)
│   │   └── docs.ts    # HTML с Scalar UI (/docs)
│   ├── migrations/0001_init.sql
│   ├── wrangler.toml
│   ├── package.json
│   └── tsconfig.json
└── flutter_app/       # Flutter клиент (Riverpod), bundle id ai.kirca.app
    ├── lib/
    │   ├── main.dart
    │   ├── config.dart   # ← URL бэкенда тут
    │   ├── state.dart
    │   ├── api.dart
    │   └── screens/{login,rooms,chat}.dart
    └── pubspec.yaml
```

## 1. Бэкенд

### Установка
```bash
cd backend
npm install
npx wrangler login
```

### Создание D1
D1 база `kirca-api` уже создана; `database_id` зашит в `wrangler.toml`. Если будешь поднимать на своём аккаунте — пересоздай:
```bash
npx wrangler d1 create kirca-api
```
и подставь новый `database_id` в `wrangler.toml`.

### Миграции
```bash
# для локальной разработки:
npm run db:migrate:local
# когда будешь деплоить:
npm run db:migrate:remote
```

### Локальный запуск
```bash
npm run dev
# слушает на http://127.0.0.1:8787
```

Быстрая проверка:
```bash
curl -X POST http://127.0.0.1:8787/register \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","password":"qwerty"}'
```

### Деплой
```bash
npm run deploy
```
Получишь URL вида `https://kirca-api.<твой-аккаунт>.workers.dev`.

## 2. Flutter

### Установка
```bash
cd flutter_app
flutter create .            # сгенерирует ios/, android/, и т.д.
flutter pub get
```

### Настройка адреса бэкенда
По умолчанию (в `lib/config.dart`) клиент идёт на прод-воркер `https://kirca-api.gdetemka.workers.dev`. Переопределяется на сборке через `--dart-define`:
```bash
# локальный wrangler (iOS-симулятор):
flutter run --dart-define=KIRCA_API_BASE=http://127.0.0.1:8787

# реальный iPhone в той же сети:
flutter run --dart-define=KIRCA_API_BASE=http://192.168.1.10:8787

# отдельный прод/staging:
flutter build ios --dart-define=KIRCA_API_BASE=https://kirca-api.<other>.workers.dev
```
`wsBase` подставится автоматически (`http://` → `ws://`, `https://` → `wss://`). Codemagic уже прокидывает прод-URL — для тестового билда менять ничего не нужно.

### iOS-specific
1. Открой `ios/Runner.xcworkspace` в Xcode.
2. Поставь Team (Signing & Capabilities) — нужен Apple ID.
3. Для подключения по HTTP/WS (локальная разработка) добавь в `ios/Runner/Info.plist`:
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```
В проде уже будет `https`/`wss` — это не понадобится.

4. `flutter_secure_storage` на iOS работает без доп. настроек, но в Xcode для прода включи Keychain Sharing если потребуется.

### Запуск
```bash
flutter run                 # выберет первый доступный девайс
# или
open -a Simulator           # запусти симулятор сначала
flutter run -d "iPhone 15"
```

## 3. Что внутри происходит

**Регистрация/логин** → пароль хешится `scrypt` (формат `s1:<salt>:<hash>`), токен в `sessions` (D1) с `expires_at = now + 30 дней`, клиент кладёт в `flutter_secure_storage`. Старые SHA-256 хеши автоматически перехешируются в scrypt на следующем успешном логине.

**Открытие чата:**
1. `GET /rooms/:id/history` — последние 50 сообщений из D1.
2. WebSocket на `/rooms/:id/ws?token=...` → Worker проверяет токен + membership → форвардит в Durable Object (`ROOM.idFromName(roomId)`).
3. DO принимает соединение через `acceptWebSocket` (Hibernation API).

**Отправка (at-least-once + dedup):** клиент генерит `client_id` (UUID v4) и шлёт `{type:"msg", client_id, text}`. DO дедупит по `UNIQUE(room_id, client_id)`, пишет в D1 и рассылает `{type:"msg", id, client_id, ...}`. Клиент по `client_id` находит pending и помечает доставленным.

**Реконнект:** при разрыве WS клиент делает backoff `1 → 2 → 4 → 8 → 16 → 30c`. На реконнекте — `GET /rooms/:id/history?after=<last_seen_at>` подбирает пропущенное, потом WS открывается заново и переотправляются все pending.

**Комнаты:** при создании указывается `is_public`. Публичные видны всем, в приватные пускают только участников (`memberships`). Создатель автоматически становится owner. В публичную можно вступить через `POST /rooms/:id/join`.

## 4. Эксплуатация

- `GET /` — минималистичный лендинг со ссылками на доку и репо.
- `GET /docs` — интерактивный API reference (Scalar UI, читает `/openapi.json`).
- `GET /openapi.json` — OpenAPI 3.1 спека (источник правды; правится в `backend/src/openapi.ts`).
- `GET /healthz` — публичный health-check для UptimeRobot/cron. Возвращает `{ok:true, t}`.
- **Logout:** `POST /logout` с Bearer-токеном — удаляет конкретно эту сессию. Клиент чистит локал.
- **Смена пароля:** `POST /change-password {old_password, new_password}` — обновляет хеш и **отзывает все остальные сессии** этого юзера.
- **Rate limiting:** регистрация/логин лимитятся per-IP (`CF-Connecting-IP`), fixed-window 1 час. WS-отправка лимитится per-user в DO (10 сообщений / 5 сек).
- **Push (APNs).** Бэкенд шлёт нативно через Web Crypto. Настройка ключей — см. `DEPLOY.md` → APNs.
- **Staging:** отдельный воркер `kirca-api-staging` из ветки `dev`. Подробности в `DEPLOY.md`.

## 5. Что ещё стоит сделать (TODO)

Дальнейшие улучшения — см. [`ROADMAP.md`](./ROADMAP.md). Кратко то, что ближе всего:
- **JWT вместо сессий в D1.** Уберёт лишний select на каждом запросе (опционально — текущая нагрузка терпит).
- **REST-fallback на отправку:** `POST /rooms/:id/messages`. Когда WS не поднимается — клиент шлёт через HTTP, чат остаётся живым; полезно ещё и для дебага.
- **Observability.** Logpush в R2 или внешний сервис + структурированные `console.error` с request ID.
- **E2E-шифрование.** Серьёзная переделка (X3DH/Sender Keys); отложено.

## 6. Лимиты Cloudflare (актуально на момент написания)

- **Workers Free:** 100k запросов в день, 10 мс CPU/запрос.
- **Durable Objects:** требуют Workers Paid ($5/мес минимум).
- **D1:** на free-плане есть, лимиты щедрые для чата.
- **WebSocket Hibernation:** не считается активным временем, пока сокет молчит — отдельная экономия.
