// Rufnummern normalisieren und für die Sprachausgabe aufbereiten.

/**
 * Wandelt eine Rufnummer in E.164 um (Standard-Landesvorwahl: Deutschland).
 * "0171 / 234 56-78" -> "+491712345678", "0049 40 123" -> "+4940123".
 * Gibt null zurück, wenn keine Nummer übermittelt wurde (anonymer Anruf).
 */
export function normalizeNumber(raw, defaultCountry = '49') {
  if (raw === null || raw === undefined) return null;
  let s = String(raw).trim();
  if (!s || /^(anonymous|anonym|unknown|unbekannt|restricted|private)$/i.test(s)) return null;
  // SIP-URIs wie "sip:+4930123@pbx.example" auf den Nummernteil reduzieren
  const sip = s.match(/^sips?:([^@;]+)/i);
  if (sip) s = sip[1];
  // "+49 (0) 30 …": die eingeklammerte 0 entfällt bei internationaler Schreibweise
  s = s.replace(/\(\s*0\s*\)/g, '');
  const plus = s.startsWith('+');
  let digits = s.replace(/\D/g, '');
  if (!digits) return null;
  if (plus) return '+' + digits;
  if (digits.startsWith('00')) return '+' + digits.slice(2);
  if (digits.startsWith('0')) return '+' + defaultCountry + digits.slice(1);
  // Interne Durchwahlen (kurz) bleiben unverändert
  if (digits.length <= 6) return digits;
  return '+' + digits;
}

/** Nummer für die Ansage: Ziffern einzeln, in Gruppen mit Pausen ("0 1 7 1, 2 3 4, 5 6 7 8"). */
export function speakableNumber(raw) {
  if (!raw) return '';
  let s = String(raw).trim();
  if (s.startsWith('+49')) s = '0' + s.slice(3).replace(/^[\s/\-()]+/, '');
  else if (s.startsWith('+')) s = 'plus ' + s.slice(1);
  const groups = s
    .split(/[\s/\-()]+/)
    .map((g) => g.replace(/[^\d]/g, ''))
    .filter(Boolean);
  const chunks = groups.length > 1 ? groups : chunk(groups[0] || '', 3);
  const prefix = s.startsWith('plus ') ? 'plus ' : '';
  return prefix + chunks.map((g) => g.split('').join(' ')).join(', ');
}

function chunk(str, size) {
  const out = [];
  for (let i = 0; i < str.length; i += size) out.push(str.slice(i, i + size));
  return out;
}
