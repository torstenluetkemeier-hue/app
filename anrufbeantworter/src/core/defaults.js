// Stammdaten und Standardkonfiguration des Anrufbeantworters.
import crypto from 'node:crypto';

export const MODI = {
  standard: { label: 'Standard (nicht erreichbar)', kurz: 'Standard' },
  termin: { label: 'Im Termin', kurz: 'Termin' },
  abwesend: { label: 'Unterwegs (Dienstreise, Messe …)', kurz: 'Unterwegs' },
  urlaub: { label: 'Urlaub', kurz: 'Urlaub' },
  krank: { label: 'Krank / nicht im Büro', kurz: 'Krank' },
  feierabend: { label: 'Außerhalb der Geschäftszeiten', kurz: 'Feierabend' },
};

/** Termin-Arten: Bezeichnung im UI und Formulierung in der Ansage. */
export const TERMIN_ARTEN = {
  'online-praesentation': { label: 'Online-Präsentation', ansage: 'in einer Online-Präsentation' },
  'praesentation-vor-ort': { label: 'Präsentation vor Ort', ansage: 'bei einer Präsentation vor Ort' },
  schulung: { label: 'Schulung', ansage: 'in einer Schulung' },
  webinar: { label: 'Online-Schulung / Webinar', ansage: 'in einem Webinar' },
  kundentermin: { label: 'Kundentermin', ansage: 'bei einem Kundentermin' },
  installation: { label: 'Installation / Praxis-Einrichtung', ansage: 'bei einer Installation in einer Praxis' },
  meeting: { label: 'Besprechung', ansage: 'in einer Besprechung' },
  telefonat: { label: 'Anderes Gespräch', ansage: 'in einem anderen Gespräch' },
  sonstiges: { label: 'Sonstiges (Freitext)', ansage: 'in einem Termin' },
};

export const ABWESEND_ARTEN = {
  dienstreise: { label: 'Dienstreise', ansage: 'auf Dienstreise' },
  messe: { label: 'Messe / Kongress', ansage: 'auf einer Messe' },
  fortbildung: { label: 'Fortbildung', ansage: 'auf einer Fortbildung' },
  sonstiges: { label: 'Sonstiges (Freitext)', ansage: 'unterwegs' },
};

export const REGEL_BEDINGUNGEN = {
  alle: 'Alle Anrufer',
  kunde: 'Bekannte Kunden (Praxen)',
  meineKunden: 'Meine Kunden (ich bin Betreuer)',
  vip: 'VIP-Kontakte',
  intern: 'Interne Kollegen',
  unbekannt: 'Unbekannte Nummern',
  anonym: 'Rufnummer unterdrückt',
  nummern: 'Bestimmte Rufnummern',
};

export const DEFAULT_TEXTE = {
  intro:
    '{{begruessung}}! Sie sind verbunden mit dem Anschluss von {{ich.name}}{{#ich.funktion}}, {{ich.funktion}}{{/ich.funktion}} bei {{firma.name}}, Ihrem Team für {{firma.produkt}}.',
  introDu: '{{begruessung}}! Hier ist der Anrufbeantworter von {{ich.vorname}}.',
  modi: {
    standard: 'Ich bin gerade nicht erreichbar, rufe Sie aber gerne zurück.',
    termin: 'Ich bin gerade {{grund}}{{#bis}}, {{bis}}{{/bis}}, und daher nicht erreichbar. Ich rufe Sie im Anschluss gerne zurück.',
    abwesend: 'Ich bin {{grund}}{{#bis}}, {{bis}}{{/bis}}, und nur eingeschränkt erreichbar.',
    urlaub: 'Ich bin im Urlaub{{#bis}}, {{bis}}{{/bis}}.',
    krank: 'Ich bin derzeit leider nicht im Büro{{#bis}}, {{bis}}{{/bis}}.',
    feierabend:
      'Sie rufen außerhalb meiner Geschäftszeiten an.{{#naechsteErreichbarkeit}} Ich bin {{naechsteErreichbarkeit}} wieder für Sie da.{{/naechsteErreichbarkeit}}',
  },
  vertretung: 'In dringenden Fällen wenden Sie sich bitte an {{vertretung.name}}, erreichbar unter {{vertretung.telefonAnsage}}.',
  weiterleitung: 'Wenn Sie direkt mit {{weiterleitung.name}} verbunden werden möchten, drücken Sie jetzt die {{weiterleitung.taste}}.',
  supportHinweis:
    'Bei dringenden technischen Fragen zu {{firma.produkt}} erreichen Sie unseren Support unter {{firma.supportAnsage}}.',
  abschluss: 'Bitte hinterlassen Sie nach dem Signalton Ihren Namen, Ihre Rufnummer und Ihr Anliegen. Vielen Dank für Ihren Anruf!',
  abschlussBekannt:
    'Bitte hinterlassen Sie nach dem Signalton eine kurze Nachricht, Ihre Rufnummer liegt mir bereits vor. Vielen Dank für Ihren Anruf!',
  abschlussOhneAufnahme: 'Vielen Dank für Ihren Anruf und auf Wiederhören!',
};

