// sipgate.io Push-API (sipgate GmbH, Düsseldorf): XML-Antworten auf Anruf-Webhooks.
// Doku: https://developer.sipgate.io/push-api/api-reference/
//
// Ablauf mit Rufumleitung vom Diensthandy auf eine sipgate-Nummer:
//   newCall  → <Gather onData=…><Play>Ansage.wav</Play></Gather>   (Ansage, Taste möglich)
//   dtmf     → <Dial><Number>…</Number></Dial>                     (Taste 1: Vertretung)
//            → <Dial><Voicemail/></Dial>                           (sonst: sipgate-Mailbox nimmt die Nachricht auf)
//   hangup   → Eintrag in der Rückrufliste
//
// Vorgaben von sipgate: Audio als WAV, mono, 16 bit PCM, 8 kHz; Antwort mit Content-Type application/xml.

import { xml } from '../core/aussprache.js';

const KOPF = '<?xml version="1.0" encoding="UTF-8"?>';

/** sipgate erwartet Nummern in E.164 ohne "+": "+49 3641 000 200" → "493641000200" */
export function waehlbar(nummer) {
  let z = String(nummer || '').replace(/\(0\)/g, '').replace(/[^\d+]/g, '');
  if (z.startsWith('+')) z = z.slice(1);
  else if (z.startsWith('00')) z = z.slice(2);
  else if (z.startsWith('0')) z = '49' + z.slice(1);
  return z;
}

/** Ansage abspielen; eine Taste oder das Ende der Ansage ruft onData auf. */
export function ansageXml({ audioUrl, datenUrl, hangupUrl, maxDigits = 1, timeoutMs = 1500 }) {
  const auflegen = hangupUrl ? ` onHangup="${xml(hangupUrl)}"` : '';
  return `${KOPF}<Response${auflegen}><Gather onData="${xml(datenUrl)}" maxDigits="${maxDigits}" timeout="${timeoutMs}">`
    + `<Play><Url>${xml(audioUrl)}</Url></Play></Gather></Response>`;
}

export function waehleXml(nummer) {
  return `${KOPF}<Response><Dial><Number>${xml(waehlbar(nummer))}</Number></Dial></Response>`;
}

/** Übergabe an die sipgate-Mailbox (Funktion muss in sipgate gebucht sein). */
export function mailboxXml() {
  return `${KOPF}<Response><Dial><Voicemail /></Dial></Response>`;
}

export function auflegenXml() {
  return `${KOPF}<Response><Hangup /></Response>`;
}

export function leerXml() {
  return `${KOPF}<Response />`;
}
