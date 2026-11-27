import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp, tempoProzent } from '../src/server.js';
import { Store } from '../src/store.js';
import { waehlbar } from '../src/telephony/sipgate.js';
import { zerlege, ssmlFragment, mergeLexika, gesprochenerText, ttsText } from '../src/core/aussprache.js';
import { leseWav, schreibeWav, resample, normalisiere } from '../src/audio/wav.js';
import { inSaetze } from '../src/tts/ansageAudio.js';
import { uebernehmeAppKonfiguration, SyncFehler } from '../src/appsync.js';
import { defaultUser } from '../src/core/defaults.js';

const BASIS = 'https://ab.example.de';
let server, base, dir, store, geheim;
const piperTexte = [];

/** Erzeugt eine "Sprach"-WAV wie Piper (22,05 kHz), Länge abhängig vom Text. */
function fakeWav(text) {
  const rate = 22050;
  const n = Math.round(rate * (0.2 + text.length / 40));
  const s = new Float32Array(n);
  for (let i = 0; i < n; i++) s[i] = 0.3 * Math.sin((2 * Math.PI * 440 * i) / rate);
  return schreibeWav(s, rate);
}

// Ersetzt Netzwerkzugriffe: Piper-Sprachausgabe (und Webhooks)
const fakeFetch = async (url, init = {}) => {
  if (String(url).endsWith('/synthesize')) {
    const body = JSON.parse(init.body);
    piperTexte.push(body);
    const wav = fakeWav(body.text);
    return { ok: true, status: 200, arrayBuffer: async () => wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.length) };
  }
  return { ok: true, status: 200, json: async () => ({}) };
};

before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-cloud-'));
  store = new Store(dir);
  store.config.telefonie.publicUrl = BASIS;
  store.config.telefonie.tts.piperUrl = 'http://piper.intern:5000';
  store.config.lexikon = [{ schreibweise: 'Hoffmann', ipa: 'ˈhɔfman', lautschrift: 'Hoffmann' }];
  geheim = store.config.telefonie.sipgate.webhookGeheimnis;
  const u = store.user('mmeyer');
  u.cloud = { nummer: '+49 30 111222', mobilnummer: '0171 9998877' };
  // Zweiter Mitarbeiter ohne eigene Nummer: erkannt über die umleitende Handynummer (sipgate: diversion)
  const t = defaultUser();
  Object.assign(t, { id: 'tmueller', kalender: [], status: null });
  t.profil = { ...t.profil, vorname: 'Thomas', nachname: 'Müller' };
  t.cloud = { nummer: '', mobilnummer: '+49 160 5554433' };
  store.config.users.push(t);
  store.saveConfig();
  server = http.createServer(createApp(store, { fetchImpl: fakeFetch, env: {}, vorwaermenBeiStart: false }));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });

async function sg(aktion, params, { pfadGeheimnis = geheim, query = '' } = {}) {
  const res = await fetch(`${base}/sg/${pfadGeheimnis}/${aktion}${query}`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(params),
  });
  return { status: res.status, typ: res.headers.get('content-type'), text: await res.text() };
}

async function api(method, pfad, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(base + pfad, { method, headers, body: body && JSON.stringify(body) });
  const typ = res.headers.get('content-type') || '';
  return { status: res.status, typ, data: typ.includes('json') ? await res.json() : Buffer.from(await res.arrayBuffer()) };
}

const neuerAnruf = (callId, from, extra = {}) => sg('anruf', { event: 'newCall', direction: 'in', from, to: '4930111222', callId, 'user[]': 'Max Meyer', ...extra });
const audioUrl = (xml) => xml.match(/<Url>([^<]+)<\/Url>/)[1];

// --------------------------------------------------------------------------------------------

