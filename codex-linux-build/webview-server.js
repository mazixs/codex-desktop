const http = require("http");
const fs = require("fs");
const path = require("path");

const port = Number.parseInt(process.env.CODEX_WEBVIEW_PORT || "5175", 10);
const webviewDir = path.resolve(__dirname, "webview");

const mimeTypes = {
  ".css": "text/css",
  ".html": "text/html",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "application/javascript",
  ".json": "application/json",
  ".mjs": "application/javascript",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ttf": "font/ttf",
  ".wav": "audio/wav",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

function sendFile(filePath, response) {
  const extension = path.extname(filePath).toLowerCase();
  const contentType = mimeTypes[extension] || "application/octet-stream";

  fs.readFile(filePath, (error, content) => {
    if (error) {
      response.writeHead(500);
      response.end("Internal Server Error");
      return;
    }

    response.writeHead(200, { "Content-Type": contentType });
    response.end(content);
  });
}

const server = http.createServer((request, response) => {
  const requestPath = decodeURIComponent((request.url || "/").split("?")[0]);
  const normalizedPath = requestPath === "/" ? "/index.html" : requestPath;
  const filePath = path.resolve(webviewDir, `.${normalizedPath}`);

  if (filePath !== webviewDir && !filePath.startsWith(`${webviewDir}${path.sep}`)) {
    response.writeHead(403);
    response.end("Forbidden");
    return;
  }

  fs.stat(filePath, (error, stats) => {
    if (!error && stats.isFile()) {
      sendFile(filePath, response);
      return;
    }

    sendFile(path.join(webviewDir, "index.html"), response);
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`[webview-server] Serving ${webviewDir} on http://127.0.0.1:${port}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}
