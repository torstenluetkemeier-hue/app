// Entscheidungslogik: Welcher Status gilt gerade, welche Regeln greifen,
// und welche Ansage hört der Anrufer? Reine Funktionen ohne I/O, damit sie
// gleichermaßen im Server, in Tests und später in einer Mobil-App laufen.

import { MODI, TERMIN_ARTEN, ABWESEND_ARTEN, DEFAULT_TEXTE } from './defaults.js';
import { render } from './template.js';
import { speakableNumber, normalizeNumber } from './phone.js';
import { localParts, describeUntil, dayGreeting, isWithin, spokenTime } from './time.js';

const WEEK = ['so', 'mo', 'di', 'mi', 'do', 'fr', 'sa'];
const WEEK_NAMES = { mo: 'Montag', di: 'Dienstag', mi: 'Mittwoch', do: 'Donnerstag', fr: 'Freitag', sa: 'Samstag', so: 'Sonntag' };

/** Formulierung für den Grund (Termin-Art, Abwesenheits-Art oder Freitext). */
export function grundText(modus, art, freitext) {
  if (freitext && (art === 'sonstiges' || !art)) return freitext;
  if (modus === 'termin') return (TERMIN_ARTEN[art] || TERMIN_ARTEN.sonstiges).ansage;
  if (modus === 'abwesend') return (ABWESEND_ARTEN[art] || ABWESEND_ARTEN.sonstiges).ansage;
  return freitext || '';
}

/** Liegt der Zeitpunkt innerhalb der Geschäftszeiten? */
export function inBusinessHours(user, parts) {
  const slots = user.geschaeftszeiten?.[parts.weekday] || [];
  return slots.some(([von, bis]) => parts.time >= von && parts.time < bis);
}

/** Nächster Beginn der Geschäftszeit, z. B. "morgen ab 8 Uhr". */
export function nextAvailability(user, parts) {
  for (let offset = 0; offset < 8; offset++) {
    const wd = WEEK[(parts.weekdayIndex + offset) % 7];
    const slots = [...(user.geschaeftszeiten?.[wd] || [])].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [von] of slots) {
      if (offset === 0 && von <= parts.time) continue;
      const ab = `ab ${spokenTime(von)}`;
      if (offset === 0) return `heute ${ab}`;
      if (offset === 1) return `morgen ${ab}`;
      return `am ${WEEK_NAMES[wd]} ${ab}`;
    }
  }
  return '';
}

/**
 * Ermittelt den aktuell gültigen Status.
 * Reihenfolge: manueller Status > Kalendereintrag > Geschäftszeiten > Standard.
 */
export function resolveStatus(user, now = new Date()) {
  const parts = localParts(now);
  const manuell = user.status;
  if (manuell && manuell.modus && (!manuell.bis || isWithin(parts.stamp, '0000-01-01T00:00', manuell.bis, manuell.ganztags))) {
    return statusFrom(manuell, 'manuell', parts);
  }
  const eintrag = (user.kalender || [])
    .filter((e) => e.aktiv !== false && isWithin(parts.stamp, e.von, e.bis, e.ganztags))
    // Kürzere (spezifischere) Einträge gewinnen, z. B. ein Termin während einer Dienstreise
    .sort((a, b) => span(a) - span(b))[0];
  if (eintrag) return statusFrom(eintrag, 'kalender', parts);
  const hatZeiten = Object.values(user.geschaeftszeiten || {}).some((s) => s.length);
  if (hatZeiten && !inBusinessHours(user, parts)) {
    return { modus: 'feierabend', label: MODI.feierabend.label, quelle: 'geschaeftszeiten', naechsteErreichbarkeit: nextAvailability(user, parts) };
  }
  return { modus: 'standard', label: MODI.standard.label, quelle: 'standard' };
}

function span(e) {
  const a = Date.parse(e.von.length <= 10 ? e.von + 'T00:00' : e.von);
  const b = Date.parse(e.bis.length <= 10 ? e.bis + 'T23:59' : e.bis);
  return b - a;
}

