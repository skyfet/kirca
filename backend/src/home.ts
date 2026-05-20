// Minimal landing page for the API root. Pure HTML, no JS.
// Kept inline so it ships in the worker bundle without a separate asset.

export const homeHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>kirca</title>
  <meta name="description" content="kirca — simple chat backend on Cloudflare Workers.">
  <style>
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; }
    body {
      font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
      max-width: 36rem;
      margin: 0 auto;
      padding: 4rem 1.25rem 6rem;
      color: #111;
      background: #fafafa;
    }
    @media (prefers-color-scheme: dark) {
      body { color: #ddd; background: #0f0f10; }
      a { color: #8ab4f8; }
      code { background: #1e1e20; }
    }
    h1 { font-size: 1.6rem; margin: 0 0 .25rem; font-weight: 600; letter-spacing: -.01em; }
    p.tag { color: #666; margin: 0 0 2rem; }
    ul { padding-left: 1.1rem; }
    li { margin: .35rem 0; }
    code {
      background: #f0f0f0;
      padding: 1px 5px;
      border-radius: 3px;
      font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .stack { color: #888; font-size: 13px; margin-top: 2rem; }
  </style>
</head>
<body>
  <h1>kirca</h1>
  <p class="tag">Simple chat. Cloudflare Worker backend + Flutter iOS client.</p>

  <ul>
    <li><a href="/docs">API reference</a> — interactive docs (Scalar)</li>
    <li><a href="/openapi.json">openapi.json</a> — OpenAPI 3.1 spec</li>
    <li><a href="/healthz">/healthz</a> — health check</li>
    <li><a href="https://github.com/skyfet/kirca">github.com/skyfet/kirca</a> — source &amp; README</li>
  </ul>

  <p class="stack">Stack: Hono on Cloudflare Workers, D1 for storage, Durable Objects for live rooms, WebSockets with Hibernation, APNs for push.</p>
</body>
</html>
`;
