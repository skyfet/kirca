# Launch — публичный запуск kirca

Этот документ — пошаговый чек-лист от «всё в репе» до «можно давать ссылку друзьям».
Делал из расчёта, что у тебя уже есть Cloudflare-аккаунт, Apple ID (для APNs опционально) и Codemagic.

Параллельно держи открытыми `README.md` (как это вообще устроено) и `DEPLOY.md` (CI/CD-детали). `ROADMAP.md` — что улучшать после запуска, не до.

Каждый шаг помечен: **(один раз)** — выполняешь ровно один раз на проект, **(повторяемо)** — может понадобиться снова при ротации/смене окружения.

---

## 0. Pre-flight: что должно быть на руках

- [ ] Аккаунт Cloudflare с подключённым **Workers Paid** ($5/мес) — без этого Durable Objects не работают.
- [ ] Репозиторий `skyfet/kirca` с правом push.
- [ ] Аккаунт **Codemagic** с подключённой репой (или GitHub Actions + mac-runner, но в этой репе настроен Codemagic).
- [ ] (опционально) Аккаунт **Apple Developer** для настоящих APNs-ключей. Без него push на устройствах с нестандартной подписью **может молча не работать** — это известный риск, см. `DEPLOY.md`.
- [ ] (опционально) **UptimeRobot** / cron-monitor для `/healthz`.

Ничего из этого пока не настраиваем — просто убеждаемся, что доступ есть.

---

## 1. Backend (production) — поднять воркер

### 1.1. Cloudflare API token и Account ID **(один раз)**

1. Cloudflare Dashboard → My Profile → API Tokens → **Create Token** → шаблон **Edit Cloudflare Workers** (либо custom: Workers Scripts Edit + D1 Edit).
2. Скопируй `Account ID` с главной страницы Dashboard (правая колонка).
3. Положи оба в GitHub → repo Settings → Secrets and variables → Actions:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`

**Проверка:** на следующем push в `main` workflow `Deploy Backend` стартует и не падает на шаге `wrangler deploy`.

### 1.2. D1-база `kirca-api`

База **уже создана** (см. `backend/wrangler.toml`, `database_id = 10d22275-...`). Это аккаунт `archen`. Если ты раскатываешь под своим аккаунтом — пересоздай:

```bash
cd backend
npx wrangler d1 create kirca-api
# подставь database_id из вывода в [[d1_databases]] в wrangler.toml
```

### 1.3. Первый ручной деплой **(один раз)**

CI деплоит автоматически, но первый раз полезно прогнать вручную — увидишь URL воркера и поймёшь, что cred'ы работают:

```bash
cd backend
npm ci
npx wrangler login          # OAuth-флоу в браузере
npm run db:migrate:remote   # применить миграции
npm run deploy
```

В выводе будет:
```
https://kirca-api.<твой-аккаунт>.workers.dev
```

**Проверка:**
```bash
curl https://kirca-api.<acc>.workers.dev/healthz
# {"ok":true,"t":1747...}
```

### 1.4. Прибить URL воркера в клиенте и тестах **(один раз)**

Если URL отличается от `https://kirca-api.archen.workers.dev`, обнови:

- `codemagic.yaml` → `vars.KIRCA_API_BASE`
- `backend/test/kirca-api.postman_environment.json` → `baseUrl`
- `flutter_app/lib/config.dart` → `defaultApiBase`

Закоммить отдельным PR (это конфиг, а не launch-фикс).

---

## 2. Backend (staging) — отдельный воркер для рискованных правок

### 2.1. Staging D1 — уже создана

В `wrangler.toml` под `[[env.staging.d1_databases]]` уже стоит реальный `database_id` (`b048752e-…`) для аккаунта `archen`. Если поднимаешь staging на своём аккаунте — пересоздай:

```bash
cd backend
npx wrangler d1 create kirca-api-staging
# подставь полученный database_id в [[env.staging.d1_databases]] в wrangler.toml.
npm run db:migrate:staging
npm run deploy:staging
```

**Проверка:**
```bash
curl https://kirca-api-staging.<acc>.workers.dev/healthz
```

После этого push в ветку `dev` будет автоматически выкатывать staging (workflow `backend-staging.yml`).

### 2.2. Branching workflow **(один раз)**

- Новые фичи → ветка `dev` → staging.
- Зелёный smoke в staging → merge `dev` → `main` → prod.
- Hotfix без staging — только если правда горит.

---

## 3. APNs (push) — опционально, но желательно до публичного запуска

Без этого backend жив, но пользователь не получит уведомление о новом сообщении, когда апа в фоне.

