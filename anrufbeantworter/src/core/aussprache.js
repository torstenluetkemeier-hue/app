// Aussprache-Wörterbuch auf Ansagetexte anwenden (Gegenstück zu Aussprache.swift in der iPhone-App).
// Ergebnis ist SSML für Cloud-Stimmen: IPA als <phoneme>, Lautschrift als <sub>.

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function xml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const hatKorrektur = (e) => !!(e && ((e.lautschrift || '').trim() || (e.ipa || '').trim()));

/**
 * Persönliches Wörterbuch hat Vorrang vor dem Firmen-Wörterbuch (gleiche Schreibweise).
 */
export function mergeLexika(firma = [], person = []) {
  const map = new Map();
  for (const e of [...firma, ...person]) {
    if (!e?.schreibweise?.trim()) continue;
    map.set(e.schreibweise.trim().toLowerCase(), e);
  }
  return [...map.values()];
}

/** Zerlegt Text in { text } und { original, lautschrift, ipa }; ganzwortig, ohne Groß-/Kleinschreibung, längere Einträge zuerst. */
export function zerlege(text, lexikon = []) {
  const eintraege = lexikon.filter(hatKorrektur).sort((a, b) => b.schreibweise.length - a.schreibweise.length);
  const treffer = [];
  for (const e of eintraege) {
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${escapeRe(e.schreibweise.trim())}(?![\\p{L}\\p{N}])`, 'giu');
    for (const m of text.matchAll(re)) {
      const start = m.index;
      const end = start + m[0].length;
      if (treffer.some((t) => start < t.end && end > t.start)) continue;
      treffer.push({ start, end, e });
    }
  }
  treffer.sort((a, b) => a.start - b.start);
  const teile = [];
  let pos = 0;
  for (const t of treffer) {
    if (t.start > pos) teile.push({ text: text.slice(pos, t.start) });
    teile.push({ original: text.slice(t.start, t.end), lautschrift: (t.e.lautschrift || '').trim() || null, ipa: (t.e.ipa || '').trim() || null });
    pos = t.end;
  }
  if (pos < text.length) teile.push({ text: text.slice(pos) });
  return teile;
}

/** SSML-Fragment (ohne <speak>), wie es Twilio im <Say>-Element erwartet. */
export function ssmlFragment(text, lexikon = []) {
  return zerlege(text, lexikon)
    .map((t) => {
      if (t.text !== undefined) return xml(t.text);
      if (t.ipa) return `<phoneme alphabet="ipa" ph="${xml(t.ipa)}">${xml(t.original)}</phoneme>`;
      if (t.lautschrift) return `<sub alias="${xml(t.lautschrift)}">${xml(t.original)}</sub>`;
      return xml(t.original);
    })
    .join('');
}

/** Klartext mit eingesetzter Lautschrift (für Stimmen ohne SSML und zur Anzeige). */
export function gesprochenerText(text, lexikon = []) {
  return zerlege(text, lexikon).map((t) => (t.text !== undefined ? t.text : t.lautschrift || t.original)).join('');
}

/** Ganze Ansage: Abschnitte mit Pausen dazwischen, optional mit Sprechtempo. */
export function ansageSsml(abschnitte, { lexikon = [], pauseMs = 450, tempoProzent = 100 } = {}) {
  const body = abschnitte.map((a) => ssmlFragment(a.text ?? a, lexikon)).join(`<break time="${Math.round(pauseMs)}ms"/>`);
  return tempoProzent && tempoProzent !== 100 ? `<prosody rate="${Math.round(tempoProzent)}%">${body}</prosody>` : body;
}
