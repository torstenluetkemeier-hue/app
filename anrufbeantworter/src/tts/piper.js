// Sprachausgabe mit Piper (Open Source, läuft auf dem eigenen Server in Deutschland).
// Erwartet den Piper-HTTP-Server:  python3 -m piper.http_server -m de_DE-thorsten-high
// API: POST /synthesize {"text", "voice"?, "length_scale"?} → audio/wav

export const PIPER_STIMMEN = {
  'de_DE-thorsten-high': 'Thorsten (männlich, hohe Qualität)',
  'de_DE-thorsten-medium': 'Thorsten (männlich, schneller)',
  'de_DE-kerstin-low': 'Kerstin (weiblich)',
  'de_DE-ramona-low': 'Ramona (weiblich)',
  'de_DE-eva_k-x_low': 'Eva (weiblich)',
};

export class PiperTts {
  constructor({ url, stimme, timeoutMs = 10_000, fetchImpl = globalThis.fetch }) {
    this.url = String(url || '').replace(/\/+$/, '');
    this.stimme = stimme;
    this.timeoutMs = timeoutMs;
    this.fetch = fetchImpl;
  }

  get bereit() { return !!this.url; }

  /** @returns {Promise<Buffer>} WAV in der Original-Abtastrate der Stimme */
  async synthesize(text, { lengthScale } = {}) {
    if (!this.url) throw new Error('Sprachausgabe (PIPER_URL) ist nicht eingerichtet');
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const body = { text };
      if (this.stimme) body.voice = this.stimme;
      if (lengthScale && lengthScale !== 1) body.length_scale = lengthScale;
      const res = await this.fetch(`${this.url}/synthesize`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`Sprachausgabe: HTTP ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    } catch (e) {
      throw e.name === 'AbortError' ? new Error('Sprachausgabe: Zeitüberschreitung') : e;
    } finally {
      clearTimeout(t);
    }
  }
}
