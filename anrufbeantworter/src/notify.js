// Benachrichtigung über neue Nachrichten.
// Prototyp: Webhook (z. B. Teams, Slack, Mattermost) und Konsolen-Log statt E-Mail.

export async function notify(user, nachricht, fetchImpl = globalThis.fetch) {
  const k = nachricht.kontakt;
  const wer = k ? [k.anrede, k.titel, k.vorname, k.nachname].filter(Boolean).join(' ') || k.organisation : nachricht.nummer || 'Unbekannt';
  const text =
    `📞 Neue Nachricht für ${user.profil.vorname} ${user.profil.nachname} von ${wer}` +
    (k?.organisation && wer !== k.organisation ? ` (${k.organisation})` : '') +
    (nachricht.nummer ? `, ${nachricht.nummer}` : '') +
    (nachricht.prioritaet === 'hoch' ? ' [HOHE PRIORITÄT]' : '') +
    (nachricht.transkript ? `\n„${nachricht.transkript}“` : '');

  const ergebnisse = [];
  if (user.optionen?.benachrichtigung?.email && user.profil.email) {
    // Hier würde produktiv eine E-Mail (SMTP/Graph) verschickt.
    console.log(`[E-Mail an ${user.profil.email}] ${text}`);
    ergebnisse.push({ kanal: 'email', ok: true, simuliert: true });
  }
  const hook = user.optionen?.benachrichtigung?.webhookUrl;
  if (hook) {
    try {
      const res = await fetchImpl(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text }) });
      ergebnisse.push({ kanal: 'webhook', ok: res.ok });
    } catch (e) {
      ergebnisse.push({ kanal: 'webhook', ok: false, fehler: e.message });
    }
  }
  return { text, ergebnisse };
}
