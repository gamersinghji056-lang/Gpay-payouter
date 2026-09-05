const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { startWatcher, status: watcherStatus } = require('./tron-watcher');

const root = path.resolve(__dirname, '..', 'dist');
const port = Number(process.env.PORT || 8080);
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
};

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

function serve(req, res) {
  if (req.url === '/health' || req.url === '/status') {
    return send(res, 200, { 'content-type': 'application/json' }, JSON.stringify({ ok: true, watcher: watcherStatus }));
  }
  const rawPath = decodeURIComponent(new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`).pathname);
  const cleanPath = rawPath.replace(/^\/+/, '');
  const target = path.resolve(root, cleanPath || 'index.html');
  const file = target.startsWith(root) && fs.existsSync(target) && fs.statSync(target).isFile() ? target : path.join(root, 'index.html');
  fs.readFile(file, (error, data) => {
    if (error) return send(res, 500, { 'content-type': 'text/plain; charset=utf-8' }, 'server error');
    const ext = path.extname(file).toLowerCase();
    send(res, 200, {
      'content-type': types[ext] || 'application/octet-stream',
      'cache-control': ext === '.html' ? 'no-cache' : 'public, max-age=31536000, immutable',
      'x-content-type-options': 'nosniff',
    }, data);
  });
}

process.env.TRON_WATCH_HEALTH = 'false';
startWatcher().catch((error) => {
  console.error(JSON.stringify({ at: new Date().toISOString(), event: 'watcher_start_failure', message: error.message }));
});

http.createServer(serve).listen(port, () => {
  console.log(JSON.stringify({ at: new Date().toISOString(), event: 'web_server_started', port }));
});
