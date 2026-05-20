// Scalar API Reference, standalone via CDN. Renders /openapi.json.
// No npm dependency: the script is fetched by the browser from jsdelivr,
// so the worker bundle stays small.

export const docsHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>kirca · API reference</title>
</head>
<body>
  <script id="api-reference" data-url="/openapi.json"></script>
  <script>
    var cfg = { theme: "default", layout: "modern", hideDownloadButton: false };
    document.getElementById("api-reference").dataset.configuration = JSON.stringify(cfg);
  </script>
  <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
</body>
</html>
`;
