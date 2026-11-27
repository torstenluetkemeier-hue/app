# Stimmdienst (Chatterbox + Whisper) – nur im internen Netz.
# Für schnelle Antworten auf einem Server mit NVIDIA-GPU betreiben (z. B. GPU-Server in einem deutschen Rechenzentrum).
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime
RUN pip install --no-cache-dir "chatterbox-tts==0.1.7" "faster-whisper==1.2.1"
WORKDIR /app
COPY server.py .
# Modelle beim Bauen laden, damit der Dienst ohne Internetzugang startet
RUN python3 -c "from chatterbox.mtl_tts import ChatterboxMultilingualTTS as M; M.from_pretrained(device='cpu')" \
 && python3 -c "from faster_whisper import WhisperModel as W; W('small', device='cpu', compute_type='int8')"
EXPOSE 5000
CMD ["python3", "server.py"]
