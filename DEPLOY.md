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

## Flutter (iOS) — Codemagic → unsigned IPA → GitHub Releases → Scarlet

Конфиг в `codemagic.yaml` (в корне репы).

**Никакого Apple Developer аккаунта не нужно.** IPA собирается без подписи и публикуется как GitHub Release. Тестеры ставят через [Scarlet](https://usescarlet.com): добавляют URL `scarlet-source.json` → видят kirca → жмут Install. Scarlet сам подписывает у себя на устройстве.

⚠️ Сертификаты Scarlet регулярно отзывает Apple (раз в 1–4 недели). Апка временно перестаёт открываться, пока Scarlet не подменит новый. Норм для тестирования, не для прода.

### Build шаги (по порядку)

1. `flutter create --org ai.kirca --platforms=ios,android .` — генерит `ios/`/`android/` (не коммитим).
2. sed-патч bundle id `ai.kirca.kirca` → `ai.kirca.app`.
3. `flutter pub get`.
4. `flutter build ios --release --no-codesign` с `--build-number=$BUILD_NUMBER`.
5. Zip `Runner.app` в `kirca.ipa`.
6. Генерация `scarlet-source.json` с текущей версией и стабильным URL `releases/latest/download/...`.
7. Codemagic создаёт GitHub Release с тегом `build-<N>` и прикладывает оба файла.

### Что настроить один раз

**Codemagic:**
1. App settings → **Build configuration** → переключи на **codemagic.yaml**.
2. User settings → Integrations → **GitHub** — должен быть подключён (обычно автоматом при connect repo через OAuth).
   - Если нет: создай GitHub PAT с правом `repo`, положи в env var `GITHUB_TOKEN` (App settings → Environment variables, mark Secure).
3. Push в `main` → билд → новый Release появится в `github.com/skyfet/kirca/releases`.

### Стабильные ссылки после первого билда

```
IPA:          https://github.com/skyfet/kirca/releases/latest/download/kirca.ipa
Scarlet repo: https://github.com/skyfet/kirca/releases/latest/download/scarlet-source.json
```

«latest» автоматически указывает на последний релиз, так что URL **не меняется** между билдами — Scarlet сам подтянет новую версию.

### Установка на iPhone (тестер)

1. Поставить Scarlet (см. [usescarlet.com](https://usescarlet.com)).
2. В Scarlet: Settings → Sources → Add → вставь `https://github.com/skyfet/kirca/releases/latest/download/scarlet-source.json`.
3. Apps tab → kirca → Get.
4. После каждого push в `main` Scarlet увидит новую версию автоматом.

## Альтернатива для Flutter: GitHub Actions + Fastlane

Если не хочешь ещё один сервис, можно через GH Actions с `fastlane` и macOS-раннером. Дольше настраивать (cert/profile через Match), но всё в одном GitHub.

Дай знать — соберу.
