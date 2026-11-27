import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';
import { Store } from '../src/store.js';
import { signatur, waehlbar, tempoProzent } from '../src/telephony/twilio.js';
import { zerlege, ssmlFragment, mergeLexika, gesprochenerText } from '../src/core/aussprache.js';
import { uebernehmeAppKonfiguration, SyncFehler } from '../src/appsync.js';
import { defaultUser } from '../src/core/defaults.js';

const BASIS = 'https://ab.example.de';
const AUTH = 'twilio-test-token';
let server, base, dir, store;
const twilioAufrufe = [];

// Ersetzt Netzwerkzugriffe: Twilio-REST-API und Aufnahmen
const fakeFetch = async (url, init = {}) => {
  twilioAufrufe.push({ url: String(url), init });
  if (String(url).includes('/Calls.json')) {
    return { ok: true, status: 201, json: async () => ({ sid: 'CA_PROBE', status: 'queued' }) };
  }
  if (String(url).endsWith('.mp3')) {
    return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([0x49, 0x44, 0x33, 1, 2, 3]).buffer };
  }
  return { ok: true, status: 200, json: async () => ({}) };
};

before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-cloud-'));
  store = new Store(dir);
  store.config.telefonie.publicUrl = BASIS;
  store.config.telefonie.twilio.accountSid = 'AC123';
  store.config.telefonie.twilio.authToken = AUTH;
  store.config.lexikon = [{ schreibweise: 'Hoffmann', ipa: 'ˈhɔfman', lautschrift: '' }];
  const u = store.user('mmeyer');
  u.cloud = { nummer: '+49 30 111222', mobilnummer: '0171 9998877' };
  // Zweiter Mitarbeiter ohne eigene Cloud-Nummer, erkannt über die umleitende Handynummer
  const t = defaultUser();
  Object.assign(t, { id: 'tmueller', kalender: [], status: null });
  t.profil = { ...t.profil, vorname: 'Thomas', nachname: 'Müller' };
  t.cloud = { nummer: '', mobilnummer: '+49 160 5554433' };
  store.config.users.push(t);
  store.saveConfig();
  server = http.createServer(createApp(store, { fetchImpl: fakeFetch, env: {}, verzoegerungMs: 20 }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });

async function tw(pfad, params, { signiert = true } = {}) {
  const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
  if (signiert) headers['X-Twilio-Signature'] = signatur(AUTH, BASIS + pfad, params);
  const res = await fetch(base + pfad, { method: 'POST', headers, body: new URLSearchParams(params) });
  return { status: res.status, text: await res.text() };
}

async function api(method, pfad, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(base + pfad, { method, headers, body: body && JSON.stringify(body) });
  const typ = res.headers.get('content-type') || '';
  return { status: res.status, data: typ.includes('json') ? await res.json() : Buffer.from(await res.arrayBuffer()) };
}

// --------------------------------------------------------------------------------------------

test('Aussprache: Wörterbuch wird ganzwortig als SSML eingesetzt', () => {
  const lex = [
    { schreibweise: 'Nguyen', lautschrift: 'Nuien', ipa: '' },
    { schreibweise: 'Çelik', lautschrift: 'Tschelik', ipa: 'tʃeˈlik' },
  ];
  assert.equal(ssmlFragment('Frau Nguyen & Herr Çelik, nicht Nguyenweg', lex),
    'Frau <sub alias="Nuien">Nguyen</sub> &amp; Herr <phoneme alphabet="ipa" ph="tʃeˈlik">Çelik</phoneme>, nicht Nguyenweg');
  assert.equal(gesprochenerText('NGUYEN', lex), 'Nuien');
  assert.equal(zerlege('Max Meyer', [{ schreibweise: 'Meyer' }]).length, 1, 'Einträge ohne Korrektur ändern nichts');
  const merged = mergeLexika([{ schreibweise: 'Kraus', lautschrift: 'A' }], [{ schreibweise: 'kraus', lautschrift: 'B' }]);
  assert.deepEqual(merged.map((e) => e.lautschrift), ['B'], 'persönlicher Eintrag hat Vorrang');
});

test('Twilio: Hilfsfunktionen', () => {
  assert.equal(waehlbar('+49 3641 000 200'), '+493641000200');
  assert.equal(waehlbar('0171/1234567'), '+491711234567');
  assert.equal(tempoProzent(0.48), 96);
});

test('Webhook ohne gültige Signatur wird abgelehnt', async () => {
  const r = await tw('/tw/voice', { CallSid: 'CA0', From: '+49897654321', To: '+4930111222' }, { signiert: false });
  assert.equal(r.status, 403);
});

