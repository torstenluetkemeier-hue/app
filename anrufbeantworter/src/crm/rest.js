// Generischer REST-Adapter für Qto und (künftig) ZSWork.
//
// Die tatsächlichen Endpunkte und Feldnamen von Qto/ZSWork sind im Prototyp
// noch Annahmen. Pfade sind konfigurierbar, das Feld-Mapping steckt in
// mapContact() und lässt sich je System überschreiben.

export class RestCrmAdapter {
  /**
   * @param {object} cfg { baseUrl, apiToken, lookupPath, taskPath }
   * @param {object} opts { timeoutMs, fetchImpl, name }
   */
  constructor(cfg, opts = {}) {
    this.cfg = cfg;
    this.name = opts.name || 'REST';
    this.timeoutMs = opts.timeoutMs || 1500;
    this.fetch = opts.fetchImpl || globalThis.fetch;
  }

  headers() {
    const h = { Accept: 'application/json', 'Content-Type': 'application/json' };
    if (this.cfg.apiToken) h.Authorization = `Bearer ${this.cfg.apiToken}`;
    return h;
  }

  url(path, nummer = '') {
    if (!this.cfg.baseUrl) throw new Error(`${this.name}: keine Basis-URL konfiguriert`);
    return this.cfg.baseUrl.replace(/\/+$/, '') + path.replace('{nummer}', encodeURIComponent(nummer));
  }

  async request(url, init = {}) {
    // Harte Zeitgrenze: Der Anrufer soll nicht auf das CRM warten.
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await this.fetch(url, { ...init, headers: this.headers(), signal: ctrl.signal });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`${this.name}: HTTP ${res.status}`);
      return await res.json();
    } finally {
      clearTimeout(t);
    }
  }

  async findByPhone(nummer) {
    if (!nummer) return null;
    const data = await this.request(this.url(this.cfg.lookupPath, nummer));
    if (!data) return null;
    const list = Array.isArray(data) ? data : Array.isArray(data.items) ? data.items : [data];
    if (!list.length) return null;
    const kontakte = list.map((r) => this.mapContact(r));
    const k = { ...kontakte[0], quelle: this.name };
    // Mehrdeutig (z. B. Praxis-Zentrale mit mehreren Ansprechpartnern):
    // niemanden falsch mit Namen ansprechen, nur die Organisation nennen.
    const personen = new Set(kontakte.map((c) => `${c.anrede}|${c.titel}|${c.nachname}`));
    if (personen.size > 1) Object.assign(k, { anrede: '', titel: '', vorname: '', nachname: '', duzen: false, mehrdeutig: true });
    return k;
  }

  /** Feld-Mapping vom System-Format auf das interne Kontaktmodell. */
  mapContact(r) {
    return {
      id: String(r.id ?? r.contactId ?? ''),
      typ: r.typ ?? r.type ?? (r.kundennummer || r.customerNumber ? 'praxis' : 'unbekannt'),
      anrede: r.anrede ?? r.salutation ?? '',
      titel: r.titel ?? r.title ?? '',
      vorname: r.vorname ?? r.firstName ?? '',
      nachname: r.nachname ?? r.lastName ?? '',
      organisation: r.organisation ?? r.praxis ?? r.company ?? '',
      kundennummer: String(r.kundennummer ?? r.customerNumber ?? ''),
      vip: Boolean(r.vip ?? r.isVip ?? false),
      betreuerId: r.betreuerId ?? r.accountManager ?? '',
      duzen: Boolean(r.duzen ?? false),
      offeneTickets: r.offeneTickets ?? r.openTickets ?? [],
    };
  }

  async createCallbackTask(task) {
    const body = {
      typ: 'rueckruf',
      titel: task.titel,
      beschreibung: task.beschreibung,
      prioritaet: task.prioritaet,
      zustaendig: task.userId,
      kontaktId: task.kontakt?.id || null,
      rufnummer: task.nummer,
      aufnahmeUrl: task.aufnahmeUrl || null,
    };
    const data = await this.request(this.url(this.cfg.taskPath), { method: 'POST', body: JSON.stringify(body) });
    return { id: String(data?.id ?? ''), url: data?.url ?? null };
  }

  async healthCheck() {
    try {
      await this.request(this.url(this.cfg.lookupPath, '+490000000000'));
      return { ok: true, info: `${this.name} erreichbar` };
    } catch (e) {
      return { ok: false, info: e.name === 'AbortError' ? `${this.name}: Zeitüberschreitung` : e.message };
    }
  }
}