function statusFrom(src, quelle, parts) {
  const modus = MODI[src.modus] ? src.modus : 'standard';
  return {
    modus,
    label: MODI[modus].label,
    quelle,
    eintragId: src.id,
    titel: src.titel || '',
    art: src.art || '',
    grund: grundText(modus, src.art, src.freitext),
    bis: src.bis ? describeUntil(src.bis, parts, src.ganztags) : '',
    bisRoh: src.bis || '',
    vertretungId: src.vertretungId,
    notiz: src.notiz || '',
  };
}

/** Passt eine Regel-Bedingung auf diesen Anruf? */
export function ruleMatches(rule, { user, nummer, kontakt, modus }) {
  if (rule.aktiv === false) return false;
  const b = rule.bedingung || {};
  if (Array.isArray(b.modi) && b.modi.length && !b.modi.includes(modus)) return false;
  switch (b.typ) {
    case 'alle': return true;
    case 'anonym': return !nummer;
    case 'unbekannt': return !!nummer && !kontakt;
    case 'kunde': return !!kontakt && kontakt.typ === 'praxis';
    case 'meineKunden': return !!kontakt && kontakt.typ === 'praxis' && kontakt.betreuerId === user.id;
    case 'vip': return !!kontakt && !!kontakt.vip;
    case 'intern': return !!kontakt && kontakt.typ === 'intern';
    case 'nummern': return !!nummer && (b.nummern || []).map((n) => normalizeNumber(n)).includes(nummer);
    default: return false;
  }
}

/** Begrüßung, auf Wunsch mit dem Namen des erkannten Anrufers. */
export function greeting(user, kontakt, parts) {
  const gruss = dayGreeting(parts.hour);
  const mode = user.optionen?.nameNennen || 'immer';
  if (!kontakt || mode === 'nie') return { text: gruss, persoenlich: false, du: false };
  if (mode === 'nurKunden' && !['praxis', 'intern'].includes(kontakt.typ)) return { text: gruss, persoenlich: false, du: false };
  if (kontakt.duzen && kontakt.vorname) return { text: `Hallo ${kontakt.vorname}`, persoenlich: true, du: true };
  if (kontakt.nachname && kontakt.anrede) {
    const name = [kontakt.anrede, kontakt.titel, kontakt.nachname].filter(Boolean).join(' ');
    return { text: `${gruss}, ${name}`, persoenlich: true, du: false };
  }
  if (kontakt.organisation) return { text: `${gruss}, liebes Team von ${kontakt.organisation}`, persoenlich: true, du: false };
  return { text: gruss, persoenlich: false, du: false };
}

function findVertretung(user, id) {
  return (user.vertretungen || []).find((v) => v.id === id) || null;
}

/**
 * Baut die komplette Antwort auf einen eingehenden Anruf.
 * @param user     Konfiguration des angerufenen Mitarbeiters
 * @param anruf    { nummer: E.164 oder null, kontakt: Kontakt aus Qto/ZSWork oder null }
 */