### 3.1. Создать APNs Auth Key **(один раз)**

1. Apple Developer Portal → Keys → **+** → выбрать `Apple Push Notifications service (APNs)` → Continue → Register.
2. Скачать `.p8` (показывают **один раз**, бэкап обязателен).
3. Запомнить `Key ID` (10 символов) и `Team ID` (правый верхний угол портала, 10 символов).

### 3.2. Прописать в `wrangler.toml` **(один раз)**

```toml
[vars]
APNS_TEAM_ID = "ABCD123456"
APNS_KEY_ID  = "WXYZ987654"
APNS_BUNDLE_ID = "ai.kirca.app"
APNS_HOST = "api.push.apple.com"
```

Сейчас оба ID **пустые** — без заполнения push молча отключается.

Для staging тот же ключ ок, но `APNS_HOST = "api.sandbox.push.apple.com"` (уже стоит).

### 3.3. Положить приватный ключ как secret **(повторяемо при ротации)**

```bash
cd backend
cat AuthKey_WXYZ987654.p8 | npx wrangler secret put APNS_KEY
cat AuthKey_WXYZ987654.p8 | npx wrangler secret put APNS_KEY --env staging
```

Redeploy:
```bash
npm run deploy && npm run deploy:staging
```

### 3.4. Проверка push

1. Сборка Flutter с реальным `aps-environment=production` (entitlements уже патчатся CI, см. `codemagic.yaml` → "Apply iOS patches").
2. На iPhone установи апку → залогинься → разреши push.
3. Со второго аккаунта отправь сообщение в общую комнату, когда первый в фоне.
4. Должен прилететь push.

⚠️ **Известное ограничение sideload-подписи**: подпись стороннего sideload-инструмента ≠ Apple Dev, и APNs может не отдать device token. Если push не работает — сначала собери через настоящий Apple Dev (TestFlight/Ad-hoc) и проверь там; если работает в TestFlight, но не при sideload — это ожидаемо, не баг бэкенда.

---

## 4. Flutter / iOS-клиент

### 4.1. Codemagic **(один раз)**

1. Codemagic → App settings → **Build configuration** → переключить на `codemagic.yaml`.
2. User settings → Integrations → **GitHub**:
   - Должен быть зелёный коннект (OAuth).
   - Если нет — создай GitHub PAT с правом `repo`, положи в App settings → Environment variables как `GITHUB_TOKEN` (Secure).

**Проверка:** dummy-commit в `main` → Codemagic стартует workflow `ios-unsigned` → через ~10 минут в `github.com/skyfet/kirca/releases` появляется `build-1` с `kirca.ipa`.

### 4.2. Стабильная ссылка для тестеров **(один раз)**

После первого успешного релиза тестерам отдаёшь прямой URL на IPA:
```
https://github.com/skyfet/kirca/releases/latest/download/kirca.ipa
```

Этот URL **стабилен** — `latest` сам указывает на свежий релиз. Тестеры скачивают и ставят любым удобным sideload-инструментом (AltStore / Sideloadly / etc).

### 4.3. Проверка установки

На чистом iPhone:
1. Скачать `kirca.ipa` по ссылке выше.
2. Установить через выбранный sideload-инструмент.
3. Открыть, зарегаться (показывается 24-словная recovery-фраза — пройти экран до конца), создать публичную комнату через FAB `+`, отправить сообщение.

---

## 5. Pre-launch smoke (минут 20)

Перед тем, как давать ссылку наружу — прогони всё руками. Багу легче поймать сейчас, чем в первые 10 минут после поста.

### 5.1. Backend smoke (curl)

```bash
BASE=https://kirca-api.<acc>.workers.dev
curl $BASE/healthz                                                                  # {"ok":true,...}
curl -sX POST $BASE/register -H 'Content-Type: application/json' \
  -d '{"username":"smoke1","password":"qwerty12"}' | jq                              # {token, user_id}
TOKEN=...
curl -sX POST $BASE/rooms -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"smoke","is_public":true}' | jq    # {id, ...}
ROOM=...
curl -s $BASE/rooms/$ROOM/history -H "Authorization: Bearer $TOKEN" | jq             # []
```

### 5.2. E2E Newman (то, что гоняет CI)

```bash
cd backend
npm run test:e2e
```

Должно всё зелёное. Если падает на rate-limit — подожди час или вытри `kv_ratelimit` / создай нового юзера (Newman так и делает — рандомизирует username per-run).

### 5.3. Клиентский smoke (золотой путь)

