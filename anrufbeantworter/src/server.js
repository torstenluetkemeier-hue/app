// HTTP-Server: Verwaltungs-API + Weboberfläche, App-API für die iPhone-App,
// Webhooks für sipgate.io (Cloud-Anrufbeantworter). Ohne externe Abhängigkeiten (Node.js ≥ 22).
//
// Alle Dienste aus Deutschland: Telefonie über sipgate (Düsseldorf), Sprachausgabe mit Piper
// auf dem eigenen Server, Betrieb in einem deutschen Rechenzentrum.
//
// Zugriffsschutz:
//   /api/app/*        Bearer-Token des Mitarbeiters (in der Weboberfläche erzeugt, in der App eingetragen)
//   /sg/<geheim>/*    sipgate-Webhooks; sipgate signiert nicht, daher geheimer Pfadbestandteil (+ HTTPS)
//   /audio/<hash>.wav nicht erratbare Dateinamen (HMAC), werden nach 24 h gelöscht
//   /api/*            sonst: ADMIN_TOKEN (falls gesetzt) – ohne ADMIN_TOKEN nur für localhost gedacht

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
import { mergeLexika, ansageSsml, ttsText } from './core/aussprache.js';
import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN, REGEL_BEDINGUNGEN, DEFAULT_TEXTE, defaultUser } from './core/defaults.js';
import { notify } from './notify.js';
import { uebernehmeAppKonfiguration, SyncFehler } from './appsync.js';
import * as sipgate from './telephony/sipgate.js';
import { PiperTts, PIPER_STIMMEN } from './tts/piper.js';
import { AnsageAudio } from './tts/ansageAudio.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(HERE, '..', 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
const MASKE = '••••••';

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const gleich = (a, b) => {
  const x = Buffer.from(sha256(String(a)));
  const y = Buffer.from(sha256(String(b)));
  return crypto.timingSafeEqual(x, y);
};

/** Sprechtempo der App (iOS-Rate, 0,5 = normal) in Prozent. */
export function tempoProzent(tempo) {
  if (!tempo) return 100;
  return Math.max(70, Math.min(130, Math.round((tempo / 0.5) * 100)));
}

/** Binäre Antwort (WAV) aus einer Route. */
class Wav {
  constructor(daten) { this.daten = daten; }
}

