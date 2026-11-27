// Twilio Programmable Voice: TwiML erzeugen, Webhook-Signaturen prüfen, Probeanrufe starten.
// Ablauf: iPhone leitet per bedingter Rufumleitung (**61*…#) auf eine Twilio-Nummer um.
// Twilio ruft /tw/voice auf, der Server antwortet mit TwiML (Ansage, Tastenwahl, Aufnahme).

import crypto from 'node:crypto';
import { xml, ansageSsml } from '../core/aussprache.js';

export const STIMMEN = {
  'Polly.Vicki-Neural': 'Vicki (weiblich, neural)',
  'Polly.Daniel-Neural': 'Daniel (männlich, neural)',
  'Google.de-DE-Neural2-C': 'Google Neural2 C (weiblich)',
  'Google.de-DE-Neural2-D': 'Google Neural2 D (männlich)',
};

/**
 * Prüft X-Twilio-Signature: HMAC-SHA1 über die volle URL plus alle POST-Parameter
 * (alphabetisch sortiert, Name+Wert aneinandergehängt), Base64, Schlüssel = Auth-Token.
 */
export function signatur(authToken, url, params = {}) {
  const daten = url + Object.keys(params).sort().map((k) => k + params[k]).join('');
  return crypto.createHmac('sha1', authToken).update(Buffer.from(daten, 'utf8')).digest('base64');
}

export function signaturGueltig(authToken, url, params, header) {
  if (!authToken || !header) return false;
  const soll = Buffer.from(signatur(authToken, url, params));
  const ist = Buffer.from(String(header));
  return soll.length === ist.length && crypto.timingSafeEqual(soll, ist);
}

/** Sprechtempo der App (iOS-Rate, 0,5 = normal) in Prozent für SSML. */
export function tempoProzent(tempo) {
  if (!tempo) return 100;
  return Math.max(70, Math.min(130, Math.round((tempo / 0.5) * 100)));
}

function say(ssml, stimme) {
  return `<Say voice="${xml(stimme)}" language="de-DE">${ssml}</Say>`;
}

/**
 * Baut die TwiML-Antwort aus dem Ablauf der Ansage-Engine.
 * @param antwort   Ergebnis von answerCall()
 * @param opts      { callId, basis (öffentliche URL), stimme, lexikon, pauseMs, tempo }
 */
export function antwortTwiml(antwort, { callId, basis, stimme, lexikon, pauseMs, tempo }) {
  const q = `callId=${encodeURIComponent(callId)}`;
  const ssml = ansageSsml(antwort.ansage.abschnitte, { lexikon, pauseMs, tempoProzent: tempoProzent(tempo) });
  const teile = [];
  const direkt = antwort.ablauf.find((s) => s.typ === 'weiterleiten');
  const auswahl = antwort.ablauf.find((s) => s.typ === 'auswahl');
  const aufnahme = antwort.ablauf.find((s) => s.typ === 'aufnahme');

  if (direkt) {
    teile.push(say(ssml, stimme), `<Dial>${xml(waehlbar(direkt.ziel.telefon))}</Dial>`);
  } else if (auswahl) {
    // Während der Ansage kann die Taste gedrückt werden; ohne Eingabe geht es mit der Aufnahme weiter.
    teile.push(`<Gather input="dtmf" numDigits="1" timeout="2" action="${xml(`${basis}/tw/taste?${q}`)}" method="POST">${say(ssml, stimme)}</Gather>`);
  } else {
    teile.push(say(ssml, stimme));
  }
  if (!direkt) {
    if (aufnahme) teile.push(recordTwiml(aufnahme.maxSekunden, basis, q));
    else teile.push('<Hangup/>');
  }
  return dokument(teile);
}

export function recordTwiml(maxSekunden, basis, q) {
  return `<Record maxLength="${Number(maxSekunden) || 120}" timeout="5" playBeep="true" trim="trim-silence" ` +
    `action="${xml(`${basis}/tw/aufnahme-ende?${q}`)}" method="POST" ` +
    `recordingStatusCallback="${xml(`${basis}/tw/aufnahme?${q}`)}" recordingStatusCallbackMethod="POST"/>`;
}

export function weiterleitenTwiml(ziel, stimme) {
  return dokument([say(`Einen Moment bitte, ich verbinde Sie mit ${xml(ziel.name)}.`, stimme), `<Dial>${xml(waehlbar(ziel.telefon))}</Dial>`]);
}

export function abschiedTwiml(stimme) {
  return dokument([say('Vielen Dank für Ihre Nachricht. Auf Wiederhören!', stimme), '<Hangup/>']);
}

export function fehlerTwiml(stimme) {
  return dokument([say('Leider ist gerade ein technischer Fehler aufgetreten. Bitte versuchen Sie es später noch einmal.', stimme), '<Hangup/>']);
}

function dokument(teile) {
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${teile.join('')}</Response>`;
}

/** "+49 3641 000 200" -> "+493641000200" (Twilio erwartet E.164) */
export function waehlbar(nummer) {
  const s = String(nummer || '').replace(/\(0\)/g, '');
  const ziffern = s.replace(/[^\d+]/g, '');
  if (ziffern.startsWith('+')) return ziffern;
  if (ziffern.startsWith('00')) return '+' + ziffern.slice(2);
  if (ziffern.startsWith('0')) return '+49' + ziffern.slice(1);
  return ziffern;
}

/** Ausgehender Probeanruf: Twilio ruft `an` an und spielt die TwiML ab. */
export async function probeanruf({ accountSid, authToken, von, an, twiml }, fetchImpl = globalThis.fetch) {
  const body = new URLSearchParams({ To: waehlbar(an), From: waehlbar(von), Twiml: twiml });
  const res = await fetchImpl(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/Calls.json`, {
    method: 'POST',
    headers: {
      Authorization: 'Basic ' + Buffer.from(`${accountSid}:${authToken}`).toString('base64'),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Twilio: ${data.message || 'HTTP ' + res.status}`);
  return { sid: data.sid, status: data.status };
}

/** Aufnahme als MP3 laden (Twilio-Aufnahmen sind per Basic-Auth geschützt). */
export async function ladeAufnahme({ accountSid, authToken }, aufnahmeUrl, fetchImpl = globalThis.fetch) {
  const url = /\.(mp3|wav)$/.test(aufnahmeUrl) ? aufnahmeUrl : aufnahmeUrl + '.mp3';
  const res = await fetchImpl(url, { headers: { Authorization: 'Basic ' + Buffer.from(`${accountSid}:${authToken}`).toString('base64') } });
  if (!res.ok) throw new Error(`Aufnahme nicht abrufbar (HTTP ${res.status})`);
  return Buffer.from(await res.arrayBuffer());
}
