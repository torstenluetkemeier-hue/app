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
import { leseWav, schreibeWav, resample, normalisiere, trimmeStille, verbinde, stille } from '../src/audio/wav.js';
import { AnsageMixer } from '../src/tts/ansageAudio.js';
import { Aufnahmen, alleBausteine } from '../src/aufnahmen.js';
import { uebernehmeAppKonfiguration, SyncFehler } from '../src/appsync.js';
import { defaultUser } from '../src/core/defaults.js';
import { answerCall } from '../src/core/engine.js';

const BASIS = 'https://ab.example.de';
let server, base, dir, store, geheim, appToken;
const kiAuftraege = [];

/** Ton als Ersatz für Sprache. Länge abhängig vom Text. */
function ton(sekunden, rate = 24000, freq = 440) {
  const s = new Float32Array(Math.round(rate * sekunden));
  for (let i = 0; i < s.length; i++) s[i] = 0.3 * Math.sin((2 * Math.PI * freq * i) / rate);
  return s;
}
const fakeWav = (text) => schreibeWav(ton(0.2 + text.length / 40), 24000);
/** Wie eine Handy-Aufnahme: 44,1 kHz mit Stille am Anfang und Ende. */
const aufnahmeWav = (sekunden = 2) => schreibeWav(verbinde([stille(700, 44100), ton(sekunden, 44100, 220), stille(900, 44100)]), 44100);

// Ersetzt den Stimmdienst (stimme/server.py) und Webhooks
const fakeFetch = async (url, init = {}) => {
  if (String(url).endsWith('/synthesize')) {
    const body = JSON.parse(init.body);
    kiAuftraege.push(body);
    const wav = fakeWav(body.text);
    return { ok: true, status: 200, arrayBuffer: async () => wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.length) };
  }
  return { ok: true, status: 200, json: async () => ({}) };
};

before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-cloud-'));
  store = new Store(dir);
  store.config.telefonie.publicUrl = BASIS;
  store.config.telefonie.stimme.url = 'http://stimme.intern:5000';
  store.config.lexikon = [{ schreibweise: 'Hoffmann', lautschrift: 'Hoff-mann', ipa: '' }];
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
  appToken = (await api('POST', '/api/users/mmeyer/app-zugang')).data.token;
});
after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });

async function sg(aktion, params, { pfadGeheimnis = geheim, query = '' } = {}) {
  const res = await fetch(`${base}/sg/${pfadGeheimnis}/${aktion}${query}`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(params),
  });
  return { status: res.status, typ: res.headers.get('content-type'), text: await res.text() };
}

