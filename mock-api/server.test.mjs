import assert from 'node:assert/strict';
import { once } from 'node:events';
import { after, before, test } from 'node:test';
import { createServer as createPipelineServer } from './pipeline/server.mjs';
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

test('pipeline_probe_returns_verified_synthetic_content_and_correlates_only_valid_requests', async (t) => {
  const logs = [];
  const pipeline = createPipelineServer(entry => logs.push(JSON.parse(entry))).listen(0, '127.0.0.1');
  await once(pipeline, 'listening');
  t.after(() => new Promise((resolve, reject) => {
    pipeline.close(error => error ? reject(error) : resolve());
  }));
  const app = `http://127.0.0.1:${pipeline.address().port}`;

  const health = await fetch(`${app}/`);
  assert.deepEqual(await health.json(), { ok: true });
  const invalid = await fetch(`${app}/probe/${'-'.repeat(36)}`);
  assert.equal(invalid.status, 404);
  await invalid.body.cancel();

  const response = await fetch(`${app}/probe/${probeId}`);
  assert.equal(response.status, 200);
  const { ok, probeId: actualId, data } = await response.json();
  assert.equal(ok, true);
  assert.equal(actualId, probeId);
  const payload = Buffer.from(data, 'base64');
  assert.equal(payload.length, 256 * 1024);
  const digest = await crypto.subtle.digest('SHA-256', payload);
  assert.equal(Buffer.from(digest).toString('hex'), '657bd23692284258f719820fa25868e9d5049dda0812fde6eed40660e263ca03');
  assert.deepEqual(logs, [{ event: 'synthetic-probe', probeId }]);
});
