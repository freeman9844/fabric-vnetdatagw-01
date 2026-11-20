import assert from 'node:assert/strict';
import { once } from 'node:events';
import { after, before, test } from 'node:test';
import { createServer } from './server.mjs';

const probeId = 'c0ffee00-cafe-4ace-8ace-fedcba987654';
let server;
let origin;

before(async () => {
  server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server?.listening) {
    await new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});

test('returns_health_for_connection_validation', async () => {
  const response = await fetch(`${origin}/`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test('returns_only_probe_payload', async () => {
  const response = await fetch(`${origin}/probe/${probeId}`, {
    headers: {
      'X-Forwarded-For': '203.0.113.47',
      'X-Request-Note': 'not-part-of-the-response',
      Authorization: 'Bearer fake-test-token',
    },
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^application\/json\b/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { ok: true, probeId });
});

test('rejects_non_probe_paths_and_unsupported_methods', async () => {
  for (const path of ['/unknown', '/probe/not-a-uuid', `/probe/${probeId}/extra`]) {
    const response = await fetch(`${origin}${path}`);
    assert.equal(response.status, 404, path);
    await response.body.cancel();
  }

  const response = await fetch(`${origin}/probe/${probeId}`, { method: 'POST' });
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'GET');
  await response.body.cancel();
});