async function api(method, pfad, body, token, roh) {
  const headers = roh ? { 'Content-Type': 'audio/wav' } : { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(base + pfad, { method, headers, body: roh || (body && JSON.stringify(body)) });
  const typ = res.headers.get('content-type') || '';
  return { status: res.status, typ, data: typ.includes('json') ? await res.json() : Buffer.from(await res.arrayBuffer()) };
}

const neuerAnruf = (callId, from, extra = {}) => sg('anruf', { event: 'newCall', direction: 'in', from, to: '4930111222', callId, 'user[]': 'Max Meyer', ...extra });
const audioUrl = (xml) => xml.match(/<Url>([^<]+)<\/Url>/)[1];

// --------------------------------------------------------------------------------------------

test('Audio: Telefonqualität, Stille abschneiden, gleichmäßige Lautstärke', () => {
  const { rate, samples } = leseWav(fakeWav('Guten Tag'));
  const tel = normalisiere(resample(samples, rate, 8000));
  assert.ok(Math.abs(tel.length - Math.floor(samples.length * 8000 / 24000)) <= 1);
  assert.ok(Math.abs(Math.max(...tel) - 0.89) < 0.01);
  assert.equal(leseWav(schreibeWav(tel)).rate, 8000);
  const a = leseWav(aufnahmeWav(2));
  const getrimmt = trimmeStille(a.samples, a.rate);
  assert.ok(Math.abs(getrimmt.length / a.rate - 2.24) < 0.06, `${getrimmt.length / a.rate} s`);
});

test('Aussprache: Lautschrift für die KI-Stimme, SSML für eigene Gateways', () => {
  const lex = [
    { schreibweise: 'Nguyen', lautschrift: 'Nuien', ipa: '' },
    { schreibweise: 'Çelik', lautschrift: 'Tschelik', ipa: 't͡ʃeˈlik' },
  ];
  assert.equal(ttsText('Frau Nguyen und Herr Çelik', lex), 'Frau Nuien und Herr Tschelik');
  assert.equal(ssmlFragment('Nguyen & Çelik', lex), '<sub alias="Nuien">Nguyen</sub> &amp; <phoneme alphabet="ipa" ph="t͡ʃeˈlik">Çelik</phoneme>');
  assert.equal(gesprochenerText('NGUYEN', lex), 'Nuien');
  assert.equal(zerlege('Max Meyer', [{ schreibweise: 'Meyer' }]).length, 1, 'Einträge ohne Korrektur ändern nichts');
  assert.deepEqual(mergeLexika([{ schreibweise: 'Kraus', lautschrift: 'A' }], [{ schreibweise: 'kraus', lautschrift: 'B' }]).map((e) => e.lautschrift), ['B']);
});

test('Hilfsfunktionen', () => {
  assert.equal(waehlbar('+49 3641 000 200'), '493641000200');
  assert.equal(waehlbar('0171/1234567'), '491711234567');
  assert.equal(tempoProzent(0.48), 96);
});

test('Bausteine: feste Teile werden aufgenommen, nur der Name des Anrufers kommt von der KI', () => {
  const u = defaultUser();
  u.status = { modus: 'urlaub', bis: '2099-12-04', ganztags: true };
  const vip = { typ: 'praxis', anrede: 'Herr', titel: 'Prof. Dr.', nachname: 'Hoffmann', vip: true };
  const b = answerCall(u, { nummer: '+49897654321', kontakt: vip }).ansage.bausteine;
  assert.deepEqual(b.map((x) => x.key), [null, 'vorstellung', 'status.urlaub', null, 'vertretung.tmueller', 'weiterleitung.tmueller', 'abschlussBekannt']);
  assert.match(b[0].text, /^Guten (Morgen|Tag|Abend), Herr Prof\. Dr\. Hoffmann!$/);
  assert.equal(b[0].ersatz, 'gruss');
  assert.equal(b[3].optional, 'zeitangabe');
  assert.equal(b[4].text, 'In dringenden Fällen wenden Sie sich bitte an Thomas Müller, erreichbar unter 03641 000 200.', 'lesbare Nummer zum Vorlesen');

  const liste = alleBausteine(u);
  const keys = liste.map((x) => x.key);
  for (const k of ['gruss', 'vorstellung', 'status.standard', 'status.urlaub', 'status.feierabend', 'abschluss', 'abschlussBekannt', 'mailboxKurz', 'verbinden.tmueller', 'vorstellungDu']) {
    assert.ok(keys.includes(k), k);
  }
  assert.ok(keys.includes('status.termin.schulung'));
  assert.equal(liste.find((x) => x.key === 'status.termin.schulung').gebraucht, false, 'nicht genutzte Varianten sind optional');
  assert.equal(liste.find((x) => x.key === 'status.urlaub').gebraucht, true);
});

test('Mixer: KI zu langsam → Aufnahme "Guten Tag!", beim nächsten Anruf kommt der Name', async () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-mix-'));
  const u = defaultUser();
  const auf = new Aufnahmen(path.join(d, 'aufnahmen'));
  auf.speichere(u, 'gruss', 'Guten Tag!', aufnahmeWav(1));
  auf.speichere(u, 'vorstellung', 'x', aufnahmeWav(3));
  let freigabe;
  const langsam = { bereit: true, sprich: (text, { referenz }) => new Promise((r) => { freigabe = () => r(fakeWav(text)); assert.ok(referenz.length > 1000, 'Referenz aus eigenen Aufnahmen'); }) };
  const mixer = new AnsageMixer({ verzeichnis: path.join(d, 'audio'), aufnahmen: auf, stimme: langsam, geheim: 'x' });
  const bausteine = [{ key: null, ki: true, text: 'Guten Tag, Frau Kraus!', ersatz: 'gruss' }, { key: 'vorstellung', text: 'x' }];
  const t0 = Date.now();
  const erst = await mixer.ansage(u, bausteine, { wartezeitMs: 200 });
  assert.ok(Date.now() - t0 < 1000);
  assert.deepEqual(erst.quellen, ['aufnahme:gruss', 'aufnahme:vorstellung']);
  freigabe();
  await new Promise((r) => setTimeout(r, 20));
  const dann = await mixer.ansage(u, bausteine, { wartezeitMs: 200 });
  assert.deepEqual(dann.quellen, ['ki:Guten Tag, Frau Kraus!', 'aufnahme:vorstellung']);
  fs.rmSync(d, { recursive: true, force: true });
});

