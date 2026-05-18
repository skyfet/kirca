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

## Flutter (iOS) — Codemagic → unsigned IPA → R2 → Scarlet

Конфиг в `codemagic.yaml` (в корне репы — Codemagic подхватывает оттуда автоматически).
`working_directory: flutter_app` внутри YAML.

**Никакого Apple Developer аккаунта не нужно.** IPA собирается без подписи и заливается в Cloudflare R2. Тестеры ставят через [Scarlet](https://usescarlet.com): добавляют URL репы → видят kirca → жмут Install. Scarlet сам подписывает у себя на устройстве.

⚠️ Сертификаты Scarlet регулярно отзывает Apple (раз в 1–4 недели). Тогда апка перестаёт открываться, пока Scarlet не подменит новый. Норм для тестирования с друзьями, не для прода.

### Build шаги (по порядку)

1. `flutter create --org ai.kirca --platforms=ios,android .` — генерит `ios/`/`android/` (не коммитим).
2. sed-патч bundle id `ai.kirca.kirca` → `ai.kirca.app`.
3. `flutter pub get`.
4. `flutter build ios --release --no-codesign` с `--build-number=$BUILD_NUMBER`.
5. Zip `Runner.app` в `kirca.ipa`.
6. Генерация `scarlet-source.json` с текущей версией.
7. Аплоад `kirca.ipa` + `scarlet-source.json` в R2 через aws CLI.

### Что настроить один раз

**Cloudflare:**
1. Dashboard → R2 Object Storage → **Enable R2** (бесплатно, 10GB).
2. Скажи Claude — он создаст бакет `kirca-releases`.
3. Bucket → Settings → **Public access** → enable **r2.dev subdomain**. Скопируй URL вида `https://pub-XXXXXX.r2.dev`.
4. R2 → **Manage R2 API Tokens** → Create API Token:
   - Permissions: **Object Read & Write**
   - Specify bucket: `kirca-releases`
   - Скопируй **Access Key ID** и **Secret Access Key** (показывают один раз).

**Codemagic:**
1. App settings → **Build configuration** → переключи на **codemagic.yaml** (если не переключено).
2. App settings → Environment variables → создай group `r2_credentials`:
   - `R2_ACCOUNT_ID = 940831dcf48b4eb3dfaf44fc48570f59`
   - `R2_BUCKET = kirca-releases`
   - `R2_ACCESS_KEY_ID = <из R2 API Token>`
   - `R2_SECRET_ACCESS_KEY = <из R2 API Token>` ✅ Secure
   - `R2_PUBLIC_BASE = https://pub-XXXXXX.r2.dev` (без / в конце)
3. Push в `main` → билд → в логах последним шагом увидишь:
   ```
   IPA:          https://pub-XXXX.r2.dev/kirca.ipa
   Scarlet repo: https://pub-XXXX.r2.dev/scarlet-source.json
   ```

### Установка на iPhone (тестер)

1. Поставить Scarlet (см. [usescarlet.com](https://usescarlet.com) — обычно через TrollStore или прямую установку с сайта).
2. В Scarlet: Settings → Sources → Add → вставь `https://pub-XXXX.r2.dev/scarlet-source.json`.
3. Apps tab → kirca → Get.
4. После каждого push в `main` SideStore/Scarlet увидит новую версию автоматом.

## Альтернатива для Flutter: GitHub Actions + Fastlane

Если не хочешь ещё один сервис, можно через GH Actions с `fastlane` и macOS-раннером. Дольше настраивать (cert/profile через Match), но всё в одном GitHub.

Дай знать — соберу.
