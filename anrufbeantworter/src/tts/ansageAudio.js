// Setzt die Ansage für das Telefon zusammen: feste Teile aus Aufnahmen, dynamische Teile
// (Name des Anrufers, optional Zeitangaben) von der KI in derselben Stimme.
//
//   [Guten Tag, Frau Dr. Schneider!]  ← KI (Stimme aus den Aufnahmen), mit Zeitlimit
//   [Sie sind verbunden mit …]        ← Aufnahme
//   [Ich bin gerade in einer …]       ← Aufnahme
//   [Bitte hinterlassen Sie …]        ← Aufnahme
//
// Braucht die KI zu lange, wird stattdessen die Aufnahme "Guten Tag!" genommen; das KI-Ergebnis
// landet trotzdem im Cache und ist beim nächsten Anruf derselben Person sofort da.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { leseWav, resample, normalisiere, stille, verbinde, schreibeWav, TELEFON_RATE } from '../audio/wav.js';
import { ttsText } from '../core/aussprache.js';

export class AnsageMixer {
  /**
   * @param verzeichnis Ablage der fertigen WAV-Dateien (ausgeliefert unter /audio/<name>.wav)
   * @param aufnahmen   Aufnahmen-Verwaltung
   * @param stimme      Stimmdienst (KI)
   * @param geheim      Schlüssel für nicht erratbare Dateinamen
   */
  constructor({ verzeichnis, aufnahmen, stimme, geheim, maxCache = 500 }) {
    this.verzeichnis = verzeichnis;
    this.aufnahmen = aufnahmen;
    this.stimme = stimme;
    this.geheim = geheim;
    this.kiCache = new Map();
    this.laufend = new Map();
    this.maxCache = maxCache;
    fs.mkdirSync(verzeichnis, { recursive: true });
  }

  /** Spricht einen Satz per KI in der Stimme des Mitarbeiters (Cache, keine Doppelaufträge). */
  ki(user, text) {
    const ref = this.aufnahmen.referenz(user);
    const key = `${ref?.hash || 'standard'}|${text}`;
    if (this.kiCache.has(key)) return Promise.resolve(this.kiCache.get(key));
    if (!this.laufend.has(key)) {
      const p = this.stimme.sprich(text, { referenz: ref?.wav })
        .then((wav) => {
          const { rate, samples } = leseWav(wav);
          const tel = normalisiere(resample(samples, rate, TELEFON_RATE));
          this.kiCache.set(key, tel);
          if (this.kiCache.size > this.maxCache) this.kiCache.delete(this.kiCache.keys().next().value);
          return tel;
        })
        .finally(() => this.laufend.delete(key));
      this.laufend.set(key, p);
    }
    return this.laufend.get(key);
  }

  /**
   * @param bausteine aus der Ansage-Engine (antwort.ansage.bausteine)
   * @returns {Promise<{ name, datei, sekunden, quellen: string[] }>}
   */
  async ansage(user, bausteine, { lexikon = [], pauseMs = 450, zeitangaben = false, wartezeitMs = 2500 } = {}) {
    const quellen = [];
    const teile = [];
    for (const b of bausteine) {
      if (b.optional === 'zeitangabe' && !zeitangaben) continue;
      if (b.key) {
        const aufnahme = this.aufnahmen.telefon(user, b.key);
        if (aufnahme) {
          teile.push(aufnahme);
          quellen.push(`aufnahme:${b.key}`);
          continue;
        }
      }
      // Dynamischer Satz oder (noch) fehlende Aufnahme: KI
      if (!this.stimme.bereit) {
        quellen.push(`fehlt:${b.key || b.text}`);
        continue;
      }
      const text = ttsText(b.text, lexikon);
      const ersatz = b.ersatz && this.aufnahmen.telefon(user, b.ersatz);
      try {
        const zeitlimit = ersatz ? wartezeitMs : 20_000;
        const ergebnis = await Promise.race([this.ki(user, text), new Promise((r) => setTimeout(() => r(null), zeitlimit).unref?.())]);
        if (ergebnis) {
          teile.push(ergebnis);
          quellen.push(`ki:${text}`);
          continue;
        }
      } catch (e) {
        console.warn('KI-Stimme fehlgeschlagen:', e.message);
      }
      if (ersatz) {
        teile.push(ersatz);
        quellen.push(`aufnahme:${b.ersatz}`);
      } else {
        quellen.push(`fehlt:${b.key || b.text}`);
      }
    }
    if (!teile.length) throw new Error('Keine Aufnahmen und keine KI-Stimme verfügbar');

    const name = crypto.createHmac('sha256', this.geheim)
      .update(JSON.stringify([user.id, pauseMs, quellen, Object.values(user.aufnahmen || {}).map((a) => a.zeit)]))
      .digest('hex').slice(0, 40) + '.wav';
    const datei = path.join(this.verzeichnis, name);
    if (!fs.existsSync(datei)) {
      const folge = [stille(250)];
      teile.forEach((t, i) => {
        if (i > 0) folge.push(stille(pauseMs));
        folge.push(t);
      });
      folge.push(stille(300));
      const tmp = `${datei}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, schreibeWav(verbinde(folge)));
      fs.renameSync(tmp, datei);
    }
    return { name, datei, sekunden: (fs.statSync(datei).size - 44) / 2 / TELEFON_RATE, quellen };
  }

  pfad(name) {
    if (!/^[a-f0-9]{40}\.wav$/.test(name)) return null;
    const datei = path.join(this.verzeichnis, name);
    return fs.existsSync(datei) ? datei : null;
  }

  /** Alte Dateien löschen (persönliche Begrüßungen enthalten Kundennamen). */
  aufraeumen(maxAlterMs = 24 * 3600_000) {
    const grenze = Date.now() - maxAlterMs;
    for (const f of fs.readdirSync(this.verzeichnis)) {
      const p = path.join(this.verzeichnis, f);
      try {
        if (fs.statSync(p).mtimeMs < grenze) fs.unlinkSync(p);
      } catch { /* bereits gelöscht */ }
    }
  }
}
