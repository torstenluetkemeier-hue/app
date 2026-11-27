// Aufnahmen der festen Ansage-Bausteine je Mitarbeiter.
// Aufgenommen wird in der iPhone-App (oder als WAV-Datei in der Weboberfläche hochgeladen).
// Aus den Aufnahmen entsteht außerdem die Referenz, mit der die KI die dynamischen Sätze
// (Name des Anrufers) in derselben Stimme spricht.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { leseWav, schreibeWav, resample, normalisiere, trimmeStille, verbinde, stille, TELEFON_RATE } from './audio/wav.js';
import { answerCall, verbindenBaustein, kurzHash } from './core/engine.js';
import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN } from './core/defaults.js';

const REFERENZ_RATE = 24000;
const REIHENFOLGE_REFERENZ = ['vorstellung', 'abschluss', 'status.standard', 'abschlussBekannt', 'gruss'];

/** Kurzansage für die sipgate-Mailbox (wird ebenfalls aufgenommen). */
export const MAILBOX_KURZ = { key: 'mailboxKurz', text: 'Bitte sprechen Sie jetzt.' };

/** Lesbarer Titel eines Bausteins. */
export function titel(key, user) {
  const v = (id) => user.vertretungen.find((x) => x.id === id)?.name || id;
  const [teil, a, b] = key.split('.');
  switch (teil) {
    case 'gruss': return 'Begrüßung (unbekannte Anrufer)';
    case 'vorstellung': return 'Vorstellung';
    case 'vorstellungDu': return 'Vorstellung für Kollegen (Du)';
    case 'status':
      if (a === 'termin') return `Status: ${b === 'frei' ? 'Termin (eigener Text)' : TERMIN_ARTEN[b]?.label || b}`;
      if (a === 'abwesend') return `Status: ${b === 'frei' ? 'Unterwegs (eigener Text)' : ABWESEND_ARTEN[b]?.label || b}`;
      return `Status: ${MODI[a]?.kurz || a}`;
    case 'vertretung': return `Vertretung: ${v(a)}`;
    case 'weiterleitung': return `Angebot Taste 1: ${v(a)}`;
    case 'verbinden': return `Verbinden mit ${v(a)}`;
    case 'support': return 'Support-Hinweis';
    case 'zusatz': return 'Zusatztext einer Regel';
    case 'abschluss': return 'Abschluss (unbekannte Anrufer)';
    case 'abschlussBekannt': return 'Abschluss (erkannte Anrufer)';
    case 'abschlussOhneAufnahme': return 'Abschluss ohne Nachricht';
    case 'mailboxKurz': return 'Kurzansage für die sipgate-Mailbox';
    default: return key;
  }
}

/**
 * Alle Bausteine, die für diesen Mitarbeiter aufgenommen werden können.
 * "gebraucht" = kommt beim aktuellen Status, in geplanten Einträgen oder im Standard vor.
 */
export function alleBausteine(user, jetzt = new Date()) {
  const liste = new Map();
  const sammle = (u, kontakt, gebraucht) => {
    const a = answerCall(u, { nummer: kontakt ? '+490' : null, kontakt }, jetzt);
    for (const b of a.ansage.bausteine) {
      if (!b.key) continue;
      const alt = liste.get(b.key);
      liste.set(b.key, { key: b.key, text: b.text, gebraucht: gebraucht || !!alt?.gebraucht });
      if (b.key.startsWith('weiterleitung.')) {
        const z = a.ablauf.find((s) => s.typ === 'auswahl')?.ziel;
        if (z) {
          const vb = verbindenBaustein(z);
          liste.set(vb.key, { ...vb, gebraucht: gebraucht || !!liste.get(vb.key)?.gebraucht });
        }
      }
    }
    const direkt = a.ablauf.find((s) => s.typ === 'weiterleiten');
    if (direkt) {
      const vb = verbindenBaustein(direkt.ziel);
      liste.set(vb.key, { ...vb, gebraucht: gebraucht || !!liste.get(vb.key)?.gebraucht });
    }
  };
  const anrufer = [
    null,
    { typ: 'praxis', anrede: 'Frau', nachname: 'Beispiel', vip: true, betreuerId: user.id },
    { typ: 'praxis', anrede: 'Frau', nachname: 'Beispiel' },
    { typ: 'intern', vorname: 'Kollege', duzen: true },
  ];
  const mit = (status) => ({ ...user, status, kalender: [] });

  // Tatsächlich gebrauchte Varianten: aktueller Status, geplante Einträge, Standard
  const hatGeschaeftszeiten = Object.values(user.geschaeftszeiten || {}).some((z) => z.length);
  const aktuell = [user.status, ...user.kalender, { modus: 'standard' }, hatGeschaeftszeiten ? { modus: 'feierabend' } : null].filter(Boolean);
  for (const s of aktuell) for (const k of anrufer) sammle(mit({ ...s, bis: '' }), k, true);

  // Alle weiteren Möglichkeiten (optional aufzunehmen)
  const varianten = [
    { modus: 'standard' },
    ...Object.keys(TERMIN_ARTEN).filter((a) => a !== 'sonstiges').map((art) => ({ modus: 'termin', art })),
    ...Object.keys(ABWESEND_ARTEN).filter((a) => a !== 'sonstiges').map((art) => ({ modus: 'abwesend', art })),
    { modus: 'urlaub' }, { modus: 'krank' },
    ...user.vertretungen.map((v) => ({ modus: 'urlaub', vertretungId: v.id })),
  ];
  for (const s of varianten) for (const k of anrufer) sammle(mit(s), k, false);

  liste.set(MAILBOX_KURZ.key, { ...MAILBOX_KURZ, gebraucht: true });
  return [...liste.values()].map((b) => ({ ...b, titel: titel(b.key, user) }));
}