test('Aufnahmen über die App: Liste, Hochladen, Abspielen, veraltet nach Textänderung', async () => {
  const liste = await api('GET', '/api/app/aufnahmen', undefined, appToken);
  assert.equal(liste.status, 200);
  const vorstellung = liste.data.bausteine.find((b) => b.key === 'vorstellung');
  assert.equal(vorstellung.stand, 'fehlt');
  assert.equal(vorstellung.titel, 'Vorstellung');
  assert.match(vorstellung.text, /^Sie sind verbunden mit dem Anschluss von Max Meyer/);

  const hoch = await api('PUT', '/api/app/aufnahmen/vorstellung', undefined, appToken, aufnahmeWav(3));
  assert.equal(hoch.status, 200, JSON.stringify(hoch.data));
  assert.ok(Math.abs(hoch.data.sekunden - 3.2) < 0.1, 'Stille abgeschnitten');
  for (const k of ['gruss', 'abschluss', 'abschlussBekannt', 'status.standard', 'weiterleitung.tmueller', 'verbinden.tmueller', 'status.feierabend']) {
    assert.equal((await api('PUT', `/api/app/aufnahmen/${k}`, undefined, appToken, aufnahmeWav(1.5))).status, 200, k);
  }
  const zurueck = await api('GET', '/api/app/aufnahmen/vorstellung.wav', undefined, appToken);
  assert.equal(zurueck.typ, 'audio/wav');
  assert.equal(leseWav(zurueck.data).rate, 44100, 'Original in voller Qualität');

  assert.equal((await api('PUT', '/api/app/aufnahmen/vorstellung', undefined, appToken, schreibeWav(new Float32Array(44100), 44100))).status, 400, 'stille Aufnahme');
  assert.equal((await api('PUT', '/api/app/aufnahmen/gibtsnicht', undefined, appToken, aufnahmeWav(1))).status, 404);

  // Funktion ändert sich → Vorstellungstext ändert sich → Aufnahme veraltet
  const u = store.user('mmeyer');
  u.profil.funktion = 'Teamleiter';
  const neu = (await api('GET', '/api/users/mmeyer/aufnahmen')).data.bausteine.find((b) => b.key === 'vorstellung');
  assert.equal(neu.stand, 'veraltet');
  assert.match(neu.aufgenommenerText, /Kundenberater/);
  u.profil.funktion = 'Kundenberater';
});

test('Webhook mit falschem Geheimnis wird abgelehnt', async () => {
  const r = await sg('anruf', { event: 'newCall', from: '4989', to: '4930111222', callId: 'x' }, { pfadGeheimnis: 'falsch' });
  assert.equal(r.status, 404);
});

test('VIP-Kunde ruft an: Name von der KI in der Stimme der Aufnahmen, Rest aus Aufnahmen, Taste 1 verbindet', async () => {
  kiAuftraege.length = 0;
  const r = await neuerAnruf('c1', '49897654321', { diversion: '491719998877' });
  assert.equal(r.status, 200);
  assert.match(r.typ, /application\/xml/);
  assert.match(r.text, new RegExp(`<Response onHangup="https://ab\\.example\\.de/sg/${geheim}/ende\\?callId=c1">`));
  assert.match(r.text, new RegExp(`<Gather onData="https://ab\\.example\\.de/sg/${geheim}/daten\\?callId=c1" maxDigits="1" timeout="1500">`));
  const url = audioUrl(r.text);
  const wav = await fetch(base + new URL(url).pathname);
  assert.equal(leseWav(Buffer.from(await wav.arrayBuffer())).rate, 8000);

  // Nur der Begrüßungssatz ging an die KI – mit Lautschrift und Referenzstimme aus den Aufnahmen
  assert.equal(kiAuftraege.length, 1, JSON.stringify(kiAuftraege.map((k) => k.text)));
  assert.match(kiAuftraege[0].text, /^Guten (Morgen|Tag|Abend), Herr Prof\. Dr\. Hoff-mann!$/);
  assert.ok(kiAuftraege[0].referenz.length > 10000);

  const t = await sg('daten', { event: 'dtmf', dtmf: '1', callId: 'c1' }, { query: '?callId=c1' });
  assert.match(t.text, /<Gather [^>]*timeout="1"><Play><Url>/, 'aufgenommenes "Einen Moment bitte …"');
  assert.equal(kiAuftraege.length, 1, 'keine KI für "verbinden" – liegt als Aufnahme vor');
  const v = await sg('daten', { event: 'dtmf', callId: 'c1' }, { query: '?callId=c1' });
  assert.equal(v.text, '<?xml version="1.0" encoding="UTF-8"?><Response><Dial><Number>493641000200</Number></Dial></Response>');
  await sg('ende', { event: 'hangup', cause: 'normalClearing', callId: 'c1' }, { query: '?callId=c1' });
  assert.equal(store.nachrichten.filter((n) => n.nummer === '+49897654321').length, 0, 'weitergeleitet: kein Rückruf nötig');
});