test('Umgeleiteter Anruf eines VIP-Kunden: Begrüßung mit Namen, Aussprache, Tastenwahl, Aufnahme', async () => {
  const r = await tw('/tw/voice', { CallSid: 'CA1', From: '+49897654321', To: '+4930111222', ForwardedFrom: '+491719998877' });
  assert.equal(r.status, 200);
  assert.match(r.text, /^<\?xml/);
  assert.match(r.text, /<Gather input="dtmf" numDigits="1"[^>]*action="https:\/\/ab\.example\.de\/tw\/taste\?callId=CA1"/);
  assert.match(r.text, /<Say voice="Polly\.Vicki-Neural" language="de-DE">/);
  assert.match(r.text, /Guten (Morgen|Tag|Abend), Herr Prof\. Dr\. <phoneme alphabet="ipa" ph="ˈhɔfman">Hoffmann<\/phoneme>!/);
  assert.match(r.text, /<break time="450ms"\/>/);
  assert.match(r.text, /<Record maxLength="120"[^>]*recordingStatusCallback="https:\/\/ab\.example\.de\/tw\/aufnahme\?callId=CA1"/);

  const t = await tw('/tw/taste?callId=CA1', { CallSid: 'CA1', Digits: '1' });
  assert.match(t.text, /ich verbinde Sie mit Thomas Müller/);
  assert.match(t.text, /<Dial>\+493641000200<\/Dial>/);
});

test('Nachricht wird gespeichert, nicht doppelt, Aufnahme über die App abrufbar', async () => {
  await tw('/tw/voice', { CallSid: 'CA2', From: '040 1234567', To: '+4930111222' });
  const ende = await tw('/tw/aufnahme-ende?callId=CA2', { CallSid: 'CA2', RecordingUrl: 'https://api.twilio.com/rec/RE2', RecordingDuration: '14' });
  assert.match(ende.text, /Vielen Dank für Ihre Nachricht/);
  await tw('/tw/aufnahme?callId=CA2', { CallSid: 'CA2', RecordingUrl: 'https://api.twilio.com/rec/RE2', RecordingStatus: 'completed', RecordingDuration: '14' });
  const eigene = store.nachrichten.filter((n) => n.aufnahmeUrl === 'https://api.twilio.com/rec/RE2');
  assert.equal(eigene.length, 1);
  assert.equal(eigene[0].kontakt.nachname, 'Schneider');
  assert.equal(eigene[0].prioritaet, 'hoch');
  assert.match(eigene[0].aufgabe.id, /^MOCK-/);

  const zugang = await api('POST', '/api/users/mmeyer/app-zugang');
  const audio = await api('GET', `/api/app/nachrichten/${eigene[0].id}/audio`, undefined, zugang.data.token);
  assert.equal(audio.status, 200);
  assert.equal(audio.data[0], 0x49);
  const abruf = twilioAufrufe.find((a) => a.url === 'https://api.twilio.com/rec/RE2.mp3');
  assert.equal(abruf.init.headers.Authorization, 'Basic ' + Buffer.from(`AC123:${AUTH}`).toString('base64'));
});

test('Anruf ohne Nachricht landet trotzdem in der Rückrufliste', async () => {
  await tw('/tw/voice', { CallSid: 'CA3', From: '+4922199887', To: '+4930111222' });
  await tw('/tw/status', { CallSid: 'CA3', CallStatus: 'completed' });
  await new Promise((r) => setTimeout(r, 60));
  const n = store.nachrichten.find((x) => x.nummer === '+4922199887');
  assert.equal(n?.ohneNachricht, true);
});

test('Mitarbeiter ohne eigene Cloud-Nummer wird über die umleitende Handynummer erkannt', async () => {
  const r = await tw('/tw/voice', { CallSid: 'CA4', From: '+4930999', To: '+4930777000', ForwardedFrom: '+491605554433' });
  assert.match(r.text, /Anschluss von Thomas Müller/);
});