export class Aufnahmen {
  constructor(verzeichnis) {
    this.verzeichnis = verzeichnis;
    this.cache = new Map();
    fs.mkdirSync(verzeichnis, { recursive: true });
  }

  datei(userId, key, variante) {
    const sicher = String(key).replace(/[^\w.-]/g, '_');
    return path.join(this.verzeichnis, userId.replace(/[^\w.-]/g, '_'), `${sicher}.${variante}.wav`);
  }

  /** Verarbeitet eine Aufnahme: Stille abschneiden, Lautstärke angleichen, Telefonfassung (8 kHz) erzeugen. */
  speichere(user, key, text, wavBuffer, quelle = 'app') {
    const { rate, samples } = leseWav(wavBuffer);
    const getrimmt = trimmeStille(samples, rate);
    const sekunden = getrimmt.length / rate;
    if (sekunden < 0.4) throw new Error('Die Aufnahme ist leer oder zu leise.');
    if (sekunden > 60) throw new Error('Die Aufnahme ist länger als 60 Sekunden.');
    const original = normalisiere(getrimmt);
    fs.mkdirSync(path.dirname(this.datei(user.id, key, 'original')), { recursive: true });
    fs.writeFileSync(this.datei(user.id, key, 'original'), schreibeWav(original, rate));
    fs.writeFileSync(this.datei(user.id, key, 'telefon'), schreibeWav(normalisiere(resample(original, rate, TELEFON_RATE)), TELEFON_RATE));
    user.aufnahmen ??= {};
    user.aufnahmen[key] = { textHash: kurzHash(text), text, sekunden: Math.round(sekunden * 10) / 10, zeit: new Date().toISOString(), quelle };
    this.cache.clear();
    return user.aufnahmen[key];
  }

  loesche(user, key) {
    for (const v of ['original', 'telefon']) fs.rmSync(this.datei(user.id, key, v), { force: true });
    delete user.aufnahmen?.[key];
    this.cache.clear();
  }

  /** Telefonfassung als Samples (8 kHz) oder null, wenn nicht vorhanden. */
  telefon(user, key) {
    if (!user.aufnahmen?.[key]) return null;
    const p = this.datei(user.id, key, 'telefon');
    const ck = `t|${p}|${user.aufnahmen[key].zeit}`;
    if (!this.cache.has(ck)) {
      if (!fs.existsSync(p)) return null;
      this.cache.set(ck, leseWav(fs.readFileSync(p)).samples);
    }
    return this.cache.get(ck);
  }

  originalDatei(user, key) {
    const p = this.datei(user.id, key, 'original');
    return user.aufnahmen?.[key] && fs.existsSync(p) ? p : null;
  }

  /**
   * Referenz für die KI-Stimme: bis zu 20 Sekunden aus den eigenen Aufnahmen.
   * @returns {{ wav: Buffer, hash: string } | null}
   */
  referenz(user) {
    const keys = Object.keys(user.aufnahmen || {}).sort((a, b) => {
      const ia = REIHENFOLGE_REFERENZ.indexOf(a);
      const ib = REIHENFOLGE_REFERENZ.indexOf(b);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    });
    if (!keys.length) return null;
    const ck = `r|${user.id}|${keys.map((k) => k + user.aufnahmen[k].zeit).join(',')}`;
    if (!this.cache.has(ck)) {
      const teile = [];
      let sekunden = 0;
      for (const k of keys) {
        const p = this.originalDatei(user, k);
        if (!p) continue;
        const { rate, samples } = leseWav(fs.readFileSync(p));
        teile.push(resample(samples, rate, REFERENZ_RATE), stille(300, REFERENZ_RATE));
        sekunden += samples.length / rate;
        if (sekunden >= 20) break;
      }
      if (!teile.length) return null;
      const wav = schreibeWav(verbinde(teile), REFERENZ_RATE);
      this.cache.set(ck, { wav, hash: crypto.createHash('sha256').update(wav).digest('hex').slice(0, 16), sekunden });
    }
    return this.cache.get(ck);
  }

  /** Bausteinliste mit Aufnahme-Stand: fehlt / vorhanden / veraltet (Text hat sich geändert). */
  liste(user) {
    return alleBausteine(user).map((b) => {
      const a = user.aufnahmen?.[b.key];
      const stand = !a ? 'fehlt' : a.textHash === kurzHash(b.text) ? 'vorhanden' : 'veraltet';
      return { ...b, stand, sekunden: a?.sekunden ?? null, zeit: a?.zeit ?? null, quelle: a?.quelle ?? null, aufgenommenerText: stand === 'veraltet' ? a.text : undefined };
    }).sort((x, y) => Number(y.gebraucht) - Number(x.gebraucht));
  }
}
