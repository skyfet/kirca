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
push → checkout → npm ci → tsc --noEmit → wrangler d1 migrations apply → wrangler deploy
```

Если `tsc` падает — деплой не пройдёт. Если миграция конфликтует — увидишь в логах GH.

## Flutter (iOS → TestFlight) — Codemagic

Конфиг в `flutter_app/codemagic.yaml`.

### Что настроить

1. Apple Developer аккаунт ($99/год).
2. В App Store Connect создай приложение с твоим `BUNDLE_ID`.
3. На codemagic.io:
   - Подключи репозиторий.
   - Teams → Integrations → App Store Connect — добавь Issuer ID, Key ID, скачанный .p8.
   - Group `app_store_credentials` со всеми `APP_STORE_CONNECT_*`.
4. Поменяй `BUNDLE_ID` в `codemagic.yaml`.
5. Первый push в `main` → автоматически загрузится в TestFlight.

Тестеры получают ссылку, ставят TestFlight приложение, тестируют.

## Альтернатива для Flutter: GitHub Actions + Fastlane

Если не хочешь ещё один сервис, можно через GH Actions с `fastlane` и macOS-раннером. Дольше настраивать (cert/profile через Match), но всё в одном GitHub.

Дай знать — соберу.
