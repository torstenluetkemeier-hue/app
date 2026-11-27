// Optionale Transkription von Sprachnachrichten.
// Erwartet einen OpenAI-kompatiblen Endpunkt (/v1/audio/transcriptions), z. B. einen selbst
// gehosteten Whisper-Server in der EU. Ohne STT_URL bleibt die Nachricht ohne Transkript.

export function sttKonfiguriert() {
  return !!process.env.STT_URL;
}

export async function transkribiere(mp3, fetchImpl = globalThis.fetch) {
  if (!process.env.STT_URL) return null;
  const form = new FormData();
  form.append('file', new Blob([mp3], { type: 'audio/mpeg' }), 'nachricht.mp3');
  form.append('model', process.env.STT_MODEL || 'whisper-1');
  form.append('language', 'de');
  const headers = process.env.STT_API_KEY ? { Authorization: `Bearer ${process.env.STT_API_KEY}` } : {};
  const res = await fetchImpl(process.env.STT_URL, { method: 'POST', headers, body: form });
  if (!res.ok) throw new Error(`Transkription fehlgeschlagen (HTTP ${res.status})`);
  const data = await res.json();
  return (data.text || '').trim();
}
