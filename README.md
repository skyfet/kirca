# kirca

Простой чат: Cloudflare Worker + Durable Objects + D1 для бэкенда, Flutter — для iOS-клиента.

См. также `DEPLOY.md` (CI/CD) и `ROADMAP.md` (что улучшать дальше).

```
kirca/
├── backend/           # Cloudflare Worker (TypeScript, Hono) — деплоится как `kirca-api`
│   ├── src/
│   │   ├── index.ts   # HTTP API + WS upgrade
│   │   └── room.ts    # Durable Object (одна на комнату)
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
Открой `lib/config.dart`:
- **iOS симулятор + локальный wrangler:** оставь `127.0.0.1:8787`.
- **Реальный iPhone в той же сети:** замени на IP мака (`ifconfig | grep inet`), например `192.168.1.10:8787`.
- **Продакшен:** `https://...workers.dev` для `apiBase`, `wss://...workers.dev` для `wsBase`.

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

**Регистрация/логин** → токен в `sessions` (D1) → клиент кладёт в `flutter_secure_storage`.

**Открытие чата:**
1. `GET /rooms/:id/history` — последние 50 сообщений из D1.
2. WebSocket на `/rooms/:id/ws?token=...` → Worker валидирует токен → форвардит в Durable Object (`ROOM.idFromName(roomId)`).
3. DO принимает соединение через `acceptWebSocket` (Hibernation API).

**Отправка:** клиент шлёт `{type:"msg", text:"..."}` → DO пишет в D1 → рассылает всем подключённым к этой комнате.

## 4. Что ещё стоит сделать (TODO)

Сразу видимые улучшения, когда базовая версия заведётся:
- **Bcrypt вместо SHA-256.** Сейчас стоит SHA-256 без соли — для прода нужен bcrypt/argon2. На Workers есть `@noble/hashes`.
- **JWT вместо сессий в D1.** Уберёт лишний select на каждом запросе.
- **Membership.** Сейчас все комнаты публичные, любой залогиненный может войти. Добавь таблицу `memberships(user_id, room_id)` и проверяй.
- **Typing indicators / read receipts.** Отдельные типы сообщений по WS, без записи в D1.
- **Реконнект на клиенте.** Сейчас при разрыве WS статус-бар идёт серым, но автореконнекта нет.
- **Пагинация истории.** Сейчас тупо последние 50.
- **Push (APNs).** Отдельный сервис, например через очередь Cloudflare Queues → внешний воркер с APNs-провайдером.

## 5. Лимиты Cloudflare (актуально на момент написания)

- **Workers Free:** 100k запросов в день, 10 мс CPU/запрос.
- **Durable Objects:** требуют Workers Paid ($5/мес минимум).
- **D1:** на free-плане есть, лимиты щедрые для чата.
- **WebSocket Hibernation:** не считается активным временем, пока сокет молчит — отдельная экономия.
