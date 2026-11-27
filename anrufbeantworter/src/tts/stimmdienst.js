// Anbindung an den eigenen Stimmdienst (stimme/server.py: Chatterbox + Whisper-Gegenprüfung).
// Wird nur für die wenigen dynamischen Sätze gebraucht – vor allem "Guten Tag, Frau Dr. Schneider!".

export class Stimmdienst {
  constructor({ url, timeoutMs = 30_000, fetchImpl = globalThis.fetch }) {
    this.url = String(url || '').replace(/\/+$/, '');
    this.timeoutMs = timeoutMs;
    this.fetch = fetchImpl;
  }

  get bereit() { return !!this.url; }

  /**
   * @param text      zu sprechender Satz
   * @param referenz  WAV-Buffer mit der Stimme, in der gesprochen werden soll (optional)
   * @returns {Promise<Buffer>} WAV
   */
  async sprich(text, { referenz, pruefen = true } = {}) {
    if (!this.url) throw new Error('Stimmdienst (STIMME_URL) ist nicht eingerichtet');
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await this.fetch(`${this.url}/synthesize`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, pruefen, referenz: referenz ? referenz.toString('base64') : undefined }),
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`Stimmdienst: HTTP ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    } catch (e) {
      throw e.name === 'AbortError' ? new Error('Stimmdienst: Zeitüberschreitung') : e;
    } finally {
      clearTimeout(t);
    }
  }
}
