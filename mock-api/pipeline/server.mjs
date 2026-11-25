import { createHash } from 'node:crypto';
import { createServer as createHttpServer } from 'node:http';

const probe = /^\/probe\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

function reply(response, code, body) {
  response.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(body));
}

function content(id) {
  const chunks = [];
  for (let i = 0; i < 8192; i++) {
    chunks.push(createHash('sha256').update(`${id}:${i}`).digest());
  }
  return Buffer.concat(chunks).toString('base64');
}

export function createServer(log = console.log) {
  return createHttpServer((request, response) => {
    if (request.method !== 'GET') return reply(response, 405, { error: 'method_not_allowed' });
    const [path] = request.url.split('?', 1);
    if (path === '/') return reply(response, 200, { ok: true });
    const match = probe.exec(path);
    if (!match) return reply(response, 404, { error: 'not_found' });
    const [, probeId] = match;
    reply(response, 200, { ok: true, probeId, data: content(probeId) });
    log(JSON.stringify({ event: 'synthetic-probe', probeId }));
  });
}

if (import.meta.main) {
  createServer().listen(Number(process.env.PORT ?? 8080), '0.0.0.0');
}
