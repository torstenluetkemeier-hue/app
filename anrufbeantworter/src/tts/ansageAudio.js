// Ansagen als Audiodatei für das Telefon erzeugen und zwischenspeichern.
// Jeder Abschnitt wird einzeln gesprochen und gecacht: Bei einem erkannten Anrufer
// muss nur die persönliche Begrüßung neu erzeugt werden, der Rest kommt aus dem Cache.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { leseWav, resample, normalisiere, stille, verbinde, schreibeWav, TELEFON_RATE } from '../audio/wav.js';
import { ttsText } from '../core/aussprache.js';

// Abkürzungen, nach denen kein Satz endet
const ABKUERZUNGEN = /(?:^|\s)(?:Dr|Prof|Hr|Fr|Nr|Str|Tel|bzw|ca|usw|vgl|z\.\s?B|u\.\s?a|d\.\s?h|[A-ZÄÖÜ])\.$/;

/** Teilt Text in Sätze (Satzzeichen + Leerzeichen), ohne nach "Dr.", "Prof.", "z. B." usw. zu trennen. */
export function inSaetze(text) {
  const saetze = [];
  let aktuell = '';
  for (const teil of String(text).split(/(?<=[.!?])\s+/)) {
    aktuell = aktuell ? `${aktuell} ${teil}` : teil;
    if (!ABKUERZUNGEN.test(aktuell)) {
      saetze.push(aktuell);
      aktuell = '';
    }
  }
  if (aktuell) saetze.push(aktuell);
  return saetze.map((s) => s.trim()).filter(Boolean);
}

export class AnsageAudio {
  /**
   * @param verzeichnis  Ablage der fertigen WAV-Dateien (werden unter /audio/<name>.wav ausgeliefert)
   * @param tts          PiperTts (oder kompatibel: synthesize(text, {lengthScale}) → WAV)
   * @param geheim       Schlüssel für nicht erratbare Dateinamen
   */
  constructor({ verzeichnis, tts, geheim, maxCache = 400 }) {
    this.verzeichnis = verzeichnis;
    this.tts = tts;
    this.geheim = geheim;
    this.cache = new Map();
    this.maxCache = maxCache;
    fs.mkdirSync(verzeichnis, { recursive: true });
  }

  /**
   * Spricht einen Abschnitt Satz für Satz. Jeder Satz wird einzeln gecacht – so ist bei einem
   * erkannten Anrufer nur der kurze Begrüßungssatz mit dem Namen neu zu erzeugen.
   */
  async abschnitt(text, lengthScale = 1) {
    const saetze = inSaetze(text);
    const teile = await Promise.all(saetze.map((s) => this.satz(s, lengthScale)));
    const folge = [];
    teile.forEach((t, i) => {
      if (i > 0) folge.push(stille(220));
      folge.push(t);
    });
    return verbinde(folge);
  }

  /** Spricht einen einzelnen Satz (mit Cache) und liefert 8-kHz-Samples. */
  async satz(text, lengthScale = 1) {
    const key = `${this.tts.stimme || ''}|${lengthScale}|${text}`;
    if (this.cache.has(key)) {
      const s = this.cache.get(key);
      this.cache.delete(key);
      this.cache.set(key, s); // zuletzt benutzt nach hinten
      return s;
    }
    const { rate, samples } = leseWav(await this.tts.synthesize(text, { lengthScale }));
    const telefon = normalisiere(resample(samples, rate, TELEFON_RATE));
    this.cache.set(key, telefon);
    if (this.cache.size > this.maxCache) this.cache.delete(this.cache.keys().next().value);
    return telefon;
  }

  /**
   * Erzeugt die komplette Ansage als WAV-Datei.
   * @param abschnitte [{ text }] aus der Ansage-Engine
   * @returns {Promise<{ name: string, datei: string, sekunden: number }>}
   */
  async ansage(abschnitte, { lexikon = [], pauseMs = 450, tempoProzent = 100, ipaInline = false } = {}) {
    const texte = abschnitte.map((a) => ttsText(a.text ?? a, lexikon, { ipaInline })).filter(Boolean);
    const lengthScale = Math.round((100 / (tempoProzent || 100)) * 100) / 100;
    const name = crypto.createHmac('sha256', this.geheim)
      .update(JSON.stringify([this.tts.stimme, lengthScale, pauseMs, texte])).digest('hex').slice(0, 40) + '.wav';
    const datei = path.join(this.verzeichnis, name);
    if (!fs.existsSync(datei)) {
      const teile = await Promise.all(texte.map((t) => this.abschnitt(t, lengthScale)));
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
    const sekunden = (fs.statSync(datei).size - 44) / 2 / TELEFON_RATE;
    return { name, datei, sekunden };
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
