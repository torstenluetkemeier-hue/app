import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, test } from 'node:test';
import { createApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { openDatabase } from '../src/db.js';

let server;
let baseUrl;
let clock = Date.now();

before(async () => {
  const config = {
    ...loadConfig({ JWT_SECRET: 'x'.repeat(48) }),
    authRateLimit: 1000,
  };
  const db = openDatabase(':memory:');
  server = http.createServer(createApp({ config, db, now: () => clock }));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

async function call(method, path, { body, token } = {}) {
  const res = await fetch(baseUrl + path, {
    method,
    headers: {
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

describe('Registrierung & Login', () => {
  test('Registrierung liefert Tokens und normalisiert E-Mail', async () => {
    const res = await call('POST', '/v1/auth/register', { body: { email: '  Anna@Example.DE ', password: 'geheim123' } });
    assert.equal(res.status, 201);
    assert.equal(res.body.user.email, 'anna@example.de');
    assert.ok(res.body.accessToken);
    assert.ok(res.body.refreshToken);
  });

  test('doppelte E-Mail wird abgelehnt', async () => {
    const res = await call('POST', '/v1/auth/register', { body: { email: 'anna@example.de', password: 'geheim123' } });
    assert.equal(res.status, 409);
    assert.equal(res.body.error.code, 'email_taken');
  });

  test('ungültige E-Mail und schwaches Passwort werden abgelehnt', async () => {
    assert.equal((await call('POST', '/v1/auth/register', { body: { email: 'kein-mail', password: 'geheim123' } })).body.error.code, 'invalid_email');
    assert.equal((await call('POST', '/v1/auth/register', { body: { email: 'b@example.de', password: 'kurz1' } })).body.error.code, 'weak_password');
    assert.equal((await call('POST', '/v1/auth/register', { body: { email: 'b@example.de', password: 'nurbuchstaben' } })).body.error.code, 'weak_password');
  });

  test('Login mit richtigem und falschem Passwort', async () => {
    const ok = await call('POST', '/v1/auth/login', { body: { email: 'ANNA@example.de', password: 'geheim123' } });
    assert.equal(ok.status, 200);
    const me = await call('GET', '/v1/me', { token: ok.body.accessToken });
    assert.equal(me.body.user.email, 'anna@example.de');

    const wrong = await call('POST', '/v1/auth/login', { body: { email: 'anna@example.de', password: 'falsch123' } });
    assert.equal(wrong.status, 401);
    const unknown = await call('POST', '/v1/auth/login', { body: { email: 'niemand@example.de', password: 'falsch123' } });
    assert.equal(unknown.status, 401);
    assert.equal(unknown.body.error.code, wrong.body.error.code);
  });

  test('ohne oder mit manipuliertem Token kein Zugriff', async () => {
    assert.equal((await call('GET', '/v1/me')).status, 401);
    const ok = await call('POST', '/v1/auth/login', { body: { email: 'anna@example.de', password: 'geheim123' } });
    const tampered = ok.body.accessToken.slice(0, -2) + (ok.body.accessToken.endsWith('A') ? 'BB' : 'AA');
    assert.equal((await call('GET', '/v1/me', { token: tampered })).status, 401);
  });

  test('Access-Token läuft ab', async () => {
    const ok = await call('POST', '/v1/auth/login', { body: { email: 'anna@example.de', password: 'geheim123' } });
    clock += 16 * 60 * 1000;
    assert.equal((await call('GET', '/v1/me', { token: ok.body.accessToken })).status, 401);
  });
});

describe('Refresh-Token-Rotation', () => {
  test('Refresh rotiert und erkennt Wiederverwendung', async () => {
    const login = await call('POST', '/v1/auth/login', { body: { email: 'anna@example.de', password: 'geheim123' } });
    const first = login.body.refreshToken;

    const r1 = await call('POST', '/v1/auth/refresh', { body: { refreshToken: first } });
    assert.equal(r1.status, 200);
    assert.notEqual(r1.body.refreshToken, first);

    // Altes Token erneut benutzt → abgelehnt und gesamte Familie gesperrt
    const reuse = await call('POST', '/v1/auth/refresh', { body: { refreshToken: first } });
    assert.equal(reuse.status, 401);
    const r2 = await call('POST', '/v1/auth/refresh', { body: { refreshToken: r1.body.refreshToken } });
    assert.equal(r2.status, 401);
  });

  test('Logout widerruft Refresh-Token', async () => {
    const login = await call('POST', '/v1/auth/login', { body: { email: 'anna@example.de', password: 'geheim123' } });
    assert.equal((await call('POST', '/v1/auth/logout', { body: { refreshToken: login.body.refreshToken } })).status, 204);
    assert.equal((await call('POST', '/v1/auth/refresh', { body: { refreshToken: login.body.refreshToken } })).status, 401);
  });
});

describe('Datensynchronisation', () => {
  test('Speichern mit optimistischer Versionierung', async () => {
    const reg = await call('POST', '/v1/auth/register', { body: { email: 'sync@example.de', password: 'geheim123' } });
    const token = reg.body.accessToken;

    const empty = await call('GET', '/v1/data', { token });
    assert.deepEqual(empty.body, { version: 0, payload: null, updatedAt: null });

    const put1 = await call('PUT', '/v1/data', { token, body: { baseVersion: 0, payload: { water: [1] } } });
    assert.equal(put1.status, 200);
    assert.equal(put1.body.version, 1);

    const conflict = await call('PUT', '/v1/data', { token, body: { baseVersion: 0, payload: { water: [2] } } });
    assert.equal(conflict.status, 409);
    assert.deepEqual(conflict.body.error.current.payload, { water: [1] });

    const put2 = await call('PUT', '/v1/data', { token, body: { baseVersion: 1, payload: { water: [1, 2] } } });
    assert.equal(put2.body.version, 2);
    const got = await call('GET', '/v1/data', { token });
    assert.deepEqual(got.body.payload, { water: [1, 2] });
  });
});

describe('Konto', () => {
  test('Passwort ändern meldet andere Sitzungen ab', async () => {
    const reg = await call('POST', '/v1/auth/register', { body: { email: 'pw@example.de', password: 'geheim123' } });
    const res = await call('PUT', '/v1/me/password', {
      token: reg.body.accessToken,
      body: { currentPassword: 'geheim123', newPassword: 'neuesPasswort9' },
    });
    assert.equal(res.status, 200);
    assert.equal((await call('POST', '/v1/auth/refresh', { body: { refreshToken: reg.body.refreshToken } })).status, 401);
    assert.equal((await call('POST', '/v1/auth/login', { body: { email: 'pw@example.de', password: 'neuesPasswort9' } })).status, 200);
  });

  test('Konto löschen entfernt Benutzer und Daten', async () => {
    const reg = await call('POST', '/v1/auth/register', { body: { email: 'weg@example.de', password: 'geheim123' } });
    const token = reg.body.accessToken;
    await call('PUT', '/v1/data', { token, body: { baseVersion: 0, payload: { a: 1 } } });
    assert.equal((await call('DELETE', '/v1/me', { token })).status, 204);
    assert.equal((await call('GET', '/v1/me', { token })).status, 401);
    assert.equal((await call('POST', '/v1/auth/login', { body: { email: 'weg@example.de', password: 'geheim123' } })).status, 401);
    // E-Mail ist wieder frei
    assert.equal((await call('POST', '/v1/auth/register', { body: { email: 'weg@example.de', password: 'geheim123' } })).status, 201);
  });
});

describe('Robustheit', () => {
  test('ungültiges JSON, falscher Content-Type, unbekannte Route', async () => {
    const bad = await fetch(baseUrl + '/v1/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{nope' });
    assert.equal(bad.status, 400);
    const type = await fetch(baseUrl + '/v1/auth/login', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: 'x' });
    assert.equal(type.status, 415);
    assert.equal((await call('GET', '/v1/gibtsnicht')).status, 404);
    assert.equal((await call('GET', '/v1/auth/login')).status, 405);
    assert.equal((await call('GET', '/health')).status, 200);
  });
});