export function createApp(store, { fetchImpl, env = process.env, vorwaermenBeiStart = true } = {}) {
  let adapter, lookup;
  const rebuildCrm = () => {
    adapter = createAdapter(store.config.crm, fetchImpl ? { fetchImpl } : {});
    lookup = new CallerLookup(adapter, store.config.crm.cacheMinuten);
  };
  rebuildCrm();

  const tel = () => store.config.telefonie;
  const basisUrl = () => (env.PUBLIC_URL || tel().publicUrl || '').replace(/\/+$/, '');
  const webhookGeheimnis = () => env.SIPGATE_WEBHOOK_SECRET || tel().sipgate.webhookGeheimnis;
  const sgBasis = () => `${basisUrl()}/sg/${webhookGeheimnis()}`;

  let tts, audio;
  const rebuildTts = () => {
    tts = new PiperTts({ url: env.PIPER_URL || tel().tts.piperUrl, stimme: tel().tts.stimme, fetchImpl });
    audio = new AnsageAudio({ verzeichnis: path.join(store.dir, 'audio'), tts, geheim: tel().audioGeheimnis });
  };
  rebuildTts();
  setInterval(() => audio.aufraeumen(), 3600_000).unref();

  // Laufende Anrufe (sipgate callId → Zustand)
  const anrufe = new Map();
  const merkeAnruf = (callId, daten) => {
    anrufe.set(callId, { ...daten, start: new Date().toISOString(), nachrichtId: null, phase: 'ansage', mailbox: false, weitergeleitet: null });
    setTimeout(() => anrufe.delete(callId), 2 * 3600_000).unref();
  };

  const getUser = (id) => {
    const u = store.user(id);
    if (!u) throw new HttpError(404, `Mitarbeiter ${id} nicht gefunden`);
    return u;
  };

  /** Welcher Mitarbeiter ist gemeint? Eigene sipgate-Nummer, umleitende Handynummer (diversion) oder Durchwahl. */
  const findeMitarbeiter = ({ to, umgeleitetVon } = {}) => {
    const users = store.config.users;
    if (!to && !umgeleitetVon) return users[0];
    const byId = to && store.user(to);
    if (byId) return byId;
    const n = normalizeNumber(to);
    const u = normalizeNumber(umgeleitetVon);
    return users.find((x) => u && [x.cloud?.mobilnummer, x.profil.durchwahl].some((m) => normalizeNumber(m) === u))
      || users.find((x) => n && normalizeNumber(x.cloud?.nummer) === n)
      || users.find((x) => n && normalizeNumber(x.profil.durchwahl) === n)
      || (users.length === 1 ? users[0] : null);
  };

  const telefonieStatus = () => ({
    ttsBereit: tts.bereit,
    publicUrl: basisUrl(),
    webhookUrl: basisUrl() ? `${sgBasis()}/anruf` : null,
    hangupUrl: basisUrl() ? `${sgBasis()}/ende` : null,
  });

  const publicConfig = () => {
    const c = structuredClone(store.config);
    for (const k of ['qto', 'zswork']) if (c.crm[k]?.apiToken) c.crm[k].apiToken = MASKE;
    delete c.telefonie.audioGeheimnis;
    c.telefonie.status = telefonieStatus();
    for (const u of c.users) {
      u.appZugang = !!u.appTokenHash;
      delete u.appTokenHash;
    }
    return c;
  };

  const lexikonFuer = (user) => mergeLexika(store.config.lexikon, user.lexikon);

  async function handleCall({ userId, to, umgeleitetVon, from, zeit, override }) {
    let user = userId ? getUser(userId) : findeMitarbeiter({ to, umgeleitetVon });
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
    const antwort = answerCall(user, { nummer, kontakt: suche.kontakt }, now);
    antwort.crm = { adapter: adapter.name, dauerMs: Date.now() - t0, fehler: suche.fehler, ausCache: !!suche.ausCache };
    const lexikon = lexikonFuer(user);
    antwort.ansage.ssml = ansageSsml(antwort.ansage.abschnitte, { lexikon, pauseMs: user.stimme?.pauseMs, tempoProzent: tempoProzent(user.stimme?.tempo) });
    antwort.ansage.gesprochen = antwort.ansage.abschnitte.map((a) => ttsText(a.text, lexikon, { ipaInline: tel().tts.ipaInline })).join(' ');
    return { user, antwort };
  }

  /** Ansage als Telefon-WAV (Cache je Abschnitt). */
  const audioFuer = (user, abschnitte) => audio.ansage(abschnitte, {
    lexikon: lexikonFuer(user),
    pauseMs: user.stimme?.pauseMs ?? 450,
    tempoProzent: tempoProzent(user.stimme?.tempo),
    ipaInline: tel().tts.ipaInline,
  });

  /**
   * Ansagen im Voraus erzeugen, damit Anrufe sofort beantwortet werden: für unbekannte Anrufer
   * komplett, für erkannte Anrufer alle Sätze außer der persönlichen Begrüßung (Cache je Satz).
   */
  const vorwaermen = (user) => {
    if (!tts.bereit) return;
    const beispiele = [
      null,
      { typ: 'praxis', anrede: 'Frau', nachname: 'Beispiel', vip: false },
      { typ: 'praxis', anrede: 'Frau', nachname: 'Beispiel', vip: true, betreuerId: user.id },
    ];
    (async () => {
      for (const kontakt of beispiele) {
        const antwort = answerCall(user, { nummer: kontakt ? '+490' : null, kontakt });
        await audioFuer(user, antwort.ansage.abschnitte);
      }
    })().catch((e) => console.warn('Vorab-Erzeugung der Ansage fehlgeschlagen:', e.message));
  };
  if (vorwaermenBeiStart) setTimeout(() => store.config.users.forEach(vorwaermen), 100).unref();

  const wavFuerText = async (text) => new Wav(fs.readFileSync((await audio.ansage([{ text }], {})).datei));

  // ---------------------------------------------------------------- Verwaltung (Admin)
  const adminRoutes = [
    ['GET', /^\/api\/meta$/, () => ({
      modi: MODI, terminArten: TERMIN_ARTEN, abwesendArten: ABWESEND_ARTEN, regelBedingungen: REGEL_BEDINGUNGEN,
      standardTexte: DEFAULT_TEXTE, stimmen: PIPER_STIMMEN,
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
        if (apiToken && apiToken !== MASKE) crm[sys].apiToken = apiToken;
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

    ['PUT', /^\/api\/telefonie$/, (_, body) => {
      const t = tel();
      if (typeof body.publicUrl === 'string') t.publicUrl = body.publicUrl.trim();
      if (body.sipgate) {
        if (typeof body.sipgate.mailbox === 'boolean') t.sipgate.mailbox = body.sipgate.mailbox;
        if (body.sipgate.neuesGeheimnis) t.sipgate.webhookGeheimnis = crypto.randomBytes(18).toString('base64url');
      }
      if (body.tts) {
        if (typeof body.tts.piperUrl === 'string') t.tts.piperUrl = body.tts.piperUrl.trim();
        if (typeof body.tts.stimme === 'string') t.tts.stimme = body.tts.stimme.trim();
        if (typeof body.tts.ipaInline === 'boolean') t.tts.ipaInline = body.tts.ipaInline;
      }
      store.saveConfig();
      rebuildTts();
      return publicConfig().telefonie;
    }],
    ['POST', /^\/api\/tts\/test$/, async (_, body) => wavFuerText(String(body.text || 'Guten Tag! Dies ist ein Test der Sprachausgabe.').slice(0, 500))],
    // Kurze Ansage für die sipgate-Mailbox (dort einmal hochladen, damit nach unserer Ansage nur noch der Signalton folgt)
    ['GET', /^\/api\/mailbox-ansage\.wav$/, async () => wavFuerText('Bitte sprechen Sie jetzt.')],
    ['PUT', /^\/api\/lexikon$/, (_, body) => {
      if (!Array.isArray(body.lexikon)) throw new HttpError(400, 'lexikon fehlt');
      store.config.lexikon = body.lexikon
        .map((e) => ({ schreibweise: String(e.schreibweise || '').trim(), lautschrift: String(e.lautschrift || '').trim(), ipa: String(e.ipa || '').trim() }))
        .filter((e) => e.schreibweise);
      store.saveConfig();
      return store.config.lexikon;
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
    ['GET', /^\/api\/users\/([\w.-]+)$/, ([id]) => publicConfig().users.find((u) => u.id === getUser(id).id)],
    ['PUT', /^\/api\/users\/([\w.-]+)$/, ([id], body) => {
      const u = getUser(id);
      for (const k of ['profil', 'firma', 'geschaeftszeiten', 'vertretungen', 'standardVertretungId', 'regeln', 'optionen', 'texte', 'kalender', 'lexikon', 'stimme', 'cloud']) {
        if (body[k] !== undefined) u[k] = body[k];
      }
      store.saveConfig();
      vorwaermen(u);
      return publicConfig().users.find((x) => x.id === u.id);
    }],
    // Zugangsschlüssel für die iPhone-App. Wird nur einmal angezeigt, gespeichert wird der Hash.
    ['POST', /^\/api\/users\/([\w.-]+)\/app-zugang$/, ([id]) => {
      const u = getUser(id);
      const token = `ab_${u.id}_${crypto.randomBytes(24).toString('base64url')}`;
      u.appTokenHash = sha256(token);
      store.saveConfig();
      return { token, serverUrl: basisUrl() || null };
    }],
    ['DELETE', /^\/api\/users\/([\w.-]+)\/app-zugang$/, ([id]) => {
      getUser(id).appTokenHash = null;
      store.saveConfig();
      return { ok: true };
    }],
    ['PUT', /^\/api\/users\/([\w.-]+)\/status$/, ([id], body) => {
      const u = getUser(id);
      u.status = body && body.modus ? {
        modus: body.modus, art: body.art || '', freitext: body.freitext || '', bis: body.bis || '',
        ganztags: !!body.ganztags, vertretungId: body.vertretungId, notiz: body.notiz || '', gesetztAm: new Date().toISOString(),
      } : null;
      store.saveConfig();
      vorwaermen(u);
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
    // Dieselbe Vorschau als Audio in Telefonqualität (Piper-Stimme, 8 kHz)
    ['POST', /^\/api\/vorschau\/audio$/, async (_, body) => {
      const { user, antwort } = await handleCall(body);
      return new Wav(fs.readFileSync((await audioFuer(user, antwort.ansage.abschnitte)).datei));
    }],

    // Generische Telefonie-Schnittstelle (eigenes Voice-Gateway, z. B. Asterisk an einem deutschen SIP-Trunk)
    ['POST', /^\/api\/telephony\/incoming$/, async (_, body) => {
      const { user, antwort } = await handleCall({ to: body.to, umgeleitetVon: body.umgeleitetVon, userId: body.userId, from: body.from, zeit: body.zeit });
      const callId = body.callId || crypto.randomUUID();
      merkeAnruf(callId, { userId: user.id, antwort });
      return { callId, ablauf: antwort.ablauf, status: antwort.status, anrufer: antwort.anrufer, ssml: antwort.ansage.ssml, gesprochen: antwort.ansage.gesprochen };
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
      const n = store.nachricht(id);
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

  // ---------------------------------------------------------------- App-API (iPhone)
  const appUser = (req) => {
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
    const hash = token && sha256(token);
    const u = hash && store.config.users.find((x) => x.appTokenHash && x.appTokenHash.length === hash.length
      && crypto.timingSafeEqual(Buffer.from(x.appTokenHash), Buffer.from(hash)));
    if (!u) throw new HttpError(401, 'Zugangsschlüssel ungültig');
    return u;
  };

  const appRoutes = [
    ['GET', /^\/api\/app\/ich$/, (u) => ({
      id: u.id,
      name: `${u.profil.vorname} ${u.profil.nachname}`.trim(),
      cloudNummer: u.cloud?.nummer || '',
      mobilnummer: u.cloud?.mobilnummer || '',
      stimme: PIPER_STIMMEN[tel().tts.stimme] || tel().tts.stimme,
      telefonieBereit: !!(tts.bereit && basisUrl()),
      mailbox: tel().sipgate.mailbox !== false,
      letzteSynchronisierung: u.appSync?.zeit || null,
      aktuell: resolveStatus(u),
    })],
    ['PUT', /^\/api\/app\/konfiguration$/, (u, body) => {
      try {
        uebernehmeAppKonfiguration(u, body);
      } catch (e) {
        if (e instanceof SyncFehler) throw new HttpError(400, e.message);
        throw e;
      }
      store.saveConfig();
      vorwaermen(u);
      return { ok: true, zeit: u.appSync.zeit, aktuell: resolveStatus(u) };
    }],
    ['GET', /^\/api\/app\/vorschau$/, async (u, _, q) => {
      const { antwort } = await handleCall({ userId: u.id, from: q.from || null });
      return { text: antwort.ansage.text, gesprochen: antwort.ansage.gesprochen, status: antwort.status, anrufer: antwort.anrufer };
    }],
    // So klingt die Ansage am Telefon (Cloud-Stimme, 8 kHz)
    ['GET', /^\/api\/app\/vorschau\.wav$/, async (u, _, q) => {
      const { antwort } = await handleCall({ userId: u.id, from: q.from || null });
      return new Wav(fs.readFileSync((await audioFuer(u, antwort.ansage.abschnitte)).datei));
    }],
    ['GET', /^\/api\/app\/nachrichten$/, (u) => store.nachrichten.filter((n) => n.userId === u.id).slice(0, 200)
      .map(({ aufnahmeUrl, benachrichtigung, ...n }) => n)],
    ['PATCH', /^\/api\/app\/nachrichten\/([\w-]+)$/, (u, body, _, [id]) => {
      const n = store.nachricht(id);
      if (!n || n.userId !== u.id) throw new HttpError(404, 'Nachricht nicht gefunden');
      if (body.erledigt !== undefined) n.erledigt = !!body.erledigt;
      store.saveMessages();
      return { ok: true, erledigt: n.erledigt };
    }],
  ];

  // ---------------------------------------------------------------- sipgate.io-Webhooks
  const sipgateRoutes = {
    // Neuer Anruf (umgeleitet vom Diensthandy oder direkt auf die sipgate-Nummer)
    anruf: async (p) => {
      if (p.direction && p.direction !== 'in') return sipgate.leerXml();
      const callId = p.callId || crypto.randomUUID();
      try {
        const { user, antwort } = await handleCall({ to: p.to, umgeleitetVon: p.diversion, from: p.from });
        merkeAnruf(callId, { userId: user.id, antwort });
        const datei = await audioFuer(user, antwort.ansage.abschnitte);
        const q = `callId=${encodeURIComponent(callId)}`;
        return sipgate.ansageXml({
          audioUrl: `${basisUrl()}/audio/${datei.name}`,
          datenUrl: `${sgBasis()}/daten?${q}`,
          hangupUrl: `${sgBasis()}/ende?${q}`,
        });
      } catch (e) {
        // Lieber die Mailbox als ein abgebrochener Anruf
        console.error('sipgate /anruf:', e.message);
        return tel().sipgate.mailbox !== false ? sipgate.mailboxXml() : sipgate.auflegenXml();
      }
    },
    // Ende der Ansage bzw. gedrückte Taste (Gather onData)
    daten: async (p, q) => {
      const call = anrufe.get(q.callId);
      if (!call) return sipgate.mailboxXml();
      const ablauf = call.antwort.ablauf;
      if (call.phase === 'verbinden') return sipgate.waehleXml(call.weitergeleitet.telefon);
      const taste = String(p.dtmf || '');
      const auswahl = ablauf.find((s) => s.typ === 'auswahl');
      const direkt = ablauf.find((s) => s.typ === 'weiterleiten');
      if (auswahl && taste === auswahl.taste) {
        call.phase = 'verbinden';
        call.weitergeleitet = auswahl.ziel;
        const user = getUser(call.userId);
        const datei = await audioFuer(user, [{ text: `Einen Moment bitte, ich verbinde Sie mit ${auswahl.ziel.name}.` }]);
        return sipgate.ansageXml({ audioUrl: `${basisUrl()}/audio/${datei.name}`, datenUrl: `${sgBasis()}/daten?callId=${encodeURIComponent(q.callId)}`, timeoutMs: 1 });
      }
      if (direkt) {
        call.weitergeleitet = direkt.ziel;
        return sipgate.waehleXml(direkt.ziel.telefon);
      }
      if (ablauf.some((s) => s.typ === 'aufnahme') && tel().sipgate.mailbox !== false) {
        call.mailbox = true;
        return sipgate.mailboxXml();
      }
      return sipgate.auflegenXml();
    },
    // Anruf beendet: in die Rückrufliste (sipgate verwirft die Antwort)
    ende: async (p, q) => {
      const call = anrufe.get(q.callId);
      if (call && !call.nachrichtId && !call.weitergeleitet) {
        const n = await saveMessage(getUser(call.userId), call.antwort, { mailbox: call.mailbox, ohneNachricht: !call.mailbox, ursache: p.cause });
        call.nachrichtId = n.id;
      }
      return sipgate.leerXml();
    },
  };

  function baueNachricht(user, antwort, body) {
    return {
      id: crypto.randomUUID().slice(0, 8),
      userId: user.id,
      zeit: new Date().toISOString(),
      nummer: antwort.anrufer.nummer,
      kontakt: antwort.anrufer.kontakt,
      status: antwort.status.label,
      prioritaet: antwort.rueckruf.prioritaet,
      dauerSekunden: body.dauerSekunden || 0,
      transkript: body.transkript || '',
      aufnahmeUrl: body.aufnahmeUrl || null,
      // true: Anrufer wurde an die sipgate-Mailbox übergeben (Aufnahme liegt dort)
      mailbox: !!body.mailbox,
      ohneNachricht: !!body.ohneNachricht,
      erledigt: false,
      aufgabe: null,
      benachrichtigung: null,
    };
  }

  async function saveMessage(user, antwort, body) {
    const nachricht = baueNachricht(user, antwort, body);
    const k = nachricht.kontakt;
    const wer = k ? [k.anrede, k.titel, k.nachname].filter(Boolean).join(' ') || k.organisation : nachricht.nummer || 'Anonym';
    if (antwort.rueckruf.aufgabe) {
      try {
        nachricht.aufgabe = await adapter.createCallbackTask({
          userId: user.id,
          titel: `Rückruf: ${wer}${k?.organisation && wer !== k.organisation ? ` (${k.organisation})` : ''}`,
          beschreibung: nachricht.transkript || (nachricht.mailbox ? 'Nachricht in der sipgate-Mailbox' : 'Anruf auf dem Anrufbeantworter'),
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

  // ---------------------------------------------------------------- Zugriffsschutz
  const pruefeAdmin = (req) => {
    if (!env.ADMIN_TOKEN) return;
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : req.headers['x-admin-token'] || '';
    if (!gleich(token, env.ADMIN_TOKEN)) throw new HttpError(401, 'Admin-Zugang erforderlich');
  };

  // ---------------------------------------------------------------- Routing
  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    try {
      const sg = url.pathname.match(/^\/sg\/([\w-]+)\/(anruf|daten|ende)$/);
      if (sg) {
        if (req.method !== 'POST' || !gleich(sg[1], webhookGeheimnis())) throw new HttpError(404, 'Unbekannter Endpunkt');
        const params = await readBody(req);
        const antwortXml = await sipgateRoutes[sg[2]](params, Object.fromEntries(url.searchParams));
        res.writeHead(200, { 'Content-Type': 'application/xml; charset=utf-8', 'Cache-Control': 'no-store' });
        return res.end(antwortXml);
      }
      const au = url.pathname.match(/^\/audio\/([a-f0-9]{40}\.wav)$/);
      if (au && req.method === 'GET') {
        const datei = audio.pfad(au[1]);
        if (!datei) throw new HttpError(404, 'Nicht gefunden');
        res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': fs.statSync(datei).size, 'Cache-Control': 'private, max-age=3600' });
        return fs.createReadStream(datei).pipe(res);
      }
      if (url.pathname.startsWith('/api/app/')) {
        const user = appUser(req);
        const body = ['POST', 'PUT', 'PATCH'].includes(req.method) ? await readBody(req) : {};
        for (const [method, re, fn] of appRoutes) {
          const mm = method === req.method && url.pathname.match(re);
          if (mm) return send(res, 200, await fn(user, body, Object.fromEntries(url.searchParams), mm.slice(1)));
        }
        throw new HttpError(404, 'Unbekannter Endpunkt');
      }
      if (url.pathname.startsWith('/api/')) {
        pruefeAdmin(req);
        const body = ['POST', 'PUT', 'PATCH'].includes(req.method) ? await readBody(req) : {};
        for (const [method, re, fn] of adminRoutes) {
          if (method !== req.method) continue;
          const mm = url.pathname.match(re);
          if (!mm) continue;
          const params = mm.length > 1 ? mm.slice(1) : Object.fromEntries(url.searchParams);
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

async function readBody(req) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 2_000_000) throw new HttpError(413, 'Anfrage zu groß');
  }
  if (!raw) return {};
  if ((req.headers['content-type'] || '').includes('application/x-www-form-urlencoded')) {
    return Object.fromEntries(new URLSearchParams(raw));
  }
  try { return JSON.parse(raw); } catch { throw new HttpError(400, 'Ungültiges JSON'); }
}

function send(res, status, data) {
  if (data instanceof Wav) {
    res.writeHead(status, { 'Content-Type': 'audio/wav', 'Content-Length': data.daten.length, 'Cache-Control': 'no-store' });
    return res.end(data.daten);
  }
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
  if (host !== '127.0.0.1' && host !== 'localhost' && !process.env.ADMIN_TOKEN) {
    console.error('Abbruch: Für öffentlichen Betrieb (HOST ≠ localhost) muss ADMIN_TOKEN gesetzt sein.');
    process.exit(1);
  }
  const store = new Store(process.env.DATA_DIR || path.join(HERE, '..', 'data'));
  http.createServer(createApp(store)).listen(port, host, () => {
    console.log(`Anrufbeantworter läuft auf http://${host}:${port}`);
  });
}
