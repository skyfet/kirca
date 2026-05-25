# Roadmap & Architecture

Что улучшать после первого работающего деплоя. Большая часть P0–P2 уже в коде — ниже только то, что осталось, и архитектурные принципы, которые продолжают действовать.

## Шипнуто

- **P0 — надёжная доставка.** `client_id` + `UNIQUE(room_id, client_id)` для дедупа, реконнект с backoff `1→2→4→8→16→30c`, догон пропущенного через `GET /rooms/:id/history?after=`. Пароли — scrypt `s1:<salt>:<hash>` (N=2^14) с автоапгрейдом старых SHA-256 на следующем успешном логине. Membership / приватные комнаты, owner-роль создателя, `POST /rooms/:id/join` для публичных.
- **P1 — UX и защита.** Нативный APNs через Web Crypto (ES256 без Firebase), rate limiting per-IP (1ч fixed-window) и per-user в DO (10 msg / 5 сек), пагинация `?before=`, typing-индикаторы через WS, mute комнаты per-user.
- **P2 — медиа и read-state.** Вложения через R2 (`POST /uploads`, blob-URL), read-receipts (`markRead`, `last_read_at`, `unread`-каунтер на тайле комнаты), edit/delete сообщений с историей правок.
- **E2E.** Identity на клиенте (X25519, ключ обёрнут recovery-key из 24-словной фразы, derived через PBKDF2-SHA512), per-room AES-256 ключ, sealing room key для каждого участника через Curve25519 sealed box. Сервер хранит только шифротекст сообщений и аттачментов, фразу никогда не видит. На новом устройстве — `IdentityStatus.needsRestore` → ввод 24 слов в `RecoveryRestoreScreen` → unwrap приватника. Серверные роуты в `backend/src/routes/e2e.ts`, клиентская крипта в `flutter_app/lib/crypto/`.
- **Архитектура.** Бэкенд разложен по `routes/auth.ts`, `routes/rooms.ts`, `routes/messages.ts`, `routes/profile.ts`, `routes/ws.ts`, `routes/devices.ts`, `routes/uploads.ts`, `routes/e2e.ts`. Юнит-тесты на vitest-pool-workers — в `backend/test/unit/` (auth, dedup, http, user_hub, e2e, e2e_ws, e2e_uploads). E2E поверх — Newman против локального wrangler в `test/kirca-api.postman_collection.json`. Staging-воркер `kirca-api-staging` поднимается из ветки `dev`.
- **Клиент.** Glass-UI на `liquid_glass_widgets`, SQLite-кеш комнат / сообщений / приглашений, per-user WS для онлайн-статуса и счётчика непрочитанных, golden-тесты на тайлы комнат.

## Что осталось

### JWT вместо сессий в D1
Сейчас на каждый запрос — `SELECT` из `sessions` для валидации токена. С ростом QPS это лишний раунд-трип. Альтернатива: подписанный JWT с `exp`, ротация через короткий TTL + refresh. Минус — нет «убить сессию мгновенно» (только blacklist в KV/D1, что возвращает тот же select). Делать, если профилирование покажет, что сейчас этот select — горлышко. Пока — не критично.

### REST-fallback на отправку: `POST /rooms/:id/messages`
Если WS не поднимается (корпоративный прокси, фон iOS), чат подвисает на отправке. Эндпоинт принимает то же тело, что и `{type:"msg"}` через WS, и идёт через тот же DO. Удобно ещё и для дебага из `curl`. Минимум кода, ощутимая надёжность.

### Observability
- `Logpush` в R2 (или внешний сервис) для прод-логов глубже встроенных 30 дней.
- Структурированный `console.error({reqId, route, code})` — Cloudflare сам тегирует request ID.
- Tail Workers (`wrangler tail`) для лайв-дебага — не настройка, привычка.

### Android-клиент
Сейчас Codemagic собирает только iOS. Android-сборка идёт `flutter build apk` локально, в CI её нет. Для публичного запуска на Android — добавить отдельный workflow + signing-конфиг + публикация APK в Releases.

