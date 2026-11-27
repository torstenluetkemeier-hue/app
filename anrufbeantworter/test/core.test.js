import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeNumber, speakableNumber } from '../src/core/phone.js';
import { render } from '../src/core/template.js';
import { fromLocal, localParts, describeUntil } from '../src/core/time.js';
import { answerCall, resolveStatus, nextAvailability } from '../src/core/engine.js';
import { defaultUser } from '../src/core/defaults.js';
import { MockAdapter } from '../src/crm/mock.js';

const at = (s) => fromLocal(s);
const mock = new MockAdapter();
const call = async (user, from, when) => {
  const nummer = normalizeNumber(from);
  return answerCall(user, { nummer, kontakt: await mock.findByPhone(nummer) }, at(when));
};
// Freitag, 27.11.2026, Geschäftszeiten Fr 08–15 Uhr
const FR_VORMITTAG = '2026-11-27T10:00';

test('Rufnummern werden nach E.164 normalisiert', () => {
  assert.equal(normalizeNumber('040 / 123 45-67'), '+49401234567');
  assert.equal(normalizeNumber('0049 89 7654321'), '+49897654321');
  assert.equal(normalizeNumber('+49 (0) 30 555'), '+4930555');
  assert.equal(normalizeNumber('sip:+4930123456@pbx.local'), '+4930123456');
  assert.equal(normalizeNumber('anonymous'), null);
  assert.equal(normalizeNumber(''), null);
  assert.equal(normalizeNumber('2301'), '2301');
});

test('Rufnummern werden für die Ansage in Ziffern zerlegt', () => {
  assert.equal(speakableNumber('+49 3641 000 200'), '0 3 6 4 1, 0 0 0, 2 0 0');
});

test('Vorlagen: Platzhalter und bedingte Abschnitte', () => {
  const tpl = 'Ich bin {{grund}}{{#bis}}, {{bis}}{{/bis}}.{{^vertretung}} Ohne Vertretung.{{/vertretung}}';
  assert.equal(render(tpl, { grund: 'im Urlaub', bis: 'bis Freitag' }), 'Ich bin im Urlaub, bis Freitag. Ohne Vertretung.');
  assert.equal(render(tpl, { grund: 'im Urlaub', vertretung: { name: 'X' } }), 'Ich bin im Urlaub.');
});

test('Zeit: Berliner Ortszeit inkl. Sommerzeit', () => {
  assert.equal(localParts(at('2026-07-01T09:30')).stamp, '2026-07-01T09:30');
  assert.equal(localParts(at('2026-12-01T09:30')).stamp, '2026-12-01T09:30');
  const now = localParts(at('2026-11-27T10:00'));
  assert.equal(describeUntil('2026-11-27T15:00', now), 'voraussichtlich bis 15 Uhr');
  assert.equal(describeUntil('2026-12-04', now, true), 'bis einschließlich Freitag, 4. Dezember');
});

test('Standard: unbekannter Anrufer wird neutral begrüßt, Zollsoft/tomedo wird genannt', async () => {
  const r = await call(defaultUser(), '+49 30 999 888 77', FR_VORMITTAG);
  assert.equal(r.status.modus, 'standard');
  assert.equal(r.anrufer.erkannt, false);
  assert.match(r.ansage.text, /^Guten Morgen! Sie sind verbunden mit dem Anschluss von Max Meyer, Kundenberater bei zollsoft, Ihrem Team für tomedo\./);
  assert.match(r.ansage.text, /Ihren Namen, Ihre Rufnummer und Ihr Anliegen/);
  assert.deepEqual(r.ablauf.map((s) => s.typ), ['ansage', 'aufnahme', 'auflegen']);
});

test('Erkannter Kunde wird mit Namen angesprochen', async () => {
  const r = await call(defaultUser(), '040 1234567', FR_VORMITTAG);
  assert.equal(r.anrufer.erkannt, true);
  assert.match(r.ansage.text, /^Guten Morgen, Frau Dr\. Schneider!/);
  assert.match(r.ansage.text, /Ihre Rufnummer liegt mir bereits vor/);
  // Regel "Meine Kunden" -> hohe Priorität
  assert.equal(r.rueckruf.prioritaet, 'hoch');
});

test('Praxis ohne Ansprechpartner wird als Team begrüßt', async () => {
  const r = await call(defaultUser(), '+49 30 5550100', FR_VORMITTAG);
  assert.match(r.ansage.text, /^Guten Morgen, liebes Team von Kinderarztpraxis Sonnenschein!/);
});

test('Name nennen lässt sich abschalten', async () => {
  const u = defaultUser();
  u.optionen.nameNennen = 'nie';
  const r = await call(u, '040 1234567', FR_VORMITTAG);
  assert.match(r.ansage.text, /^Guten Morgen! /);
});