export function defaultUser() {
  return {
    id: 'mmeyer',
    profil: {
      vorname: 'Max',
      nachname: 'Meyer',
      funktion: 'Kundenberater',
      team: 'Vertrieb',
      durchwahl: '+49 3641 000 100',
      email: 'max.meyer@example.org',
    },
    firma: {
      name: 'zollsoft',
      produkt: 'tomedo',
      support: '',
    },
    geschaeftszeiten: {
      mo: [['08:00', '17:00']],
      di: [['08:00', '17:00']],
      mi: [['08:00', '17:00']],
      do: [['08:00', '17:00']],
      fr: [['08:00', '15:00']],
      sa: [],
      so: [],
    },
    vertretungen: [
      { id: 'tmueller', name: 'Thomas Müller', telefon: '+49 3641 000 200', email: 'thomas.mueller@example.org' },
    ],
    standardVertretungId: 'tmueller',
    // Manuell gesetzter Status (übersteuert Kalender und Geschäftszeiten), null = automatisch
    status: null,
    // Geplante Abwesenheiten und Termine
    kalender: [],
    regeln: [
      {
        id: 'r-vip', aktiv: true, name: 'VIP-Kunden dürfen zur Vertretung durchgestellt werden',
        bedingung: { typ: 'vip' },
        aktion: { weiterleitungAnbieten: true, prioritaet: 'hoch' },
      },
      {
        id: 'r-meine', aktiv: true, name: 'Meine Kunden: Rückruf mit hoher Priorität',
        bedingung: { typ: 'meineKunden' },
        aktion: { prioritaet: 'hoch', supportHinweis: true },
      },
      {
        id: 'r-kunde', aktiv: true, name: 'Kunden: Support-Hinweis ansagen',
        bedingung: { typ: 'kunde' },
        aktion: { supportHinweis: true },
      },
      {
        id: 'r-sperre', aktiv: false, name: 'Werbeanrufe sperren',
        bedingung: { typ: 'nummern', nummern: ['+4989999999'] },
        aktion: { sperren: true },
      },
    ],
    optionen: {
      anruferErkennung: true,
      // 'immer' | 'nurKunden' | 'nie' – wann der Anrufer mit Namen angesprochen wird
      nameNennen: 'immer',
      // In diesen Modi wird automatisch die Standard-Vertretung genannt
      vertretungNennenIn: ['urlaub', 'krank', 'abwesend'],
      weiterleitungTaste: '1',
      aufnehmen: true,
      maxNachrichtSekunden: 120,
      rueckrufAufgabe: true,
      transkription: true,
      benachrichtigung: { email: true, webhookUrl: '' },
      stimme: 'de-DE',
    },
    texte: structuredClone(DEFAULT_TEXTE),
    // Persönliches Aussprache-Wörterbuch (aus der iPhone-App synchronisiert)
    lexikon: [],
    // Sprechweise (aus der iPhone-App): Tempo wie iOS (0,5 = normal), Pause zwischen Abschnitten
    stimme: { tempo: 0.48, pauseMs: 450 },
    // Cloud-Anrufbeantworter: eigene sipgate-Nummer und/oder Handynummer, von der umgeleitet wird
    cloud: { nummer: '', mobilnummer: '' },
    appTokenHash: null,
    appSync: null,
  };
}

/** Ergänzt fehlende Felder in älteren Konfigurationsdateien. */
export function migrateConfig(config) {
  const d = defaultConfig();
  const t = config.telefonie || {};
  config.telefonie = {
    publicUrl: t.publicUrl ?? '',
    sipgate: { ...d.telefonie.sipgate, ...(t.sipgate || {}) },
    tts: { ...d.telefonie.tts, ...(t.tts || {}) },
  };
  // Geheimer Teil der Webhook-Adresse (sipgate signiert Webhooks nicht)
  if (!config.telefonie.sipgate.webhookGeheimnis) config.telefonie.sipgate.webhookGeheimnis = crypto.randomBytes(18).toString('base64url');
  if (!config.telefonie.audioGeheimnis) config.telefonie.audioGeheimnis = crypto.randomBytes(24).toString('base64url');
  config.lexikon ??= [];
  for (const u of config.users || []) {
    const du = defaultUser();
    for (const k of ['lexikon', 'stimme', 'cloud', 'appTokenHash', 'appSync']) u[k] ??= du[k];
    u.texte = { ...du.texte, ...(u.texte || {}), modi: { ...du.texte.modi, ...(u.texte?.modi || {}) } };
  }
  return config;
}

export function defaultConfig() {
  return {
    crm: {
      // 'mock' | 'qto' | 'zswork'
      adapter: 'mock',
      qto: { baseUrl: '', apiToken: '', lookupPath: '/api/v1/contacts?phone={nummer}', taskPath: '/api/v1/tasks' },
      zswork: { baseUrl: '', apiToken: '', lookupPath: '/api/contacts/by-phone/{nummer}', taskPath: '/api/callbacks' },
      timeoutMs: 1500,
      cacheMinuten: 10,
    },
    telefonie: {
      // Öffentliche Basis-URL des Servers (sipgate ruft Webhooks und Audiodateien darüber ab), z. B. https://ab.example.de
      publicUrl: '',
      // sipgate.io (sipgate GmbH, Düsseldorf)
      sipgate: {
        webhookGeheimnis: '',
        // Nach der Ansage: sipgate-Mailbox nimmt die Nachricht auf (Funktion in sipgate buchen)
        mailbox: true,
      },
      // Sprachausgabe mit Piper auf eigenem Server (Open Source, keine Daten an Dritte)
      tts: {
        piperUrl: '',
        stimme: 'de_DE-thorsten-high',
        // IPA-Korrekturen als Piper-Rohphoneme [[ … ]] übergeben (sonst Lautschrift)
        ipaInline: true,
      },
    },
    // Firmenweites Aussprache-Wörterbuch (z. B. Kundennamen); persönliche Einträge haben Vorrang
    lexikon: [],
    users: [defaultUser()],
  };
}
