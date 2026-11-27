// Übernahme der Konfiguration aus der iPhone-App (PUT /api/app/konfiguration).
// Die App schickt bereits das Server-Format; hier wird nur geprüft und zusammengeführt.
// Serverseitige Einstellungen (Anrufer-Regeln, Cloud-Nummer, Geschäftszeiten …) bleiben unberührt.

import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN } from './core/defaults.js';

const STAMP = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/;
const str = (v, max = 200) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const MODUS_APP = Object.keys(MODI).filter((m) => m !== 'feierabend');

export class SyncFehler extends Error {}

function vertretungsWahl(v) {
  if (v === undefined || v === null) return undefined; // automatisch
  return str(v, 64); // '' = keine, sonst ID
}

function art(modus, a) {
  if (modus === 'termin') return TERMIN_ARTEN[a] ? a : 'sonstiges';
  if (modus === 'abwesend') return ABWESEND_ARTEN[a] ? a : 'sonstiges';
  return '';
}

function status(s) {
  if (!MODUS_APP.includes(s?.modus)) throw new SyncFehler(`Unbekannter Status „${s?.modus}“`);
  if (s.bis && !STAMP.test(s.bis)) throw new SyncFehler('Ungültiges Datum bei „bis“');
  return {
    modus: s.modus, art: art(s.modus, s.art), freitext: str(s.freitext), bis: s.bis || '',
    ganztags: !!s.ganztags, vertretungId: vertretungsWahl(s.vertretungId), gesetztAm: new Date().toISOString(),
  };
}

function eintrag(e) {
  const s = status(e);
  if (!STAMP.test(e.von || '') || !STAMP.test(e.bis || '')) throw new SyncFehler('Kalendereintrag braucht „von“ und „bis“');
  if (e.bis.slice(0, e.von.length) < e.von.slice(0, e.bis.length)) throw new SyncFehler('Kalendereintrag endet vor dem Beginn');
  return { id: str(e.id, 64) || cryptoId(), titel: str(e.titel), von: e.von, bis: e.bis, modus: s.modus, art: s.art,
    freitext: s.freitext, ganztags: s.ganztags, vertretungId: s.vertretungId, aktiv: true };
}

const cryptoId = () => Math.random().toString(36).slice(2, 10);

export function uebernehmeAppKonfiguration(user, p) {
  if (!p || typeof p !== 'object') throw new SyncFehler('Leere Konfiguration');
  if (p.profil) {
    for (const k of ['vorname', 'nachname', 'funktion']) if (p.profil[k] !== undefined) user.profil[k] = str(p.profil[k], 100);
  }
  if (p.firma) {
    for (const k of ['name', 'produkt']) if (p.firma[k] !== undefined) user.firma[k] = str(p.firma[k], 100);
  }
  if (Array.isArray(p.vertretungen)) {
    user.vertretungen = p.vertretungen.slice(0, 20)
      .map((v) => ({ id: str(v.id, 64) || cryptoId(), name: str(v.name, 100), telefon: str(v.telefon, 40) }))
      .filter((v) => v.name);
  }
  if ('standardVertretungId' in p) user.standardVertretungId = str(p.standardVertretungId, 64);
  if (Array.isArray(p.vertretungNennenIn)) {
    user.optionen.vertretungNennenIn = p.vertretungNennenIn.filter((m) => MODI[m]);
  }
  if ('status' in p) user.status = p.status ? status(p.status) : null;
  if (Array.isArray(p.kalender)) user.kalender = p.kalender.slice(0, 500).map(eintrag).sort((a, b) => a.von.localeCompare(b.von));
  if (p.texte) {
    const t = p.texte;
    for (const k of ['intro', 'vertretung', 'abschluss']) if (typeof t[k] === 'string') user.texte[k] = str(t[k], 1000);
    for (const m of MODUS_APP) if (typeof t.modi?.[m] === 'string') user.texte.modi[m] = str(t.modi[m], 1000);
  }
  if (Array.isArray(p.lexikon)) {
    user.lexikon = p.lexikon.slice(0, 1000)
      .map((e) => ({ schreibweise: str(e.schreibweise, 100), lautschrift: str(e.lautschrift, 200), ipa: str(e.ipa, 200) }))
      .filter((e) => e.schreibweise);
  }
  if (p.stimme) {
    const tempo = Number(p.stimme.tempo);
    const pause = Number(p.stimme.pauseMs);
    user.stimme = {
      tempo: Number.isFinite(tempo) ? Math.min(0.7, Math.max(0.3, tempo)) : 0.48,
      pauseMs: Number.isFinite(pause) ? Math.min(2000, Math.max(0, Math.round(pause))) : 450,
    };
  }
  if (p.cloud?.mobilnummer !== undefined) user.cloud.mobilnummer = str(p.cloud.mobilnummer, 40);
  user.appSync = { zeit: new Date().toISOString(), version: str(p.version, 20) };
  return user;
}