test('Manueller Status "Online-Präsentation" mit Uhrzeit, danach automatisch zurück', async () => {
  const u = defaultUser();
  u.status = { modus: 'termin', art: 'online-praesentation', bis: '2026-11-27T11:30' };
  const r = await call(u, null, FR_VORMITTAG);
  assert.equal(r.status.quelle, 'manuell');
  assert.match(r.ansage.text, /Ich bin gerade in einer Online-Präsentation, voraussichtlich bis 11 Uhr 30, und daher nicht erreichbar\./);
  const spaeter = resolveStatus(u, at('2026-11-27T12:00'));
  assert.equal(spaeter.modus, 'standard');
});

test('Urlaub aus dem Kalender nennt die Vertretung mit Rufnummer', async () => {
  const u = defaultUser();
  u.kalender.push({ id: 'u1', modus: 'urlaub', von: '2026-12-21', bis: '2027-01-04', ganztags: true });
  const r = await call(u, '+49 89 999', '2026-12-22T09:00');
  assert.equal(r.status.modus, 'urlaub');
  assert.match(r.ansage.text, /Ich bin im Urlaub, bis einschließlich Montag, 4\. Januar\./);
  assert.match(r.ansage.text, /wenden Sie sich bitte an Thomas Müller, erreichbar unter 0 3 6 4 1, 0 0 0, 2 0 0\./);
});

test('Urlaub ohne Vertretungsnennung, wenn am Eintrag "keine" gewählt ist', async () => {
  const u = defaultUser();
  u.kalender.push({ id: 'u1', modus: 'urlaub', von: '2026-12-21', bis: '2027-01-04', ganztags: true, vertretungId: '' });
  const r = await call(u, null, '2026-12-22T09:00');
  assert.doesNotMatch(r.ansage.text, /Thomas Müller/);
});

test('Spezifischer Termin gewinnt gegen längere Abwesenheit', () => {
  const u = defaultUser();
  u.kalender.push({ id: 'a', modus: 'abwesend', art: 'messe', von: '2026-11-25', bis: '2026-11-28', ganztags: true });
  u.kalender.push({ id: 'b', modus: 'termin', art: 'schulung', von: '2026-11-27T09:00', bis: '2026-11-27T12:00' });
  assert.equal(resolveStatus(u, at(FR_VORMITTAG)).eintragId, 'b');
  assert.equal(resolveStatus(u, at('2026-11-27T13:00')).eintragId, 'a');
});

test('Außerhalb der Geschäftszeiten: nächste Erreichbarkeit wird angesagt', async () => {
  const u = defaultUser();
  const r = await call(u, null, '2026-11-27T16:00'); // Freitag nach 15 Uhr
  assert.equal(r.status.modus, 'feierabend');
  assert.match(r.ansage.text, /Ich bin am Montag ab 8 Uhr wieder für Sie da\./);
  assert.equal(nextAvailability(u, localParts(at('2026-11-26T07:00'))), 'heute ab 8 Uhr');
  assert.equal(nextAvailability(u, localParts(at('2026-11-26T19:00'))), 'morgen ab 8 Uhr');
});

test('VIP-Regel bietet Weiterleitung per Taste 1 an', async () => {
  const r = await call(defaultUser(), '+49 89 7654321', FR_VORMITTAG);
  assert.match(r.ansage.text, /Herr Prof\. Dr\. Hoffmann/);
  assert.match(r.ansage.text, /drücken Sie jetzt die 1\./);
  const auswahl = r.ablauf.find((s) => s.typ === 'auswahl');
  assert.equal(auswahl.ziel.name, 'Thomas Müller');
});

test('Gesperrte Nummer: keine Aufnahme, keine Aufgabe', async () => {
  const u = defaultUser();
  u.regeln.find((r) => r.id === 'r-sperre').aktiv = true;
  const r = await call(u, '089 999999', FR_VORMITTAG);
  assert.deepEqual(r.ablauf.map((s) => s.typ), ['ansage', 'auflegen']);
  assert.equal(r.rueckruf.aufgabe, false);
});

test('Regel mit direkter Weiterleitung nur im Urlaub', async () => {
  const u = defaultUser();
  u.regeln.push({ id: 'x', aktiv: true, name: 'Meine Kunden im Urlaub direkt zu Thomas', bedingung: { typ: 'meineKunden', modi: ['urlaub'] }, aktion: { direktWeiterleiten: true } });
  const normal = await call(u, '040 1234567', FR_VORMITTAG);
  assert.equal(normal.ablauf[1].typ, 'aufnahme');
  u.status = { modus: 'urlaub', bis: '2026-12-01', ganztags: true };
  const urlaub = await call(u, '040 1234567', FR_VORMITTAG);
  assert.equal(urlaub.ablauf[1].typ, 'weiterleiten');
  assert.match(urlaub.ansage.text, /ich verbinde Sie mit Thomas Müller/);
});

test('Kollegen werden geduzt', async () => {
  const r = await call(defaultUser(), '+49 3641 000 300', FR_VORMITTAG);
  assert.match(r.ansage.text, /^Hallo Julia! Hier ist der Anrufbeantworter von Max\./);
});