test('Audio: Telefonqualität 8 kHz mono 16 bit, gleichmäßige Lautstärke', () => {
  const wav = fakeWav('Guten Tag');
  const { rate, samples } = leseWav(wav);
  assert.equal(rate, 22050);
  const tel = normalisiere(resample(samples, rate, 8000));
  assert.ok(Math.abs(tel.length - Math.floor(samples.length * 8000 / 22050)) <= 1);
  assert.ok(Math.abs(Math.max(...tel) - 0.89) < 0.01);
  const zurueck = leseWav(schreibeWav(tel));
  assert.equal(zurueck.rate, 8000);
  assert.equal(zurueck.samples.length, tel.length);
});

test('Aussprache: Lautschrift, IPA für Piper und SSML', () => {
  const lex = [
    { schreibweise: 'Nguyen', lautschrift: 'Nuien', ipa: '' },
    { schreibweise: 'Çelik', lautschrift: 'Tschelik', ipa: 't͡ʃeˈlik' },
  ];
  assert.equal(ttsText('Frau Nguyen und Herr Çelik', lex), 'Frau Nuien und Herr Tschelik');
  assert.equal(ttsText('Frau Nguyen und Herr Çelik', lex, { ipaInline: true }), 'Frau Nuien und Herr [[ tʃeˈlik ]]');
  assert.equal(ssmlFragment('Nguyen & Çelik', lex), '<sub alias="Nuien">Nguyen</sub> &amp; <phoneme alphabet="ipa" ph="t͡ʃeˈlik">Çelik</phoneme>');
  assert.equal(gesprochenerText('NGUYEN', lex), 'Nuien');
  assert.equal(zerlege('Max Meyer', [{ schreibweise: 'Meyer' }]).length, 1, 'Einträge ohne Korrektur ändern nichts');
  assert.deepEqual(mergeLexika([{ schreibweise: 'Kraus', lautschrift: 'A' }], [{ schreibweise: 'kraus', lautschrift: 'B' }]).map((e) => e.lautschrift), ['B']);
});

test('Sätze werden nicht nach Abkürzungen getrennt', () => {
  assert.deepEqual(inSaetze('Guten Tag, Herr Prof. Dr. Hoffmann! Sie sind verbunden. Z. B. mit Frau M. Kraus?'),
    ['Guten Tag, Herr Prof. Dr. Hoffmann!', 'Sie sind verbunden.', 'Z. B. mit Frau M. Kraus?']);
});

test('Hilfsfunktionen', () => {
  assert.equal(waehlbar('+49 3641 000 200'), '493641000200');
  assert.equal(waehlbar('0171/1234567'), '491711234567');
  assert.equal(tempoProzent(0.48), 96);
});

test('Webhook mit falschem Geheimnis wird abgelehnt', async () => {
  const r = await sg('anruf', { event: 'newCall', from: '4989', to: '4930111222', callId: 'x' }, { pfadGeheimnis: 'falsch' });
  assert.equal(r.status, 404);
});