export function answerCall(user, { nummer = null, kontakt = null } = {}, now = new Date()) {
  const parts = localParts(now);
  const status = resolveStatus(user, now);
  const opt = user.optionen || {};
  const texte = { ...DEFAULT_TEXTE, ...(user.texte || {}), modi: { ...DEFAULT_TEXTE.modi, ...(user.texte?.modi || {}) } };

  // Regeln auswerten (alle passenden, spätere überschreiben frühere)
  const angewandt = [];
  const aktion = { weiterleitungAnbieten: false, prioritaet: 'normal', supportHinweis: false, aufnehmen: opt.aufnehmen !== false, sperren: false, nameNennen: true, zusatzText: '' };
  for (const rule of user.regeln || []) {
    if (!ruleMatches(rule, { user, nummer, kontakt, modus: status.modus })) continue;
    angewandt.push({ id: rule.id, name: rule.name });
    for (const [k, v] of Object.entries(rule.aktion || {})) {
      if (k === 'zusatzText') aktion.zusatzText = [aktion.zusatzText, v].filter(Boolean).join(' ');
      else if (v !== undefined && v !== '') aktion[k] = v;
    }
  }

  // Vertretung: explizit am Status/Eintrag, sonst Standard-Vertretung in den konfigurierten Modi
  let vertretung = status.vertretungId ? findVertretung(user, status.vertretungId) : null;
  if (!vertretung && status.vertretungId !== '' && (opt.vertretungNennenIn || []).includes(status.modus)) {
    vertretung = findVertretung(user, user.standardVertretungId);
  }

  // Weiterleitungsziel: aus der Regel oder die Vertretung (bzw. Standard-Vertretung)
  let ziel = null;
  if (aktion.weiterleitungZiel?.telefon) ziel = aktion.weiterleitungZiel;
  else if (aktion.weiterleitungAnbieten || aktion.direktWeiterleiten) ziel = vertretung || findVertretung(user, user.standardVertretungId);

  const kontaktFuerAnsage = aktion.nameNennen === false || opt.anruferErkennung === false ? null : kontakt;
  const gruss = greeting(user, kontaktFuerAnsage, parts);
  const ctx = {
    begruessung: gruss.text,
    ich: {
      name: `${user.profil.vorname} ${user.profil.nachname}`.trim(),
      vorname: user.profil.vorname,
      nachname: user.profil.nachname,
      funktion: user.profil.funktion,
      team: user.profil.team,
    },
    firma: {
      name: user.firma?.name,
      produkt: user.firma?.produkt,
      support: user.firma?.support,
      supportAnsage: speakableNumber(user.firma?.support),
    },
    anrufer: kontaktFuerAnsage ? { ...kontaktFuerAnsage } : {},
    grund: status.grund,
    bis: status.bis,
    titel: status.titel,
    notiz: status.notiz,
    naechsteErreichbarkeit: status.naechsteErreichbarkeit,
    vertretung: vertretung ? { ...vertretung, telefonAnsage: speakableNumber(vertretung.telefon) } : null,
    weiterleitung: ziel ? { name: ziel.name, telefon: ziel.telefon, taste: opt.weiterleitungTaste || '1' } : null,
  };

  const abschnitte = [];
  const add = (teil, tpl) => {
    const text = render(tpl, ctx);
    if (text) abschnitte.push({ teil, text });
  };

  if (aktion.sperren) {
    add('abschluss', texte.abschlussOhneAufnahme);
    return result([{ typ: 'ansage', text: joinText(abschnitte) }, { typ: 'auflegen' }]);
  }
  if (aktion.direktWeiterleiten && ziel) {
    abschnitte.push({ teil: 'weiterleitung', text: `${gruss.text}! Einen Moment bitte, ich verbinde Sie mit ${ziel.name}.` });
    return result([{ typ: 'ansage', text: joinText(abschnitte) }, { typ: 'weiterleiten', ziel }]);
  }

  add('intro', gruss.du && texte.introDu ? texte.introDu : texte.intro);
  add('status', texte.modi[status.modus] || texte.modi.standard);
  if (vertretung) add('vertretung', texte.vertretung);
  if (aktion.supportHinweis && user.firma?.support) add('support', texte.supportHinweis);
  if (aktion.zusatzText) add('zusatz', aktion.zusatzText);
  if (aktion.weiterleitungAnbieten && ziel) add('weiterleitung', texte.weiterleitung);
  if (aktion.aufnehmen) add('abschluss', kontakt && nummer ? texte.abschlussBekannt : texte.abschluss);
  else add('abschluss', texte.abschlussOhneAufnahme);

  const ablauf = [{ typ: 'ansage', text: joinText(abschnitte) }];
  if (aktion.weiterleitungAnbieten && ziel) ablauf.push({ typ: 'auswahl', taste: ctx.weiterleitung.taste, ziel });
  if (aktion.aufnehmen) ablauf.push({ typ: 'aufnahme', maxSekunden: opt.maxNachrichtSekunden || 120 });
  ablauf.push({ typ: 'auflegen' });
  return result(ablauf);

  function result(ablauf) {
    return {
      zeit: parts.stamp,
      status,
      anrufer: { nummer, anonym: !nummer, erkannt: !!kontakt, kontakt, persoenlichBegruesst: gruss.persoenlich },
      regeln: angewandt,
      ansage: { text: joinText(abschnitte), abschnitte },
      ablauf,
      rueckruf: {
        aufgabe: opt.rueckrufAufgabe !== false && !aktion.sperren,
        prioritaet: aktion.prioritaet,
      },
    };
  }
}

function joinText(abschnitte) {
  return abschnitte.map((a) => a.text).join(' ');
}
