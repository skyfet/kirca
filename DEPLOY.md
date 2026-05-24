# Deploy

## Backend (Cloudflare Worker) — автодеплой через GitHub Actions

Workflow в `.github/workflows/backend.yml` срабатывает на push в `main`, когда меняется что-то в `backend/`.

### Что настроить в GitHub один раз

1. **Secrets** (Settings → Secrets and variables → Actions):
   - `CLOUDFLARE_API_TOKEN` — создай в Cloudflare Dashboard → My Profile → API Tokens → Create Token.
     Используй шаблон **Edit Cloudflare Workers**, либо custom с правами:
     - Account → Workers Scripts → Edit
     - Account → D1 → Edit
     - Account → Workers KV Storage → Edit (если будешь добавлять)
   - `CLOUDFLARE_ACCOUNT_ID` — в Dashboard на главной странице справа.

2. **D1 уже создана.** В `wrangler.toml` стоит правильный `database_id`. Workflow при деплое автоматически применяет миграции на remote.

3. **Первый деплой можешь сделать руками** (`npm run deploy`), чтобы убедиться, что воркер на твоём аккаунте появился. Дальше CI сам поднимает.

### Что произойдёт на push

```
push → checkout → npm ci → tsc --noEmit → npm test → wrangler d1 migrations apply → wrangler deploy → newman e2e (prod)
```

`npm test` гонит юнит-тесты (vitest-pool-workers поднимает воркер в miniflare). Падают — деплой отменяется.
Если `tsc` падает — деплой не пройдёт. Если миграция конфликтует — увидишь в логах GH.

### Staging

Отдельный воркер `kirca-api-staging` деплоится из ветки `dev` (workflow `backend-staging.yml`).
Перед первым запуском нужно один раз руками:

```bash
cd backend
npx wrangler d1 create kirca-api-staging
# Вставь полученный database_id в [[env.staging.d1_databases]] в wrangler.toml.
npm run db:migrate:staging
npm run deploy:staging
```

После этого push в `dev` будет автоматически выкатывать staging.

Flutter-билд для staging — отдельным dart-define:

```bash
flutter build ios --release --no-codesign \
  --dart-define=KIRCA_API_BASE=https://kirca-api-staging.<acc>.workers.dev
```

### Push (APNs)

Бэкенд шлёт APNs напрямую через Web Crypto. Никакого Firebase не нужно.

Один раз настроить:

1. **Apple Developer Portal → Keys → +**. Создай ключ с `Apple Push Notifications service (APNs)`. Скачай `.p8`.
2. Запомни `Key ID` (10 символов) и `Team ID` (10 символов из правого верхнего угла портала).
3. В `backend/wrangler.toml` `[vars]` подставь:
   ```toml
   APNS_TEAM_ID = "..."
   APNS_KEY_ID  = "..."
   APNS_BUNDLE_ID = "ai.kirca.app"
   ```
4. Положи `.p8` как секрет:
   ```bash
   cat AuthKey_XXXX.p8 | npx wrangler secret put APNS_KEY
   # для staging:
   cat AuthKey_XXXX.p8 | npx wrangler secret put APNS_KEY --env staging
   ```
5. Передеплой воркер. С этого момента сообщения в комнате триггерят push offline-юзерам.

Если значения пустые — воркер тихо пропускает push (никаких 500), удобно для локалки.

⚠️ **Не-Apple-Dev подпись и APNs.** Если IPA устанавливается через сторонний sideload-инструмент со своим профилем (не Apple Dev), push **может не работать** — это известный риск. Если упрётся: бэкенд продолжит работать без пушей; в `wrangler.toml` можно переключить `APNS_HOST` на `api.sandbox.push.apple.com` и попробовать. Гарантия push'а — настоящий Apple Developer-аккаунт.

## Flutter (iOS) — Codemagic → unsigned IPA → GitHub Releases

Конфиг в `codemagic.yaml` (в корне репы).

**Никакого Apple Developer аккаунта не нужно для CI.** IPA собирается без подписи и публикуется как GitHub Release. Тестеры скачивают `kirca.ipa` и ставят любым удобным sideload-инструментом (например, AltStore / Sideloadly) — он подписывает приложение своим профилем на устройстве.

### Build шаги (по порядку)

1. `flutter create --org ai.kirca --platforms=ios,android .` — генерит `ios/`/`android/` (не коммитим).
2. sed-патч bundle id `ai.kirca.kirca` → `ai.kirca.app`.
3. `flutter pub get`.
4. `flutter build ios --release --no-codesign` с `--build-number=$BUILD_NUMBER`.
5. Zip `Runner.app` в `kirca.ipa`.
6. Codemagic создаёт GitHub Release с тегом `build-<N>` и прикладывает `kirca.ipa`.

### Что настроить один раз

**Codemagic:**
1. App settings → **Build configuration** → переключи на **codemagic.yaml**.
2. User settings → Integrations → **GitHub** — должен быть подключён (обычно автоматом при connect repo через OAuth).
   - Если нет: создай GitHub PAT с правом `repo`, положи в env var `GITHUB_TOKEN` (App settings → Environment variables, mark Secure).
3. Push в `main` → билд → новый Release появится в `github.com/skyfet/kirca/releases`.

### Стабильная ссылка после первого билда

```
IPA: https://github.com/skyfet/kirca/releases/latest/download/kirca.ipa
```

«latest» автоматически указывает на последний релиз, так что URL **не меняется** между билдами.

### Установка на iPhone (тестер)

1. Скачать `kirca.ipa` с GitHub Releases (ссылка выше).
2. Установить через любой sideload-инструмент с компьютера или iPhone.
3. Запустить kirca.

## Альтернатива для Flutter: GitHub Actions + Fastlane

Если не хочешь ещё один сервис, можно через GH Actions с `fastlane` и macOS-раннером. Дольше настраивать (cert/profile через Match), но всё в одном GitHub.

Дай знать — соберу.