### Расширения E2E
Базовый протокол достаточен для группового чата, но не даёт forward secrecy на уровне сообщения. Если важно — направление: Signal Sender Keys (per-sender ratchet) + периодическая ротация room key при изменении состава участников. Сейчас ротация ключа есть только при `key_version` bump (вручную); автоматический rotate-on-remove — отдельная задача.

## Архитектурные принципы

Несколько вещей, которые лучше заложить с самого начала — переписывать потом дороже.

### Единственный источник истины
- **D1** — долгое хранение. Что записано в D1 — то и есть правда.
- **DO** — онлайн-состояние (кто подключён, чьи typing-индикаторы активны, online-флаг в `USER_HUB`). При рестарте теряется без последствий.
- Никогда не дублировать. DO не «кеширует» сообщения — оно пишет в D1 и сразу рассылает, не помня после рассылки.

### Идемпотентность всего, что меняет состояние
Каждая операция от клиента, которая что-то создаёт, должна иметь `client_id`. Серверный сторона: `INSERT OR IGNORE` или `UNIQUE` + поймать конфликт. Это даёт безопасные ретраи без дублей.

### API версионирование
Сейчас `/register`, потом `/v1/register`. Когда сломаешь формат — `/v2/register`, старые клиенты живут.

В Hono это просто:
```ts
const v1 = new Hono<{ Bindings: Env }>();
v1.post('/register', ...);
app.route('/v1', v1);
```

### Schema migrations — только аддитивно
Никогда не удаляй колонку в той же миграции, где код перестаёт её писать. Цикл:
1. Миграция: добавить новую колонку (опциональную).
2. Релиз: код пишет в новую И старую.
3. Миграция: бэкфилл старых строк.
4. Релиз: код читает только из новой.
5. Миграция: удалить старую.

Иначе при rollback или старый клиент → опа.

### Graceful degradation
Если WS не подключился — приложение не должно быть мёртвым. История через REST доступна. Отправка может работать через `POST /rooms/:id/messages` как fallback (добавь такой эндпоинт). Это полезно ещё и для дебага.

### Слои в Worker
`index.ts` — только композиция: middleware + `app.route()` на под-роутеры. Бизнес-логика живёт в:
```
src/
  routes/
    auth.ts        # register/login/logout/change-password
    rooms.ts       # CRUD комнат, join, invites, mute
    messages.ts    # история, edit/delete, read-receipts
    profile.ts     # /me, avatar, delete-account, logout-all
    ws.ts          # WS upgrade → Room DO
    devices.ts     # APNs token registration
    uploads.ts     # R2 presigned upload
    e2e.ts         # identity bundle, room keys (sealed)
  room.ts          # Durable Object одной комнаты
  user_hub.ts     # Durable Object одного пользователя (online + fan-out)
  lib/
    auth.ts        # scrypt, token verify
    apns.ts        # ES256 JWT, request к api.push.apple.com
    rate_limit.ts  # fixed-window
    openapi.ts     # createApp/createRoute/jsonContent
    schemas.ts     # zod-схемы запросов/ответов
    middleware.ts  # auth guard, request id, CORS
```
Когда роут вырастает за пару сотен строк — выноси в отдельный файл рядом с остальными.

### Тесты
`vitest` + `@cloudflare/vitest-pool-workers` гоняет Worker в нативной среде с реальной D1 (in-memory). Покрытие в `backend/test/unit/`: auth-flow, dedup сообщений, `user_hub` (DO-presence), общие HTTP-эндпоинты, E2E identity + sealed room keys, E2E через WS, шифрованные аттачменты. E2E поверх — Newman против локального wrangler в `test/kirca-api.postman_collection.json`. Любая новая фича шипится с минимальным тестом — это окупается с первого же рефакторинга.

### Конфиг и env per stage
Два воркера: `kirca-api` (prod) и `kirca-api-staging`. Конфигурируются через `[env.staging]` / `[env.production]` в `wrangler.toml`. CI деплоит staging на push в `dev`, prod — на push в `main` (см. `.github/workflows/backend-*.yml`).
