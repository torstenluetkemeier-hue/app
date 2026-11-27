// HTTP-Server: Verwaltungs-API + Weboberfläche, App-API für die iPhone-App,
// Twilio-Webhooks für den Cloud-Anrufbeantworter. Ohne externe Abhängigkeiten (Node.js ≥ 22).
//
// Zugriffsschutz:
//   /api/app/*   Bearer-Token des Mitarbeiters (in der Weboberfläche erzeugt, in der App eingetragen)
//   /tw/*        Twilio-Signatur (X-Twilio-Signature)
//   /api/*       sonst: ADMIN_TOKEN (falls gesetzt) – ohne ADMIN_TOKEN nur für localhost gedacht

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
import { mergeLexika, ansageSsml } from './core/aussprache.js';
import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN, REGEL_BEDINGUNGEN, DEFAULT_TEXTE, defaultUser } from './core/defaults.js';
import { notify } from './notify.js';
import { uebernehmeAppKonfiguration, SyncFehler } from './appsync.js';
import * as twilio from './telephony/twilio.js';
import { transkribiere, sttKonfiguriert } from './stt.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(HERE, '..', 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
const MASKE = '••••••';

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

export function createApp(store, { fetchImpl, env = process.env, verzoegerungMs = 15_000 } = {}) {
  let adapter, lookup;
  const rebuildCrm = () => {
    adapter = createAdapter(store.config.crm, fetchImpl ? { fetchImpl } : {});
    lookup = new CallerLookup(adapter, store.config.crm.cacheMinuten);
  };
  rebuildCrm();

  // Laufende Anrufe (callId bzw. Twilio CallSid → Zustand)
  const anrufe = new Map();
  const merkeAnruf = (callId, daten) => {
    anrufe.set(callId, { ...daten, start: new Date().toISOString(), nachrichtId: null });
    setTimeout(() => anrufe.delete(callId), 60 * 60_000).unref();
  };

  const twilioCfg = () => {
    const t = store.config.telefonie.twilio;
    return {
      accountSid: env.TWILIO_ACCOUNT_SID || t.accountSid,
      authToken: env.TWILIO_AUTH_TOKEN || t.authToken,
      stimme: t.stimme || 'Polly.Vicki-Neural',
      absenderNummer: t.absenderNummer,
    };
  };
  const basisUrl = () => (env.PUBLIC_URL || store.config.telefonie.publicUrl || '').replace(/\/+$/, '');

  const getUser = (id) => {
    const u = store.user(id);
    if (!u) throw new HttpError(404, `Mitarbeiter ${id} nicht gefunden`);
    return u;
  };

  /** Welcher Mitarbeiter ist gemeint? Eigene Cloud-Nummer, umleitende Handynummer oder Durchwahl. */
  const findeMitarbeiter = ({ to, umgeleitetVon } = {}) => {
    const users = store.config.users;
    if (!to && !umgeleitetVon) return users[0];
    const byId = to && store.user(to);
    if (byId) return byId;
    const n = normalizeNumber(to);
    const u = normalizeNumber(umgeleitetVon);
    return users.find((x) => n && normalizeNumber(x.cloud?.nummer) === n)
      || users.find((x) => u && [x.cloud?.mobilnummer, x.profil.durchwahl].some((m) => normalizeNumber(m) === u))
      || users.find((x) => n && normalizeNumber(x.profil.durchwahl) === n)
      || (users.length === 1 ? users[0] : null);
  };

  const publicConfig = () => {
    const c = structuredClone(store.config);
    for (const k of ['qto', 'zswork']) if (c.crm[k]?.apiToken) c.crm[k].apiToken = MASKE;
    if (c.telefonie.twilio.authToken) c.telefonie.twilio.authToken = MASKE;
    c.telefonie.status = {
      twilioBereit: !!(twilioCfg().accountSid && twilioCfg().authToken),
      publicUrl: basisUrl(),
      transkription: sttKonfiguriert(),
    };
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
    antwort.ansage.ssml = ansageSsml(antwort.ansage.abschnitte, {
      lexikon: lexikonFuer(user), pauseMs: user.stimme?.pauseMs, tempoProzent: twilio.tempoProzent(user.stimme?.tempo),
    });
    return { user, antwort };
  }

  const twimlOptionen = (user, callId) => ({
    callId, basis: basisUrl(), stimme: twilioCfg().stimme, lexikon: lexikonFuer(user),
    pauseMs: user.stimme?.pauseMs, tempo: user.stimme?.tempo,
  });

  // ---------------------------------------------------------------- Verwaltung (Admin)
  const adminRoutes = [
    ['GET', /^\/api\/meta$/, () => ({
      modi: MODI, terminArten: TERMIN_ARTEN, abwesendArten: ABWESEND_ARTEN, regelBedingungen: REGEL_BEDINGUNGEN,
      standardTexte: DEFAULT_TEXTE, stimmen: twilio.STIMMEN,
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
      const t = store.config.telefonie;
      if (typeof body.publicUrl === 'string') t.publicUrl = body.publicUrl.trim();
      if (body.twilio) {
        for (const k of ['accountSid', 'stimme', 'absenderNummer']) if (typeof body.twilio[k] === 'string') t.twilio[k] = body.twilio[k].trim();
        if (body.twilio.authToken && body.twilio.authToken !== MASKE) t.twilio.authToken = body.twilio.authToken.trim();
      }
      store.saveConfig();
      return publicConfig().telefonie;
    }],
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

    // Vorschau: was hört ein Anrufer mit dieser Nummer zu diesem Zeitpunkt? (inkl. TwiML)
    ['POST', /^\/api\/vorschau$/, async (_, body) => {
      const { user, antwort } = await handleCall(body);
      antwort.twiml = twilio.antwortTwiml(antwort, twimlOptionen(user, 'VORSCHAU'));
      return antwort;
    }],

    // Generische Telefonie-Schnittstelle (eigenes Voice-Gateway statt Twilio)
    ['POST', /^\/api\/telephony\/incoming$/, async (_, body) => {
      const { user, antwort } = await handleCall({ to: body.to, umgeleitetVon: body.umgeleitetVon, userId: body.userId, from: body.from, zeit: body.zeit });
      const callId = body.callId || crypto.randomUUID();
      merkeAnruf(callId, { userId: user.id, antwort });
      return { callId, ablauf: antwort.ablauf, status: antwort.status, anrufer: antwort.anrufer, ssml: antwort.ansage.ssml };
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
  const eigeneNachricht = (u, id) => {
    const n = store.nachricht(id);
    if (!n || n.userId !== u.id) throw new HttpError(404, 'Nachricht nicht gefunden');
    return n;
  };

  const appRoutes = [
    ['GET', /^\/api\/app\/ich$/, (u) => ({
      id: u.id,
      name: `${u.profil.vorname} ${u.profil.nachname}`.trim(),
      cloudNummer: u.cloud?.nummer || '',
      mobilnummer: u.cloud?.mobilnummer || '',
      stimme: twilioCfg().stimme,
      telefonieBereit: !!(twilioCfg().accountSid && twilioCfg().authToken && basisUrl()),
      transkription: sttKonfiguriert(),
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
      return { ok: true, zeit: u.appSync.zeit, aktuell: resolveStatus(u) };
    }],
    ['GET', /^\/api\/app\/vorschau$/, async (u, _, q) => {
      const { antwort } = await handleCall({ userId: u.id, from: q.from || null });
      return { text: antwort.ansage.text, ssml: antwort.ansage.ssml, status: antwort.status, anrufer: antwort.anrufer };
    }],
    ['POST', /^\/api\/app\/probeanruf$/, async (u, body) => {
      const cfg = twilioCfg();
      if (!cfg.accountSid || !cfg.authToken) throw new HttpError(503, 'Twilio ist auf dem Server noch nicht eingerichtet');
      const an = body.an || u.cloud?.mobilnummer;
      const von = u.cloud?.nummer || cfg.absenderNummer;
      if (!an) throw new HttpError(400, 'Keine Handynummer hinterlegt');
      if (!von) throw new HttpError(400, 'Keine Cloud-Nummer als Absender hinterlegt');
      const { antwort } = await handleCall({ userId: u.id, from: body.alsAnrufer || null });
      const twiml = `<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/>`
        + `<Say voice="${cfg.stimme}" language="de-DE">${antwort.ansage.ssml}</Say><Hangup/></Response>`;
      return twilio.probeanruf({ accountSid: cfg.accountSid, authToken: cfg.authToken, von, an, twiml }, fetchImpl);
    }],
    ['GET', /^\/api\/app\/nachrichten$/, (u) => store.nachrichten.filter((n) => n.userId === u.id).slice(0, 200)
      .map(({ aufnahmeUrl, benachrichtigung, ...n }) => ({ ...n, hatAufnahme: !!aufnahmeUrl }))],
    ['PATCH', /^\/api\/app\/nachrichten\/([\w-]+)$/, (u, body, _, [id]) => {
      const n = eigeneNachricht(u, id);
      if (body.erledigt !== undefined) n.erledigt = !!body.erledigt;
      store.saveMessages();
      return { ok: true, erledigt: n.erledigt };
    }],
  ];

  // ---------------------------------------------------------------- Twilio-Webhooks
  const twilioRoutes = {
    // Eingehender (umgeleiteter) Anruf
    '/tw/voice': async (p) => {
      const callId = p.CallSid || crypto.randomUUID();
      try {
        const { user, antwort } = await handleCall({ to: p.To || p.Called, umgeleitetVon: p.ForwardedFrom, from: p.From });
        merkeAnruf(callId, { userId: user.id, antwort });
        return twilio.antwortTwiml(antwort, twimlOptionen(user, callId));
      } catch (e) {
        console.error('Twilio /tw/voice:', e.message);
        return twilio.fehlerTwiml(twilioCfg().stimme);
      }
    },
    // Taste während der Ansage
    '/tw/taste': (p, q) => {
      const call = anrufe.get(q.callId);
      const stimme = twilioCfg().stimme;
      if (!call) return twilio.fehlerTwiml(stimme);
      const auswahl = call.antwort.ablauf.find((s) => s.typ === 'auswahl' && s.taste === String(p.Digits));
      if (auswahl) {
        call.weitergeleitet = auswahl.ziel;
        return twilio.weiterleitenTwiml(auswahl.ziel, stimme);
      }
      // Andere Taste: weiter zur Aufnahme
      const aufnahme = call.antwort.ablauf.find((s) => s.typ === 'aufnahme');
      return aufnahme
        ? `<?xml version="1.0" encoding="UTF-8"?><Response>${twilio.recordTwiml(aufnahme.maxSekunden, basisUrl(), `callId=${encodeURIComponent(q.callId)}`)}</Response>`
        : twilio.abschiedTwiml(stimme);
    },
    // Ende der Aufnahme (auch wenn der Anrufer auflegt)
    '/tw/aufnahme-ende': async (p, q) => {
      await nachrichtAusAufnahme(q.callId, p);
      return twilio.abschiedTwiml(twilioCfg().stimme);
    },
    // Aufnahme fertig verarbeitet (Absicherung, falls aufnahme-ende nicht ankam)
    '/tw/aufnahme': async (p, q) => {
      if (p.RecordingStatus === 'completed') await nachrichtAusAufnahme(q.callId, p);
      return '<?xml version="1.0" encoding="UTF-8"?><Response/>';
    },
    // Anrufstatus (in der Twilio-Konsole an der Nummer eintragen): Anrufe ohne Nachricht festhalten
    '/tw/status': (p) => {
      const call = anrufe.get(p.CallSid);
      if (call && p.CallStatus === 'completed') {
        setTimeout(() => {
          if (!call.nachrichtId && !call.weitergeleitet) {
            const n = baueNachricht(getUser(call.userId), call.antwort, { ohneNachricht: true });
            call.nachrichtId = n.id;
            store.nachrichten.unshift(n);
            store.saveMessages();
          }
        }, verzoegerungMs).unref?.();
      }
      return '<?xml version="1.0" encoding="UTF-8"?><Response/>';
    },
  };

  async function nachrichtAusAufnahme(callId, p) {
    const call = anrufe.get(callId);
    if (!call || call.nachrichtId || !p.RecordingUrl) return;
    const dauer = Number(p.RecordingDuration) || 0;
    const user = getUser(call.userId);
    const n = await saveMessage(user, call.antwort, { aufnahmeUrl: p.RecordingUrl, dauerSekunden: dauer, ohneNachricht: dauer < 1 }, { benachrichtigen: false });
    call.nachrichtId = n.id;
    // Transkription und Benachrichtigung im Hintergrund, Twilio bekommt sofort Antwort
    (async () => {
      try {
        if (sttKonfiguriert() && dauer >= 1) {
          const mp3 = await twilio.ladeAufnahme(twilioCfg(), p.RecordingUrl, fetchImpl);
          n.transkript = (await transkribiere(mp3, fetchImpl)) || '';
        }
      } catch (e) {
        n.transkriptFehler = e.message;
      }
      n.benachrichtigung = await notify(user, n, fetchImpl);
      store.saveMessages();
    })();
  }

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
      ohneNachricht: !!body.ohneNachricht,
      erledigt: false,
      aufgabe: null,
      benachrichtigung: null,
    };
  }

  async function saveMessage(user, antwort, body, { benachrichtigen = true } = {}) {
    const nachricht = baueNachricht(user, antwort, body);
    const k = nachricht.kontakt;
    const wer = k ? [k.anrede, k.titel, k.nachname].filter(Boolean).join(' ') || k.organisation : nachricht.nummer || 'Anonym';
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
    if (benachrichtigen) nachricht.benachrichtigung = await notify(user, nachricht, fetchImpl);
    store.nachrichten.unshift(nachricht);
    store.saveMessages();
    return nachricht;
  }

  // ---------------------------------------------------------------- Zugriffsschutz
  const pruefeAdmin = (req) => {
    if (!env.ADMIN_TOKEN) return;
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : req.headers['x-admin-token'] || '';
    const a = Buffer.from(sha256(String(token)));
    const b = Buffer.from(sha256(env.ADMIN_TOKEN));
    if (!crypto.timingSafeEqual(a, b)) throw new HttpError(401, 'Admin-Zugang erforderlich');
  };

  const pruefeTwilio = (req, url, params) => {
    const { authToken } = twilioCfg();
    if (!authToken) throw new HttpError(503, 'Twilio ist nicht konfiguriert');
    const basis = basisUrl();
    if (!basis) throw new HttpError(503, 'PUBLIC_URL ist nicht gesetzt');
    if (!twilio.signaturGueltig(authToken, basis + url.pathname + url.search, params, req.headers['x-twilio-signature'])) {
      throw new HttpError(403, 'Ungültige Twilio-Signatur');
    }
  };

  // ---------------------------------------------------------------- Routing
  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (url.pathname.startsWith('/tw/')) {
        const fn = twilioRoutes[url.pathname];
        if (!fn || req.method !== 'POST') throw new HttpError(404, 'Unbekannter Endpunkt');
        const params = await readBody(req);
        pruefeTwilio(req, url, params);
        const xmlAntwort = await fn(params, Object.fromEntries(url.searchParams));
        res.writeHead(200, { 'Content-Type': 'text/xml; charset=utf-8', 'Cache-Control': 'no-store' });
        return res.end(xmlAntwort);
      }
      if (url.pathname.startsWith('/api/app/')) {
        const user = appUser(req);
        const m = url.pathname.match(/^\/api\/app\/nachrichten\/([\w-]+)\/audio$/);
        if (m && req.method === 'GET') return streamAufnahme(eigeneNachricht(user, m[1]), res);
        const body = ['POST', 'PUT', 'PATCH'].includes(req.method) ? await readBody(req) : {};
        for (const [method, re, fn] of appRoutes) {
          const mm = method === req.method && url.pathname.match(re);
          if (mm) return send(res, 200, await fn(user, body, Object.fromEntries(url.searchParams), mm.slice(1)));
        }
        throw new HttpError(404, 'Unbekannter Endpunkt');
      }
      if (url.pathname.startsWith('/api/')) {
        pruefeAdmin(req);
        const m = url.pathname.match(/^\/api\/nachrichten\/([\w-]+)\/audio$/);
        if (m && req.method === 'GET') {
          const n = store.nachricht(m[1]);
          if (!n) throw new HttpError(404, 'Nachricht nicht gefunden');
          return streamAufnahme(n, res);
        }
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

  async function streamAufnahme(n, res) {
    if (!n.aufnahmeUrl) throw new HttpError(404, 'Keine Aufnahme vorhanden');
    const mp3 = await twilio.ladeAufnahme(twilioCfg(), n.aufnahmeUrl, fetchImpl);
    res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'Content-Length': mp3.length, 'Cache-Control': 'private, no-store' });
    res.end(mp3);
  }
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
