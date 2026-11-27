import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';
import { Store } from '../src/store.js';
import { RestCrmAdapter } from '../src/crm/rest.js';
import { CallerLookup } from '../src/crm/index.js';

let server, base, dir;

before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-test-'));
  server = http.createServer(createApp(new Store(dir)));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });

const req = async (method, url, body) => {
  const res = await fetch(base + url, { method, headers: { 'Content-Type': 'application/json' }, body: body && JSON.stringify(body) });
  return { status: res.status, data: await res.json() };
};

test('Kompletter Anruf über die Telefonie-API: Erkennung, Tastenwahl, Nachricht, Aufgabe', async () => {
  const inc = await req('POST', '/api/telephony/incoming', { to: '+49 3641 000 100', from: '089 7654321', zeit: '2026-11-27T10:00' });
  assert.equal(inc.status, 200);
  assert.equal(inc.data.anrufer.erkannt, true);
  assert.match(inc.data.ablauf[0].text, /Herr Prof\. Dr\. Hoffmann/);

  const dtmf = await req('POST', '/api/telephony/dtmf', { callId: inc.data.callId, taste: '1' });
  assert.equal(dtmf.data.aktion, 'weiterleiten');

  const rec = await req('POST', '/api/telephony/recording', { callId: inc.data.callId, transkript: 'Bitte um Rückruf wegen Update.' });
  assert.equal(rec.data.prioritaet, 'hoch');
  assert.match(rec.data.aufgabe.id, /^MOCK-/);

  const list = await req('GET', '/api/nachrichten?userId=mmeyer');
  assert.equal(list.data.length, 1);
  assert.equal(list.data[0].transkript, 'Bitte um Rückruf wegen Update.');
});

test('Status setzen und Kalendereintrag anlegen', async () => {
  const s = await req('PUT', '/api/users/mmeyer/status', { modus: 'urlaub', bis: '2099-01-01', ganztags: true });
  assert.equal(s.data.aktuell.modus, 'urlaub');
  await req('PUT', '/api/users/mmeyer/status', { modus: null });
  const bad = await req('POST', '/api/users/mmeyer/kalender', { modus: 'termin', von: '2026-12-02T10:00', bis: '2026-12-02T09:00' });
  assert.equal(bad.status, 400);
  const ok = await req('POST', '/api/users/mmeyer/kalender', { modus: 'termin', art: 'schulung', von: '2026-12-02T09:00', bis: '2026-12-02T12:00' });
  assert.equal(ok.status, 200);
  const pv = await req('POST', '/api/vorschau', { userId: 'mmeyer', zeit: '2026-12-02T10:00' });
  assert.match(pv.data.ansage.text, /Ich bin gerade in einer Schulung, voraussichtlich bis 12 Uhr/);
});

test('API-Token wird nicht ausgeliefert', async () => {
  await req('PUT', '/api/crm', { qto: { apiToken: 'geheim', baseUrl: 'https://qto.example' } });
  const c = await req('GET', '/api/config');
  assert.equal(c.data.crm.qto.apiToken, '••••••');
  await req('PUT', '/api/crm', { adapter: 'mock' });
});

test('REST-Adapter: Feld-Mapping und Timeout-Fallback', async () => {
  const fake = async (url) => ({ ok: true, status: 200, json: async () => ({ items: [{ id: 7, salutation: 'Frau', lastName: 'Kraus', company: 'Praxis Kraus', customerNumber: 'K7' }] }), url });
  const a = new RestCrmAdapter({ baseUrl: 'https://qto.example', lookupPath: '/c?phone={nummer}' }, { name: 'Qto', fetchImpl: fake });
  const k = await a.findByPhone('+4930123');
  assert.equal(k.nachname, 'Kraus');
  assert.equal(k.typ, 'praxis');

  const zwei = async () => ({ ok: true, status: 200, json: async () => [
    { id: 1, salutation: 'Frau', lastName: 'Kraus', company: 'Praxis Kraus', customerNumber: 'K7' },
    { id: 2, salutation: 'Herr', lastName: 'Lenz', company: 'Praxis Kraus', customerNumber: 'K7' },
  ] });
  const m = await new RestCrmAdapter({ baseUrl: 'https://qto.example', lookupPath: '/c?phone={nummer}' }, { fetchImpl: zwei }).findByPhone('+4930123');
  assert.equal(m.nachname, '');
  assert.equal(m.organisation, 'Praxis Kraus');
  assert.equal(m.mehrdeutig, true);

  const slow =(url, { signal }) => new Promise((_, rej) => signal.addEventListener('abort', () => rej(Object.assign(new Error('abort'), { name: 'AbortError' }))));
  const b = new RestCrmAdapter({ baseUrl: 'https://qto.example', lookupPath: '/c?phone={nummer}' }, { name: 'Qto', fetchImpl: slow, timeoutMs: 50 });
  const r = await new CallerLookup(b).find('+4930123');
  assert.equal(r.kontakt, null);
  assert.equal(r.fehler, 'Zeitüberschreitung');
});
