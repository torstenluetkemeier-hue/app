// Testdaten-Adapter: simuliert Qto/ZSWork mit fiktiven Kontakten.
// Alle Namen und Nummern sind frei erfunden.

import { normalizeNumber } from '../core/phone.js';

export const MOCK_KONTAKTE = [
  {
    id: 'K-10234', typ: 'praxis', anrede: 'Frau', titel: 'Dr.', vorname: 'Anna', nachname: 'Schneider',
    organisation: 'Hausarztpraxis am Markt', kundennummer: '10234', vip: false, betreuerId: 'mmeyer',
    telefonnummern: ['+49 40 1234567', '0171 1112233'],
    offeneTickets: [{ id: 'T-5521', titel: 'Frage zur eAU-Übermittlung' }],
  },
  {
    id: 'K-20877', typ: 'praxis', anrede: 'Herr', titel: 'Prof. Dr.', vorname: 'Jürgen', nachname: 'Hoffmann',
    organisation: 'MVZ Hoffmann & Kollegen', kundennummer: '20877', vip: true, betreuerId: 'tmueller',
    telefonnummern: ['+49 89 7654321'],
    offeneTickets: [],
  },
  {
    id: 'K-31002', typ: 'praxis', anrede: '', titel: '', vorname: '', nachname: '',
    organisation: 'Kinderarztpraxis Sonnenschein', kundennummer: '31002', vip: false, betreuerId: 'mmeyer',
    telefonnummern: ['+49 30 5550100'],
    offeneTickets: [{ id: 'T-6010', titel: 'Schulungstermin für neue MFA' }],
  },
  {
    id: 'L-4411', typ: 'interessent', anrede: 'Frau', titel: '', vorname: 'Laura', nachname: 'Becker',
    organisation: 'Praxis Becker (Neugründung)', kundennummer: '', vip: false, betreuerId: 'mmeyer',
    telefonnummern: ['+49 221 998877'],
    offeneTickets: [],
  },
  {
    id: 'M-0007', typ: 'intern', anrede: 'Frau', titel: '', vorname: 'Julia', nachname: 'Wagner',
    organisation: 'zollsoft', kundennummer: '', vip: false, betreuerId: '', duzen: true,
    telefonnummern: ['+49 3641 000 300'],
    offeneTickets: [],
  },
];

export class MockAdapter {
  constructor() {
    this.name = 'Testdaten (Mock)';
    this.aufgaben = [];
  }

  async findByPhone(nummer) {
    if (!nummer) return null;
    const k = MOCK_KONTAKTE.find((c) => c.telefonnummern.some((t) => normalizeNumber(t) === nummer));
    return k ? { ...k, quelle: 'mock' } : null;
  }

  async createCallbackTask(task) {
    const id = `MOCK-${this.aufgaben.length + 1}`;
    this.aufgaben.push({ id, ...task });
    return { id, url: null };
  }

  async healthCheck() {
    return { ok: true, info: `${MOCK_KONTAKTE.length} Testkontakte` };
  }
}
