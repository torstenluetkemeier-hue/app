// Auswahl des CRM-Adapters und Caching der Rufnummernsuche.

import { MockAdapter } from './mock.js';
import { RestCrmAdapter } from './rest.js';

export function createAdapter(crmCfg, opts = {}) {
  const timeoutMs = crmCfg.timeoutMs || 1500;
  switch (crmCfg.adapter) {
    case 'qto':
      return new RestCrmAdapter(
        { ...crmCfg.qto, apiToken: process.env.QTO_API_TOKEN || crmCfg.qto?.apiToken },
        { name: 'Qto', timeoutMs, ...opts },
      );
    case 'zswork':
      return new RestCrmAdapter(
        { ...crmCfg.zswork, apiToken: process.env.ZSWORK_API_TOKEN || crmCfg.zswork?.apiToken },
        { name: 'ZSWork', timeoutMs, ...opts },
      );
    default:
      return new MockAdapter();
  }
}

/**
 * Sucht den Anrufer. Fehler oder Zeitüberschreitungen führen nie zum
 * Abbruch des Anrufs, sondern zu einer neutralen Begrüßung.
 */
export class CallerLookup {
  constructor(adapter, cacheMinuten = 10) {
    this.adapter = adapter;
    this.ttl = cacheMinuten * 60_000;
    this.cache = new Map();
  }

  async find(nummer) {
    if (!nummer) return { kontakt: null, fehler: null, ausCache: false };
    const hit = this.cache.get(nummer);
    if (hit && hit.until > Date.now()) return { kontakt: hit.kontakt, fehler: null, ausCache: true };
    try {
      const kontakt = await this.adapter.findByPhone(nummer);
      this.cache.set(nummer, { kontakt, until: Date.now() + this.ttl });
      return { kontakt, fehler: null, ausCache: false };
    } catch (e) {
      return { kontakt: null, fehler: e.name === 'AbortError' ? 'Zeitüberschreitung' : e.message, ausCache: false };
    }
  }
}
