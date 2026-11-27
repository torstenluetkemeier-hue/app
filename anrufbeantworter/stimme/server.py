"""Stimmdienst für den Cloud-Anrufbeantworter.

Spricht kurze dynamische Sätze (z. B. "Guten Tag, Frau Dr. Schneider!") in der Stimme der
aufgenommenen Ansage. Die Stimme wird aus einer Referenzaufnahme übernommen (Chatterbox,
Open Source, MIT-Lizenz). Jedes Ergebnis wird mit Whisper gegengehört; bei Aussetzern
(abgeschnittene oder angehängte Silben) wird neu erzeugt.

Läuft nur im internen Netz, auf einem eigenen Server in Deutschland (am besten mit GPU).

API
  GET  /info         → {"bereit": true, "geraet": "cuda"}
  POST /synthesize   JSON {"text": "...", "referenz": "<WAV base64, optional>", "pruefen": true}
                     → audio/wav (mono, 16 bit); Header X-Versuche, X-Erkannt
"""

import base64
import hashlib
import io
import json
import os
import re
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
import torchaudio
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
from faster_whisper import WhisperModel

GERAET = os.environ.get("GERAET") or ("cuda" if torch.cuda.is_available() else "cpu")
MAX_VERSUCHE = int(os.environ.get("MAX_VERSUCHE", "3"))
AUSDRUCK = float(os.environ.get("AUSDRUCK", "0.45"))  # Chatterbox "exaggeration": ruhig, freundlich

if GERAET == "cpu":
    torch.set_num_threads(os.cpu_count() or 4)

print(f"Lade Modelle auf {GERAET} …", flush=True)
MODELL = ChatterboxMultilingualTTS.from_pretrained(device=GERAET)
STANDARD_STIMME = MODELL.conds
PRUEFER = WhisperModel(os.environ.get("WHISPER_MODELL", "small"), device=GERAET,
                       compute_type="float16" if GERAET == "cuda" else "int8")
SPERRE = threading.Lock()
STIMMEN = {}  # Hash der Referenz → vorbereitete Stimme
print("Bereit.", flush=True)


def woerter(s):
    return re.findall(r"[a-zäöüß]+", s.lower())


def bewertung(soll, ist):
    """Anteil der erwarteten Wörter, die erkannt wurden; zu viele Zusatzwörter = Aussetzer."""
    a, b = woerter(soll), woerter(ist)
    if not a:
        return 1.0
    treffer = sum(1 for w in a if w in b) / len(a)
    return treffer if len(b) <= len(a) + 2 else treffer * 0.5


def stimme_fuer(referenz_b64):
    if not referenz_b64:
        return STANDARD_STIMME
    daten = base64.b64decode(referenz_b64)
    h = hashlib.sha256(daten).hexdigest()
    if h not in STIMMEN:
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(daten)
            f.flush()
            MODELL.prepare_conditionals(f.name, exaggeration=AUSDRUCK)
        STIMMEN[h] = MODELL.conds
        if len(STIMMEN) > 50:
            STIMMEN.pop(next(iter(STIMMEN)))
    return STIMMEN[h]


def sprich(text, referenz_b64, pruefen=True):
    with SPERRE:
        MODELL.conds = stimme_fuer(referenz_b64)
        bestes, beste_note, erkannt = None, -1.0, ""
        for versuch in range(1, MAX_VERSUCHE + 1):
            wav = MODELL.generate(text, language_id="de", exaggeration=AUSDRUCK, cfg_weight=0.5)
            if not pruefen:
                return wav, versuch, ""
            w16 = torchaudio.functional.resample(wav, MODELL.sr, 16000)[0].cpu().numpy()
            segmente, _ = PRUEFER.transcribe(w16, language="de")
            ist = " ".join(s.text.strip() for s in segmente)
            note = bewertung(text, ist)
            if note > beste_note:
                bestes, beste_note, erkannt = wav, note, ist
            if note >= 0.8:
                break
        return bestes, versuch, erkannt


def als_wav(tensor, rate):
    pcm = (tensor[0].cpu().numpy().clip(-1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/info":
            return self._json(200, {"bereit": True, "geraet": GERAET})
        self._json(404, {"fehler": "unbekannt"})

    def do_POST(self):
        if self.path != "/synthesize":
            return self._json(404, {"fehler": "unbekannt"})
        try:
            laenge = int(self.headers.get("Content-Length", "0"))
            anfrage = json.loads(self.rfile.read(laenge))
            text = str(anfrage.get("text", "")).strip()[:400]
            if not text:
                return self._json(400, {"fehler": "text fehlt"})
            t0 = time.time()
            wav, versuche, erkannt = sprich(text, anfrage.get("referenz"), anfrage.get("pruefen", True))
            daten = als_wav(wav, MODELL.sr)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(daten)))
            self.send_header("X-Versuche", str(versuche))
            self.send_header("X-Erkannt", base64.b64encode(erkannt.encode()).decode())
            self.send_header("X-Dauer-Ms", str(int((time.time() - t0) * 1000)))
            self.end_headers()
            self.wfile.write(daten)
        except Exception as e:  # noqa: BLE001 – Fehler als JSON melden, Dienst läuft weiter
            self._json(500, {"fehler": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