test('App-API: Zugang, Synchronisierung, Vorschau, Probeanruf', async () => {
  const ohne = await api('GET', '/api/app/ich');
  assert.equal(ohne.status, 401);
  const { data: { token } } = await api('POST', '/api/users/mmeyer/app-zugang');
  assert.match(token, /^ab_mmeyer_/);
  const ich = await api('GET', '/api/app/ich', undefined, token);
  assert.equal(ich.data.name, 'Max Meyer');
  assert.equal(ich.data.telefonieBereit, true);
  const cfg = await api('GET', '/api/config');
  assert.equal(cfg.data.users[0].appTokenHash, undefined, 'Hash wird nicht ausgeliefert');
  assert.equal(cfg.data.telefonie.twilio.authToken, '••••••');

  // Konfiguration aus der App (Format, das AnrufbeantworterCore.CloudPayload erzeugt)
  const sync = await api('PUT', '/api/app/konfiguration', {
    version: '0.3.0',
    profil: { vorname: 'Max', nachname: 'Meyer', funktion: 'Vertrieb' },
    vertretungen: [{ id: 'v1', name: 'Gülşen Yılmaz', telefon: '0171 2223344' }],
    standardVertretungId: 'v1',
    vertretungNennenIn: ['urlaub', 'termin'],
    status: { modus: 'termin', art: 'online-praesentation', freitext: '', bis: '2099-01-01T15:00', ganztags: false },
    kalender: [{ id: 'k1', titel: 'Urlaub', modus: 'urlaub', art: '', von: '2099-07-01', bis: '2099-07-14', ganztags: true, vertretungId: '' }],
    texte: { intro: '{{begruessung}}! Hier ist {{ich.name}} von {{firma.name}}.' },
    lexikon: [{ schreibweise: 'Gülşen Yılmaz', lautschrift: 'Gülschen Jilmas', ipa: '' }],
    stimme: { tempo: 0.5, pauseMs: 300 },
  }, token);
  assert.equal(sync.status, 200, JSON.stringify(sync.data));
  assert.equal(sync.data.aktuell.modus, 'termin');

  const v = await api('GET', '/api/app/vorschau', undefined, token);
  assert.match(v.data.text, /Hier ist Max Meyer von zollsoft\. Ich bin gerade in einer Online-Präsentation/);
  assert.match(v.data.ssml, /<sub alias="Gülschen Jilmas">Gülşen Yılmaz<\/sub>/);
  assert.match(v.data.ssml, /<break time="300ms"\/>/);

  const p = await api('POST', '/api/app/probeanruf', {}, token);
  assert.equal(p.data.sid, 'CA_PROBE');
  const call = twilioAufrufe.find((a) => a.url.endsWith('/Accounts/AC123/Calls.json'));
  const params = new URLSearchParams(String(call.init.body));
  assert.equal(params.get('To'), '+491719998877');
  assert.equal(params.get('From'), '+4930111222');
  assert.match(params.get('Twiml'), /<Say voice="Polly\.Vicki-Neural"/);

  const kaputt = await api('PUT', '/api/app/konfiguration', { status: { modus: 'quatsch' } }, token);
  assert.equal(kaputt.status, 400);
});

test('Sync übernimmt nur erlaubte Felder', () => {
  const u = defaultUser();
  const regelnVorher = structuredClone(u.regeln);
  uebernehmeAppKonfiguration(u, { regeln: [], cloud: { nummer: '+49999', mobilnummer: '0171 1' }, status: null });
  assert.deepEqual(u.regeln, regelnVorher);
  assert.equal(u.cloud.nummer, '', 'Cloud-Nummer vergibt nur die Verwaltung');
  assert.equal(u.cloud.mobilnummer, '0171 1');
  assert.throws(() => uebernehmeAppKonfiguration(u, { kalender: [{ modus: 'urlaub', von: '2099-07-10', bis: '2099-07-01' }] }), SyncFehler);
});

test('ADMIN_TOKEN schützt die Verwaltung', async () => {
  const s = http.createServer(createApp(new Store(fs.mkdtempSync(path.join(os.tmpdir(), 'ab-adm-'))), { env: { ADMIN_TOKEN: 'geheim' } }));
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const b = `http://127.0.0.1:${s.address().port}`;
  assert.equal((await fetch(b + '/api/config')).status, 401);
  assert.equal((await fetch(b + '/api/config', { headers: { Authorization: 'Bearer geheim' } })).status, 200);
  assert.equal((await fetch(b + '/')).status, 200, 'Weboberfläche selbst ist erreichbar');
  s.close();
});

test('Vertrag mit der iPhone-App: von Swift erzeugte Übertragung wird korrekt angesagt', async () => {
  // test/fixtures/app-payload.json erzeugt der Swift-Test CloudTests.testBeispielPayloadFuerServerTest
  const payload = JSON.parse(fs.readFileSync(new URL('./fixtures/app-payload.json', import.meta.url)));
  const { data: { token } } = await api('POST', '/api/users/tmueller/app-zugang');
  const sync = await api('PUT', '/api/app/konfiguration', payload, token);
  assert.equal(sync.status, 200, JSON.stringify(sync.data));
  const v = await api('GET', '/api/app/vorschau?from=%2B49897654321', undefined, token);
  assert.match(v.data.text, /^Guten (Morgen|Tag|Abend), Herr Prof\. Dr\. Hoffmann! Sie sind verbunden mit dem Anschluss von Max Meyer, Kundenberater bei zollsoft, Ihrem Team für tomedo\./);
  assert.match(v.data.text, /Ich bin gerade in einer Online-Präsentation, voraussichtlich bis .*15 Uhr, und daher nicht erreichbar\./);
  assert.match(v.data.text, /In dringenden Fällen erreichen Sie Gülşen Yılmaz unter 0 1 7 1, 2 2 2 3 3 4 4\./);
  assert.match(v.data.ssml, /<sub alias="Gülschen Jilmas">Gülşen Yılmaz<\/sub>/);
});
