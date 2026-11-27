// WAV lesen, auf Telefonqualität bringen (8 kHz, mono, 16 bit – Vorgabe von sipgate.io) und zusammensetzen.
// Reines JavaScript, ohne ffmpeg.

export const TELEFON_RATE = 8000;

/** Liest eine PCM-16-bit-WAV-Datei. Mehrkanalig wird zu mono gemischt. */
export function leseWav(buf) {
  if (buf.length < 12 || buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('Keine WAV-Datei');
  }
  let off = 12;
  let fmt = null;
  let data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      fmt = { format: buf.readUInt16LE(body), kanaele: buf.readUInt16LE(body + 2), rate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
    } else if (id === 'data') {
      // Manche Encoder schreiben beim Streamen eine zu große Länge – auf den vorhandenen Rest begrenzen
      data = buf.subarray(body, Math.min(body + size, buf.length));
      break;
    }
    off = body + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('WAV ohne fmt- oder data-Block');
  if (fmt.format !== 1 || fmt.bits !== 16) throw new Error('Nur PCM 16 bit wird unterstützt');
  const frames = Math.floor(data.length / (2 * fmt.kanaele));
  const samples = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let summe = 0;
    for (let k = 0; k < fmt.kanaele; k++) summe += data.readInt16LE((i * fmt.kanaele + k) * 2);
    samples[i] = summe / fmt.kanaele / 32768;
  }
  return { rate: fmt.rate, samples };
}

/** Tiefpass (gefensterter Sinc, Hamming) gegen Aliasing, dann lineare Interpolation auf die Zielrate. */
export function resample(samples, von, nach = TELEFON_RATE) {
  if (von === nach) return samples;
  let quelle = samples;
  if (nach < von) {
    const fc = (0.45 * nach) / von; // Grenzfrequenz knapp unter der neuen Nyquist-Frequenz
    const M = 32;
    const h = new Float32Array(2 * M + 1);
    let summe = 0;
    for (let n = -M; n <= M; n++) {
      const sinc = n === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * n) / (Math.PI * n);
      const fenster = 0.54 + 0.46 * Math.cos((Math.PI * n) / M);
      h[n + M] = sinc * fenster;
      summe += h[n + M];
    }
    for (let i = 0; i < h.length; i++) h[i] /= summe;
    quelle = new Float32Array(samples.length);
    for (let i = 0; i < samples.length; i++) {
      let acc = 0;
      for (let k = -M; k <= M; k++) {
        const j = i + k;
        if (j >= 0 && j < samples.length) acc += samples[j] * h[k + M];
      }
      quelle[i] = acc;
    }
  }
  const faktor = von / nach;
  const laenge = Math.floor(quelle.length / faktor);
  const out = new Float32Array(laenge);
  for (let i = 0; i < laenge; i++) {
    const pos = i * faktor;
    const j = Math.floor(pos);
    const t = pos - j;
    out[i] = quelle[j] * (1 - t) + (quelle[j + 1] ?? quelle[j]) * t;
  }
  return out;
}

/** Spitzenpegel auf einen einheitlichen Wert bringen (gleiche Lautstärke bei allen Ansagen). */
export function normalisiere(samples, ziel = 0.89) {
  let spitze = 0;
  for (const s of samples) spitze = Math.max(spitze, Math.abs(s));
  if (spitze < 1e-4) return samples;
  const f = ziel / spitze;
  return samples.map((s) => s * f);
}

export function stille(ms, rate = TELEFON_RATE) {
  return new Float32Array(Math.round((ms / 1000) * rate));
}

export function verbinde(teile) {
  const out = new Float32Array(teile.reduce((n, t) => n + t.length, 0));
  let pos = 0;
  for (const t of teile) {
    out.set(t, pos);
    pos += t.length;
  }
  return out;
}

/** Mono, 16 bit PCM. */
export function schreibeWav(samples, rate = TELEFON_RATE) {
  const daten = samples.length * 2;
  const buf = Buffer.alloc(44 + daten);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + daten, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(1, 22); // mono
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(daten, 40);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(s < 0 ? s * 32768 : s * 32767), 44 + i * 2);
  }
  return buf;
}
