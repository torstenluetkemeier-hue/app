// HTTP-Server: Konfigurations-API, Telefonie-Schnittstelle und Weboberfläche.
// Bewusst ohne externe Abhängigkeiten (nur Node.js ≥ 22).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Store } from './store.js';
import { createAdapter, CallerLookup } from './crm/index.js';
import { MOCK_KONTAKTE } from './crm/mock.js';
import { answerCall, resolveStatus } from './core/engine.js';
import { normalizeNumber } from './core/phone.js';
import { fromLocal } from './core/time.js';
import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN, REGEL_BEDINGUNGEN, DEFAULT_TEXTE, defaultUser } from './core/defaults.js';
import { notify } from './notify.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(HERE, '..', 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function createApp(store, { fetchImpl } = {}) {
  let adapter, lookup;
  const rebuildCrm = () => {
    adapter = createAdapter(store.config.crm, fetchImpl ? { fetchImpl } : {});
    lookup = new CallerLookup(adapter, store.config.crm.cacheMinuten);
  };
  rebuildCrm();

  // Laufende Anrufe (zwischen "incoming" und "recording")
  const anrufe = new Map();

  const getUser = (id) => {
    const u = store.user(id);
    if (!u) throw new HttpError(404, `Mitarbeiter ${id} nicht gefunden`);
    return u;
  };

  const findUserByTarget = (to) => {
    if (!to) return store.config.users[0];
    const byId = store.user(to);
    if (byId) return byId;
    const n = normalizeNumber(to);
    return store.config.users.find((u) => normalizeNumber(u.profil.durchwahl) === n) || null;
  };

  const publicConfig = () => {
    const c = structuredClone(store.config);
    for (const k of ['qto', 'zswork']) if (c.crm[k]?.apiToken) c.crm[k].apiToken = '••••••';
    return c;
  };

  async function handleCall({ userId, to, from, zeit, override }) {
    let user = userId ? getUser(userId) : findUserByTarget(to);
    if (!user) throw new HttpError(404, 'Kein Mitarbeiter für diese Zielnummer');
    // Vorschau mit noch nicht gespeicherten Einstellungen (z. B. Ansagetexte, Status)
    if (override) {
      user = { ...user };
      for (const k of ['status', 'texte', 'regeln', 'optionen']) if (override[k] !== undefined) user[k] = override[k];
    }
    const nummer = normalizeNumber(from);
    const now = zeit ? fromLocal(zeit) : new Date();
    const t0 = Date.now();
    const suche = user.optionen?.anruferErkennung === false ? { kontakt: null, fehler: null } : await lookup.find(nummer);
    const kontakt = suche.kontakt;
    const antwort = answerCall(user, { nummer, kontakt }, now);
    antwort.crm = { adapter: adapter.name, dauerMs: Date.now() - t0, fehler: suche.fehler, ausCache: !!suche.ausCache };
    return { user, antwort };
  }

  const routes = [
    ['GET', /^\/api\/meta$/, () => ({
      modi: MODI, terminArten: TERMIN_ARTEN, abwesendArten: ABWESEND_ARTEN, regelBedingungen: REGEL_BEDINGUNGEN,
      standardTexte: DEFAULT_TEXTE,
      testAnrufer: MOCK_KONTAKTE.map((k) => ({
        nummer: k.telefonnummern[0],
        label: `${[k.anrede, k.titel, k.vorname, k.nachname].filter(Boolean).join(' ') || k.organisation} – ${k.organisation} (${k.typ}${k.vip ? ', VIP' : ''})`,
      })),
    })],
    ['GET', /^\/api\/config$/, () => publicConfig()],

    ['PUT', /^\/api\/crm$/, (_, body) => {
      const crm = store.config.crm;
      for (const k of ['adapter', 'timeoutMs', 'cacheMinuten']) if (body[k] !== undefined) crm[k] = body[k];
      for (const sys of ['qto', 'zswork']) {
        if (!body[sys]) continue;
        const { apiToken, ...rest } = body[sys];
        Object.assign(crm[sys], rest);
        if (apiToken && apiToken !== '••••••') crm[sys].apiToken = apiToken;
      }
      store.saveConfig();
      rebuildCrm();
      return publicConfig().crm;
    }],
    ['POST', /^\/api\/crm\/test$/, async (_, body) => {
      const health = await adapter.healthCheck();
      const nummer = normalizeNumber(body.nummer);
      const suche = nummer ? await new CallerLookup(adapter, 0).find(nummer) : null;
      return { adapter: adapter.name, health, nummer, suche };
    }],

    ['POST', /^\/api\/users$/, (_, body) => {
      const id = String(body.id || '').trim().toLowerCase().replace(/[^a-z0-9._-]/g, '');
      if (!id) throw new HttpError(400, 'Kürzel fehlt');
      if (store.user(id)) throw new HttpError(409, 'Kürzel existiert bereits');
      const u = defaultUser();
      Object.assign(u, { id, kalender: [], status: null });
      u.profil = { ...u.profil, vorname: body.vorname || '', nachname: body.nachname || '', email: '', durchwahl: '' };
      store.config.users.push(u);
      store.saveConfig();
      return u;
    }],
    ['GET', /^\/api\/users\/([\w.-]+)$/, ([id]) => getUser(id)],
    ['PUT', /^\/api\/users\/([\w.-]+)$/, ([id], body) => {
      const u = getUser(id);
      for (const k of ['profil', 'firma', 'geschaeftszeiten', 'vertretungen', 'standardVertretungId', 'regeln', 'optionen', 'texte', 'kalender']) {
        if (body[k] !== undefined) u[k] = body[k];
      }
      store.saveConfig();
      return u;
    }],
    ['PUT', /^\/api\/users\/([\w.-]+)\/status$/, ([id], body) => {
      const u = getUser(id);
      u.status = body && body.modus ? {
        modus: body.modus, art: body.art || '', freitext: body.freitext || '', bis: body.bis || '',
        ganztags: !!body.ganztags, vertretungId: body.vertretungId, notiz: body.notiz || '', gesetztAm: new Date().toISOString(),
      } : null;
      store.saveConfig();
      return { status: u.status, aktuell: resolveStatus(u) };
    }],
    ['POST', /^\/api\/users\/([\w.-]+)\/kalender$/, ([id], body) => {
      const u = getUser(id);
      if (!body.von || !body.bis || !MODI[body.modus]) throw new HttpError(400, 'Modus, von und bis sind Pflicht');
      if (body.bis < body.von) throw new HttpError(400, '„bis“ liegt vor „von“');
      const e = {
        id: crypto.randomUUID().slice(0, 8), modus: body.modus, art: body.art || '', freitext: body.freitext || '',
        titel: body.titel || '', von: body.von, bis: body.bis, ganztags: !!body.ganztags,
        vertretungId: body.vertretungId || undefined, notiz: body.notiz || '', aktiv: true,
      };
      u.kalender.push(e);
      u.kalender.sort((a, b) => a.von.localeCompare(b.von));
      store.saveConfig();
      return e;
    }],
    ['DELETE', /^\/api\/users\/([\w.-]+)\/kalender\/([\w-]+)$/, ([id, eid]) => {
      const u = getUser(id);
      u.kalender = u.kalender.filter((e) => e.id !== eid);
      store.saveConfig();
      return { ok: true };
    }],

    // Vorschau: was hört ein Anrufer mit dieser Nummer zu diesem Zeitpunkt?
    ['POST', /^\/api\/vorschau$/, async (_, body) => (await handleCall(body)).antwort],

    // --- Telefonie-Schnittstelle (wird von der Telefonanlage / dem Voicebot aufgerufen) ---
    ['POST', /^\/api\/telephony\/incoming$/, async (_, body) => {
      const { user, antwort } = await handleCall({ to: body.to, userId: body.userId, from: body.from, zeit: body.zeit });
      const callId = body.callId || crypto.randomUUID();
      anrufe.set(callId, { userId: user.id, antwort, start: new Date().toISOString(), weitergeleitet: null });
      setTimeout(() => anrufe.delete(callId), 30 * 60_000).unref();
      return { callId, ablauf: antwort.ablauf, status: antwort.status, anrufer: antwort.anrufer };
    }],
    ['POST', /^\/api\/telephony\/dtmf$/, (_, body) => {
      const call = anrufe.get(body.callId);
      if (!call) throw new HttpError(404, 'Unbekannter Anruf');
      const auswahl = call.antwort.ablauf.find((s) => s.typ === 'auswahl' && s.taste === String(body.taste));
      if (!auswahl) return { aktion: 'ignorieren' };
      call.weitergeleitet = auswahl.ziel;
      return { aktion: 'weiterleiten', ziel: auswahl.ziel, ansage: `Einen Moment bitte, ich verbinde Sie mit ${auswahl.ziel.name}.` };
    }],
    ['POST', /^\/api\/telephony\/recording$/, async (_, body) => {
      const call = anrufe.get(body.callId);
      if (!call) throw new HttpError(404, 'Unbekannter Anruf');
      anrufe.delete(body.callId);
      return saveMessage(getUser(call.userId), call.antwort, body);
    }],

    ['GET', /^\/api\/nachrichten$/, (q) => store.nachrichten.filter((n) => !q.userId || n.userId === q.userId)],
    ['PATCH', /^\/api\/nachrichten\/([\w-]+)$/, ([id], body) => {
      const n = store.nachrichten.find((x) => x.id === id);
      if (!n) throw new HttpError(404, 'Nachricht nicht gefunden');
      if (body.erledigt !== undefined) n.erledigt = !!body.erledigt;
      store.saveMessages();
      return n;
    }],
    ['DELETE', /^\/api\/nachrichten\/([\w-]+)$/, ([id]) => {
      store.nachrichten = store.nachrichten.filter((x) => x.id !== id);
      store.saveMessages();
      return { ok: true };
    }],
  ];

  async function saveMessage(user, antwort, body) {
    const k = antwort.anrufer.kontakt;
    const wer = k ? [k.anrede, k.titel, k.nachname].filter(Boolean).join(' ') || k.organisation : antwort.anrufer.nummer || 'Anonym';
    const nachricht = {
      id: crypto.randomUUID().slice(0, 8),
      userId: user.id,
      zeit: new Date().toISOString(),
      nummer: antwort.anrufer.nummer,
      kontakt: k,
      status: antwort.status.label,
      prioritaet: antwort.rueckruf.prioritaet,
      dauerSekunden: body.dauerSekunden || 0,
      transkript: body.transkript || '',
      aufnahmeUrl: body.aufnahmeUrl || null,
      erledigt: false,
      aufgabe: null,
      benachrichtigung: null,
    };
    if (antwort.rueckruf.aufgabe) {
      try {
        nachricht.aufgabe = await adapter.createCallbackTask({
          userId: user.id,
          titel: `Rückruf: ${wer}${k?.organisation && wer !== k.organisation ? ` (${k.organisation})` : ''}`,
          beschreibung: nachricht.transkript || 'Nachricht auf dem Anrufbeantworter',
          prioritaet: nachricht.prioritaet,
          kontakt: k,
          nummer: nachricht.nummer,
          aufnahmeUrl: nachricht.aufnahmeUrl,
        });
        nachricht.aufgabe.system = adapter.name;
      } catch (e) {
        nachricht.aufgabe = { fehler: e.message, system: adapter.name };
      }
    }
    nachricht.benachrichtigung = await notify(user, nachricht, fetchImpl);
    store.nachrichten.unshift(nachricht);
    store.saveMessages();
    return nachricht;
  }

  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (url.pathname.startsWith('/api/')) {
        const body = ['POST', 'PUT', 'PATCH'].includes(req.method) ? await readJson(req) : {};
        for (const [method, re, fn] of routes) {
          if (method !== req.method) continue;
          const m = url.pathname.match(re);
          if (!m) continue;
          const params = m.length > 1 ? m.slice(1) : Object.fromEntries(url.searchParams);
          return send(res, 200, await fn(params, body));
        }
        throw new HttpError(404, 'Unbekannter Endpunkt');
      }
      return serveStatic(url.pathname, res);
    } catch (e) {
      const status = e.status || 500;
      if (status === 500) console.error(e);
      return send(res, status, { fehler: e.message });
    }
  };
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 1_000_000) throw new HttpError(413, 'Anfrage zu groß');
  }
  if (!raw) return {};
  try { return JSON.parse(raw); } catch { throw new HttpError(400, 'Ungültiges JSON'); }
}

function send(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

function serveStatic(pathname, res) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const file = path.normalize(path.join(PUBLIC, rel));
  if (!file.startsWith(PUBLIC) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); return res.end('Nicht gefunden');
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const port = Number(process.env.PORT || 8080);
  const host = process.env.HOST || '127.0.0.1';
  const store = new Store(process.env.DATA_DIR || path.join(HERE, '..', 'data'));
  http.createServer(createApp(store)).listen(port, host, () => {
    console.log(`Anrufbeantworter läuft auf http://${host}:${port}`);
  });
}