test('VIP-Kunde ruft an: persönliche Ansage als WAV, Taste 1 verbindet mit der Vertretung', async () => {
  const r = await neuerAnruf('c1', '49897654321', { diversion: '491719998877' });
  assert.equal(r.status, 200);
  assert.match(r.typ, /application\/xml/);
  assert.match(r.text, new RegExp(`<Response onHangup="https://ab\\.example\\.de/sg/${geheim}/ende\\?callId=c1">`));
  assert.match(r.text, new RegExp(`<Gather onData="https://ab\\.example\\.de/sg/${geheim}/daten\\?callId=c1" maxDigits="1" timeout="1500">`));
  const url = audioUrl(r.text);
  assert.match(url, /^https:\/\/ab\.example\.de\/audio\/[a-f0-9]{40}\.wav$/);

  // Die Datei liefert der Server selbst aus – in sipgate-Format
  const wav = await fetch(base + new URL(url).pathname);
  assert.equal(wav.status, 200);
  const { rate } = leseWav(Buffer.from(await wav.arrayBuffer()));
  assert.equal(rate, 8000);

  // An Piper ging der persönliche Text mit IPA-Korrektur aus dem Firmen-Wörterbuch
  assert.ok(piperTexte.some((p) => /^Guten (Morgen|Tag|Abend), Herr Prof\. Dr\. \[\[ ˈhɔfman \]\]!/.test(p.text)), JSON.stringify(piperTexte.map((p) => p.text)));
  assert.equal(piperTexte[0].voice, 'de_DE-thorsten-high');
  assert.equal(piperTexte[0].length_scale, 1.04);

  const t = await sg('daten', { event: 'dtmf', dtmf: '1', callId: 'c1' }, { query: '?callId=c1' });
  assert.match(t.text, /<Gather [^>]*timeout="1"><Play><Url>/, 'erst "Einen Moment bitte …" abspielen');
  assert.ok(piperTexte.some((p) => p.text === 'Einen Moment bitte, ich verbinde Sie mit Thomas Müller.'));
  const v = await sg('daten', { event: 'dtmf', callId: 'c1' }, { query: '?callId=c1' });
  assert.equal(v.text, '<?xml version="1.0" encoding="UTF-8"?><Response><Dial><Number>493641000200</Number></Dial></Response>');

  await sg('ende', { event: 'hangup', cause: 'normalClearing', callId: 'c1' }, { query: '?callId=c1' });
  assert.equal(store.nachrichten.filter((n) => n.nummer === '+49897654321').length, 0, 'weitergeleitet: kein Rückruf nötig');
});

test('Ohne Taste: Übergabe an die sipgate-Mailbox, Eintrag in der Rückrufliste', async () => {
  const vorher = piperTexte.length;
  await neuerAnruf('c2', '0401234567');
  const m = await sg('daten', { event: 'dtmf', callId: 'c2' }, { query: '?callId=c2' });
  assert.match(m.text, /<Dial><Voicemail \/><\/Dial>/);
  await sg('ende', { event: 'hangup', cause: 'normalClearing', callId: 'c2' }, { query: '?callId=c2' });
  const n = store.nachrichten.find((x) => x.nummer === '+49401234567');
  assert.equal(n.mailbox, true);
  assert.equal(n.kontakt.nachname, 'Schneider');
  assert.equal(n.prioritaet, 'hoch');
  assert.match(n.aufgabe.id, /^MOCK-/);

  // Zweiter Anruf derselben Kundin: Ansage kommt komplett aus dem Cache
  const zwischen = piperTexte.length;
  assert.ok(zwischen > vorher);
  await neuerAnruf('c2b', '0401234567');
  assert.equal(piperTexte.length, zwischen, 'keine erneute Sprachsynthese');
});

test('Aufgelegt während der Ansage: Anruf ohne Nachricht', async () => {
  await neuerAnruf('c3', '4922199887');
  await sg('ende', { event: 'hangup', cause: 'cancel', callId: 'c3' }, { query: '?callId=c3' });
  const n = store.nachrichten.find((x) => x.nummer === '+4922199887');
  assert.equal(n.ohneNachricht, true);
  assert.equal(n.mailbox, false);
});

test('Mitarbeiter wird über die umleitende Handynummer (diversion) erkannt', async () => {
  await sg('anruf', { event: 'newCall', direction: 'in', from: '4930999', to: '4930777000', callId: 'c4', diversion: '491605554433' });
  assert.ok(piperTexte.some((p) => p.text.includes('Anschluss von Thomas Müller')));
});

