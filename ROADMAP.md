# Roadmap & Architecture

Что улучшать после первого работающего деплоя. Большая часть P0–P2 уже в коде — ниже только то, что осталось, и архитектурные принципы, которые продолжают действовать.

## Шипнуто

P0 (доставка с `client_id` + `UNIQUE(room_id, client_id)`, реконнект с backoff `1→2→4→8→16→30c` и догон через `?after=`, scrypt-пароли с `s1:<salt>:<hash>` + автоапгрейд старых SHA-256, membership/приватные комнаты), P1 (нативный APNs через Web Crypto, rate limiting per-IP + per-user, пагинация `?before=`, typing-индикаторы) и P2 в части вложений (R2 + `/uploads`) и read-receipts (`markRead`, `last_read_at`). Бэкенд разложен по `routes/auth.ts`, `routes/rooms.ts`, `routes/messages.ts`, `routes/profile.ts`, `routes/ws.ts`, `routes/devices.ts`, `routes/uploads.ts`. Юнит-тесты на vitest-pool-workers — в `backend/test/unit/`. Staging-воркер `kirca-api-staging` поднимается из ветки `dev`.

## Что осталось

### JWT вместо сессий в D1
Сейчас на каждый запрос — `SELECT` из `sessions` для валидации токена. С ростом QPS это лишний раунд-трип. Альтернатива: подписанный JWT с `exp`, ротация через короткий TTL + refresh. Минус — нет «убить сессию мгновенно» (только blacklist в KV/D1, что возвращает тот же select). Делать, если профилирование покажет, что сейчас этот select — горлышко. Пока — не критично.

### REST-fallback на отправку: `POST /rooms/:id/messages`
Если WS не поднимается (корпоративный прокси, фон iOS), чат подвисает на отправке. Эндпоинт принимает то же тело, что и `{type:"msg"}` через WS, и идёт через тот же DO. Удобно ещё и для дебага из `curl`. Минимум кода, ощутимая надёжность.

### Observability
- `Logpush` в R2 (или внешний сервис) для прод-логов глубже встроенных 30 дней.
- Структурированный `console.error({reqId, route, code})` — Cloudflare сам тегирует request ID.
- Tail Workers (`wrangler tail`) для лайв-дебага — не настройка, привычка.

### E2E-шифрование
Серьёзная переделка. Сервер становится «глупым» — хранит только зашифрованные блоки. Ключи у клиентов, обмен через X3DH (Signal Protocol), Sender Keys для групповых комнат. Делать, только если приватность — основное value-предложение; ломает edit/server-side search/uploaded thumbnails.

## Архитектурные принципы

Несколько вещей, которые лучше заложить с самого начала — переписывать потом дороже.

### Единственный источник истины
- **D1** — долгое хранение. Что записано в D1 — то и есть правда.
- **DO** — онлайн-состояние (кто подключён, чьи typing-индикаторы активны). При рестарте теряется без последствий.
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
    rooms.ts       # CRUD комнат, join
    messages.ts    # история, edit/delete, read-receipts
    profile.ts     # /me, avatar, delete-account
    ws.ts          # WS upgrade → DO
    devices.ts     # APNs token registration
    uploads.ts     # R2 presigned upload
  room.ts          # Durable Object
  lib/auth.ts      # scrypt, token verify
```
Когда роут вырастает за пару сотен строк — выноси в отдельный файл рядом с остальными.

### Тесты
`vitest` + `@cloudflare/vitest-pool-workers` гоняет Worker в нативной среде с реальной D1 (in-memory). Покрытие в `backend/test/unit/`: auth-flow, dedup сообщений, `user_hub` (DO-presence), общие HTTP-эндпоинты. E2E поверх — Newman против локального wrangler в `test/kirca-api.postman_collection.json`. Любая новая фича шипится с минимальным тестом — это окупается с первого же рефакторинга.

### Конфиг и env per stage
Два воркера: `kirca-api` (prod) и `kirca-api-staging`. Конфигурируются через `[env.staging]` / `[env.production]` в `wrangler.toml`. CI деплоит staging на push в `dev`, prod — на push в `main` (см. `.github/workflows/backend-*.yml`).

