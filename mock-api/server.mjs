import { createServer as createHttpServer } from 'node:http';

const probePath = /^\/probe\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

function sendJson(response, status, payload, headers) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  response.end(JSON.stringify(payload));
}

export function createServer() {
  return createHttpServer((request, response) => {
    if (request.method !== 'GET') {
      sendJson(response, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });
      return;
    }

    const [path] = request.url.split('?', 1);
    if (path === '/') {
      sendJson(response, 200, { ok: true });
      return;
    }

    const probe = probePath.exec(path);
    if (probe) {
      sendJson(response, 200, { ok: true, probeId: probe[1] });
      return;
    }

    sendJson(response, 404, { error: 'not_found' });
  });
}

if (import.meta.main) {
  createServer().listen(Number(process.env.PORT ?? 8080), '0.0.0.0');
}