test('Ausgehende Anrufe werden ignoriert, Fehler der Sprachausgabe führen zur Mailbox', async () => {
  const aus = await sg('anruf', { event: 'newCall', direction: 'out', from: '4930111222', to: '4989', callId: 'c5' });
  assert.equal(aus.text, '<?xml version="1.0" encoding="UTF-8"?><Response />');

  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-fehler-'));
  const st = new Store(d);
  st.config.telefonie.publicUrl = BASIS;
  st.config.telefonie.tts.piperUrl = 'http://piper.intern:5000';
  const kaputt = async () => { throw new Error('Piper nicht erreichbar'); };
  const s = http.createServer(createApp(st, { fetchImpl: kaputt, env: {}, vorwaermenBeiStart: false }));
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const res = await fetch(`http://127.0.0.1:${s.address().port}/sg/${st.config.telefonie.sipgate.webhookGeheimnis}/anruf`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ event: 'newCall', direction: 'in', from: '4989', to: '4930111222', callId: 'f1' }),
  });
  assert.match(await res.text(), /<Dial><Voicemail \/><\/Dial>/);
  s.close();
});

test('App-API: Zugang, Synchronisierung, Vorschau als Text und als Telefon-Audio', async () => {
  assert.equal((await api('GET', '/api/app/ich')).status, 401);
  const { data: { token } } = await api('POST', '/api/users/mmeyer/app-zugang');
  assert.match(token, /^ab_mmeyer_/);
  const ich = await api('GET', '/api/app/ich', undefined, token);
  assert.equal(ich.data.name, 'Max Meyer');
  assert.equal(ich.data.telefonieBereit, true);
  assert.match(ich.data.stimme, /Thorsten/);

  const cfg = await api('GET', '/api/config');
  assert.equal(cfg.data.users[0].appTokenHash, undefined, 'Hash wird nicht ausgeliefert');
  assert.equal(cfg.data.telefonie.audioGeheimnis, undefined);
  assert.equal(cfg.data.telefonie.status.webhookUrl, `${BASIS}/sg/${geheim}/anruf`);

  const sync = await api('PUT', '/api/app/konfiguration', {
    version: '0.4.0',
    profil: { vorname: 'Max', nachname: 'Meyer', funktion: 'Vertrieb' },
    vertretungen: [{ id: 'v1', name: 'Gülşen Yılmaz', telefon: '0171 2223344' }],
    standardVertretungId: 'v1',
    vertretungNennenIn: ['urlaub', 'termin'],
    status: { modus: 'termin', art: 'online-praesentation', freitext: '', bis: '2099-01-01T15:00', ganztags: false },
    texte: { intro: '{{begruessung}}! Hier ist {{ich.name}} von {{firma.name}}.' },
    lexikon: [{ schreibweise: 'Gülşen Yılmaz', lautschrift: 'Gülschen Jilmas', ipa: '' }],
    stimme: { tempo: 0.5, pauseMs: 300 },
  }, token);
  assert.equal(sync.status, 200, JSON.stringify(sync.data));
  assert.equal(sync.data.aktuell.modus, 'termin');

  const v = await api('GET', '/api/app/vorschau', undefined, token);
  assert.match(v.data.text, /Hier ist Max Meyer von zollsoft\. Ich bin gerade in einer Online-Präsentation/);
  assert.match(v.data.gesprochen, /an Gülschen Jilmas, erreichbar unter/);

  const wav = await api('GET', '/api/app/vorschau.wav', undefined, token);
  assert.equal(wav.typ, 'audio/wav');
  assert.equal(leseWav(wav.data).rate, 8000);

  assert.equal((await api('PUT', '/api/app/konfiguration', { status: { modus: 'quatsch' } }, token)).status, 400);
});

test('Verwaltung: Kurzansage für die sipgate-Mailbox und Stimmtest', async () => {
  const m = await api('GET', '/api/mailbox-ansage.wav');
  assert.equal(m.typ, 'audio/wav');
  assert.ok(piperTexte.some((p) => p.text === 'Bitte sprechen Sie jetzt.'));
  const t = await api('POST', '/api/tts/test', { text: 'Test' });
  assert.equal(leseWav(t.data).rate, 8000);
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
  assert.match(v.data.gesprochen, /Gülschen Jilmas/);
});