test('Unbekannter Anrufer: komplett aus Aufnahmen, ohne KI', async () => {
  kiAuftraege.length = 0;
  await neuerAnruf('c0', '4922100000');
  assert.equal(kiAuftraege.length, 0);
});

test('Ohne Taste: sipgate-Mailbox, Eintrag in der Rückrufliste, zweiter Anruf aus dem Cache', async () => {
  await neuerAnruf('c2', '0401234567');
  const m = await sg('daten', { event: 'dtmf', callId: 'c2' }, { query: '?callId=c2' });
  assert.match(m.text, /<Dial><Voicemail \/><\/Dial>/);
  await sg('ende', { event: 'hangup', cause: 'normalClearing', callId: 'c2' }, { query: '?callId=c2' });
  const n = store.nachrichten.find((x) => x.nummer === '+49401234567');
  assert.equal(n.mailbox, true);
  assert.equal(n.kontakt.nachname, 'Schneider');
  assert.equal(n.prioritaet, 'hoch');
  assert.match(n.aufgabe.id, /^MOCK-/);
  const vorher = kiAuftraege.length;
  await neuerAnruf('c2b', '0401234567');
  assert.equal(kiAuftraege.length, vorher, 'Begrüßung kommt aus dem Cache');
});

test('Aufgelegt während der Ansage: Anruf ohne Nachricht', async () => {
  await neuerAnruf('c3', '4922199887');
  await sg('ende', { event: 'hangup', cause: 'cancel', callId: 'c3' }, { query: '?callId=c3' });
  const n = store.nachrichten.find((x) => x.nummer === '+4922199887');
  assert.equal(n.ohneNachricht, true);
  assert.equal(n.mailbox, false);
});

test('Mitarbeiter wird über die umleitende Handynummer (diversion) erkannt; fehlende Aufnahmen spricht die KI', async () => {
  kiAuftraege.length = 0;
  await sg('anruf', { event: 'newCall', direction: 'in', from: '4930999', to: '4930777000', callId: 'c4', diversion: '491605554433' });
  assert.ok(kiAuftraege.some((p) => p.text.includes('Anschluss von Thomas Müller')));
  assert.equal(kiAuftraege[0].referenz, undefined, 'ohne eigene Aufnahmen: Standardstimme');
});

test('Ausgehende Anrufe werden ignoriert, ohne Aufnahmen und KI geht es in die Mailbox', async () => {
  const aus = await sg('anruf', { event: 'newCall', direction: 'out', from: '4930111222', to: '4989', callId: 'c5' });
  assert.equal(aus.text, '<?xml version="1.0" encoding="UTF-8"?><Response />');

  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-fehler-'));
  const st = new Store(d);
  st.config.telefonie.publicUrl = BASIS;
  st.config.telefonie.stimme.url = 'http://stimme.intern:5000';
  const kaputt = async () => { throw new Error('Stimmdienst nicht erreichbar'); };
  const s = http.createServer(createApp(st, { fetchImpl: kaputt, env: {}, vorwaermenBeiStart: false }));
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const res = await fetch(`http://127.0.0.1:${s.address().port}/sg/${st.config.telefonie.sipgate.webhookGeheimnis}/anruf`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ event: 'newCall', direction: 'in', from: '4989', to: '4930111222', callId: 'f1' }),
  });
  assert.match(await res.text(), /<Dial><Voicemail \/><\/Dial>/);
  s.close();
});