С двух iPhone (или iPhone + симулятор):
1. Регистрация двух разных юзеров.
2. Юзер A создаёт публичную комнату.
3. Юзер B заходит → `POST /rooms/:id/join`.
4. A отправляет сообщение → у B появилось мгновенно.
5. B выключает WiFi → A отправляет ещё → B включает WiFi → сообщение пришло (реконнект + `history?after=...`).
6. Закрыть апку у B → A пишет → B получает **push** (если APNs настроен).
7. Сменить пароль у B → все сессии B на других устройствах разлогинились.

### 5.4. Rate-limit sanity

```bash
for i in $(seq 1 12); do curl -sX POST $BASE/register -H 'Content-Type: application/json' \
  -d "{\"username\":\"rl$i$RANDOM\",\"password\":\"qwerty12\"}" | jq -c '.error // .user_id'; done
```

Последние пара запросов должны вернуть `429` / `{"error":"rate_limited"}`.

---

## 6. Observability **(один раз)**

### 6.1. Workers Logs

Cloudflare Dashboard → Workers & Pages → `kirca-api` → Logs → включить **Workers Logs** (до 30 дней встроенно, бесплатно).

Проверка: открой Logs, дёрни любой curl на воркер → запись должна появиться через ~5 секунд.

### 6.2. `/healthz` мониторинг

UptimeRobot (бесплатный план) → New Monitor → HTTP(s) → `https://kirca-api.<acc>.workers.dev/healthz` → интервал 5 минут → алерт в Telegram/email.

То же для staging — но в alert-policy отметить как low-priority, чтобы не будили ночью.

### 6.3. Алерт на бюджет

Cloudflare Dashboard → Billing → **Notifications** → включить alert на 80% Workers Paid лимита. Хотя бы будешь знать, если кто-то наспамил.

---

## 7. Безопасность перед публичным анонсом

- [ ] **Секреты в порядке.** `wrangler secret list` показывает `APNS_KEY` (если включён push). `.p8` не закоммичен.
- [ ] **`.gitignore` в порядке.** Бегло: `git ls-files | grep -E "\.(env|p8|pem|key)$"` — пусто.
- [ ] **CORS / Origin.** Сейчас API доступен с любого origin (Hono без CORS-restriction'ов). Если планируешь только iOS-клиента — норм; если веб — добавь allow-list позже.
- [ ] **scrypt active.** Старые SHA-256 хеши автоматически перехешируются при следующем логине — но если запускаешь на чистой базе, это и так не проблема.
- [ ] **Rate limit включён.** `backend/src/lib/rate_limit.ts` живой, в `index.ts` применяется к `/register`, `/login`. WS-rate-limit — в `room.ts` (10 msg / 5 сек на user).
- [ ] **Membership-чек.** Приватные комнаты доступны только участникам. Прогнать руками: создать private room юзером A → попытаться `GET /rooms/:id/history` юзером B → должен быть 403.

---

## 8. Запуск

1. Финальный merge `dev` → `main` (если работал в `dev`).
2. Дождаться зелёного `Deploy Backend` workflow + e2e Newman.
3. Дождаться Codemagic-релиза `build-N`.
4. На тестовом iPhone скачать новый `kirca.ipa`, переставить и прогнать smoke (раздел 5.3).
5. **Запостить ссылку** на IPA:
   ```
   https://github.com/skyfet/kirca/releases/latest/download/kirca.ipa
   ```

---

## 9. Первый день после запуска

- Каждый час смотреть Workers Logs на `ERROR`-уровень.
- UptimeRobot — должен быть «зелёным» (uptime > 99%).
- Если в логах ловятся 5xx — `console.error` уже тегирует request ID, ищи по нему в Tail Workers (`npx wrangler tail`).
- Бэкап D1 пока ручной: `npx wrangler d1 export kirca-api --output backup-$(date +%F).sql` — прогони хотя бы перед любой миграцией.

---

## 10. Что осталось «после запуска» (см. `ROADMAP.md`)

- JWT вместо `SELECT sessions` на каждый запрос (если профилирование покажет горлышко).
- REST-fallback на отправку (`POST /rooms/:id/messages`) когда WS не поднимается.
- Observability: Logpush в R2, структурированные `console.error` с request id.
- Android-клиент (Codemagic сейчас собирает только iOS).
- Forward secrecy в E2E (Sender Keys + автоматическая ротация room key при удалении участника).

Это **не блокеры** для публичного запуска — это уже фичи v1.1+. Typing-индикаторы, read-receipts, edit/delete, attachments в R2, infinite scroll и базовый E2E (включая 24-словную фразу восстановления) уже в коде.
