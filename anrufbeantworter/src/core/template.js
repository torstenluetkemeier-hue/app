// Minimaler Platzhalter-Renderer für Ansagetexte.
//   {{pfad.zum.wert}}            -> Wert einsetzen (leer, wenn nicht vorhanden)
//   {{#pfad}} ... {{/pfad}}      -> Abschnitt nur ausgeben, wenn der Wert gesetzt ist
//   {{^pfad}} ... {{/pfad}}      -> Abschnitt nur ausgeben, wenn der Wert NICHT gesetzt ist

function lookup(ctx, path) {
  return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), ctx);
}

function truthy(v) {
  if (Array.isArray(v)) return v.length > 0;
  return v !== undefined && v !== null && v !== false && v !== '';
}

export function render(template, ctx) {
  let out = String(template ?? '');
  // Abschnitte von innen nach außen auflösen (keine gleichnamige Verschachtelung nötig)
  const section = /\{\{([#^])\s*([\w.]+)\s*\}\}([\s\S]*?)\{\{\/\s*\2\s*\}\}/;
  let guard = 0;
  while (section.test(out) && guard++ < 100) {
    out = out.replace(section, (_, type, path, inner) => {
      const v = truthy(lookup(ctx, path));
      return (type === '#' ? v : !v) ? inner : '';
    });
  }
  out = out.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, path) => {
    const v = lookup(ctx, path);
    return v == null ? '' : String(v);
  });
  return tidy(out);
}

/** Leerräume und verwaiste Satzzeichen nach dem Einsetzen bereinigen. */
export function tidy(text) {
  return text
    .replace(/\s+/g, ' ')
    .replace(/\s+([,.!?:;])/g, '$1')
    .replace(/,\s*([.!?])/g, '$1')
    .replace(/([.!?])\s*\./g, '$1')
    .trim();
}

/** Alle in einer Vorlage verwendeten Platzhalter (für Validierung im UI). */
export function placeholders(template) {
  const set = new Set();
  for (const m of String(template).matchAll(/\{\{\s*[#^/]?\s*([\w.]+)\s*\}\}/g)) set.add(m[1]);
  return [...set];
}