test('App-API: Zugang, Synchronisierung, Vorschau als Text und als Telefon-Audio, Stimmtest', async () => {
  assert.equal((await api('GET', '/api/app/ich')).status, 401);
  const ich = await api('GET', '/api/app/ich', undefined, appToken);
  assert.equal(ich.data.name, 'Max Meyer');
  assert.equal(ich.data.telefonieBereit, true);
  assert.ok(ich.data.aufnahmen.vorhanden >= 5);

  const cfg = await api('GET', '/api/config');
  assert.equal(cfg.data.users[0].appTokenHash, undefined, 'Hash wird nicht ausgeliefert');
  assert.equal(cfg.data.telefonie.audioGeheimnis, undefined);
  assert.equal(cfg.data.telefonie.status.webhookUrl, `${BASIS}/sg/${geheim}/anruf`);

  const sync = await api('PUT', '/api/app/konfiguration', {
    version: '0.5.0',
    profil: { vorname: 'Max', nachname: 'Meyer', funktion: 'Kundenberater' },
    vertretungen: [{ id: 'v1', name: 'Gülşen Yılmaz', telefon: '0171 2223344' }],
    standardVertretungId: 'v1',
    vertretungNennenIn: ['urlaub', 'termin'],
    status: { modus: 'termin', art: 'online-praesentation', freitext: '', bis: '2099-01-01T15:00', ganztags: false },
    lexikon: [{ schreibweise: 'Gülşen Yılmaz', lautschrift: 'Gülschen Jilmas', ipa: '' }],
    stimme: { tempo: 0.5, pauseMs: 300 },
  }, appToken);
  assert.equal(sync.status, 200, JSON.stringify(sync.data));
  assert.equal(sync.data.aktuell.modus, 'termin');

  const v = await api('GET', '/api/app/vorschau', undefined, appToken);
  assert.match(v.data.text, /Ich bin gerade in einer Online-Präsentation/);
  assert.match(v.data.gesprochen, /an Gülschen Jilmas, erreichbar unter/);

  const wav = await api('GET', '/api/app/vorschau.wav', undefined, appToken);
  assert.equal(wav.typ, 'audio/wav');
  assert.equal(leseWav(wav.data).rate, 8000);

  const test = await api('POST', '/api/app/stimmtest', { text: 'Guten Tag, Herr Hoffmann!' }, appToken);
  assert.equal(test.typ, 'audio/wav');
  assert.ok(kiAuftraege.some((k) => k.text === 'Guten Tag, Herr Hoff-mann!'));

  assert.equal((await api('PUT', '/api/app/konfiguration', { status: { modus: 'quatsch' } }, appToken)).status, 400);
});

test('Verwaltung: Mailbox-Kurzansage und Aufnahmen hochladen', async () => {
  const m = await api('GET', '/api/users/mmeyer/mailbox-ansage.wav');
  assert.equal(m.typ, 'audio/wav');
  assert.ok(kiAuftraege.some((p) => p.text === 'Bitte sprechen Sie jetzt.'), 'ohne Aufnahme: KI');
  const hoch = await api('PUT', '/api/users/mmeyer/aufnahmen/mailboxKurz', undefined, undefined, aufnahmeWav(1));
  assert.equal(hoch.status, 200);
  assert.equal(hoch.data.quelle, 'web');
});

test('Sync übernimmt nur erlaubte Felder', () => {
  const u = defaultUser();
  const regelnVorher = structuredClone(u.regeln);
  uebernehmeAppKonfiguration(u, { regeln: [], cloud: { nummer: '+49999', mobilnummer: '0171 1' }, status: null, aufnahmen: { x: 1 } });
  assert.deepEqual(u.regeln, regelnVorher);
  assert.deepEqual(u.aufnahmen, {});
  assert.equal(u.cloud.nummer, '', 'Cloud-Nummer vergibt nur die Verwaltung');
  assert.equal(u.cloud.mobilnummer, '0171 1');
  assert.throws(() => uebernehmeAppKonfiguration(u, { kalender: [{ modus: 'urlaub', von: '2099-07-10', bis: '2099-07-01' }] }), SyncFehler);
});

test('ADMIN_TOKEN schützt die Verwaltung (auch Aufnahmen)', async () => {
  const s = http.createServer(createApp(new Store(fs.mkdtempSync(path.join(os.tmpdir(), 'ab-adm-'))), { env: { ADMIN_TOKEN: 'geheim' }, vorwaermenBeiStart: false }));
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const b = `http://127.0.0.1:${s.address().port}`;
  assert.equal((await fetch(b + '/api/config')).status, 401);
  assert.equal((await fetch(b + '/api/users/mmeyer/aufnahmen')).status, 401);
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
