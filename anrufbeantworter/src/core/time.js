// Zeitfunktionen, immer in der Zeitzone Europe/Berlin.
// Termine werden als lokale Zeitstempel "YYYY-MM-DDTHH:MM" gespeichert,
// dadurch lassen sie sich per Stringvergleich ordnen.

export const TZ = 'Europe/Berlin';
const WEEKDAYS = ['so', 'mo', 'di', 'mi', 'do', 'fr', 'sa'];
const WEEKDAY_NAMES = ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag'];
const MONTH_NAMES = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];

/** Zerlegt ein Date in die lokale Berliner Uhrzeit. */
export function localParts(date = new Date(), tz = TZ) {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false, weekday: 'short',
  });
  const p = Object.fromEntries(fmt.formatToParts(date).map((x) => [x.type, x.value]));
  const hour = p.hour === '24' ? '00' : p.hour;
  const dateStr = `${p.year}-${p.month}-${p.day}`;
  const time = `${hour}:${p.minute}`;
  const wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(p.weekday);
  return { date: dateStr, time, stamp: `${dateStr}T${time}`, weekday: WEEKDAYS[wd], weekdayIndex: wd, hour: Number(hour) };
}

/** "2026-12-05" -> "Samstag, 5. Dezember" */
export function spokenDate(dateStr) {
  const [y, m, d] = dateStr.slice(0, 10).split('-').map(Number);
  const wd = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return `${WEEKDAY_NAMES[wd]}, ${d}. ${MONTH_NAMES[m - 1]}`;
}

/** "15:00" -> "15 Uhr", "15:30" -> "15 Uhr 30" */
export function spokenTime(time) {
  const [h, min] = time.split(':').map(Number);
  return min ? `${h} Uhr ${min}` : `${h} Uhr`;
}

/**
 * Beschreibt das Ende einer Abwesenheit für die Ansage.
 * Ganztägig: "bis einschließlich Freitag, 5. Dezember".
 * Mit Uhrzeit, heute: "voraussichtlich bis 15 Uhr".
 * Mit Uhrzeit, anderer Tag: "voraussichtlich bis Freitag, 5. Dezember, 15 Uhr".
 */
export function describeUntil(bis, nowParts, ganztags = false) {
  if (!bis) return '';
  const date = bis.slice(0, 10);
  const time = bis.length > 10 ? bis.slice(11, 16) : null;
  if (ganztags || !time) return `bis einschließlich ${spokenDate(date)}`;
  if (date === nowParts.date) return `voraussichtlich bis ${spokenTime(time)}`;
  return `voraussichtlich bis ${spokenDate(date)}, ${spokenTime(time)}`;
}

/** Tagesgruß abhängig von der Uhrzeit. */
export function dayGreeting(hour) {
  if (hour < 11) return 'Guten Morgen';
  if (hour < 18) return 'Guten Tag';
  return 'Guten Abend';
}

/** Ist ein lokaler Zeitpunkt innerhalb [von, bis]? Ganztägige Einträge gelten bis Tagesende. */
export function isWithin(stamp, von, bis, ganztags = false) {
  const start = ganztags || von.length <= 10 ? von.slice(0, 10) + 'T00:00' : von;
  const end = ganztags || bis.length <= 10 ? bis.slice(0, 10) + 'T23:59' : bis;
  return stamp >= start && stamp <= end;
}

/** Lokaler Berliner Zeitstempel "YYYY-MM-DDTHH:MM" -> Date (für Simulationen). */
export function fromLocal(stamp, tz = TZ) {
  const guess = Date.parse(stamp.slice(0, 16) + ':00Z');
  if (Number.isNaN(guess)) return new Date();
  const diff = Date.parse(localParts(new Date(guess), tz).stamp + ':00Z') - guess;
  return new Date(guess - diff);
}
