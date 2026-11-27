# Piper-Sprachausgabe (Open Source, MIT/GPL) – läuft nur im internen Netz, nicht öffentlich.
FROM python:3.12-slim
RUN pip install --no-cache-dir "piper-tts[http]==1.8.0"
WORKDIR /voices
# Deutsche Stimmen beim Bauen laden (einmalig, ca. 110 MB je Stimme in hoher Qualität)
RUN python3 -m piper.download_voices --data-dir /voices de_DE-thorsten-high de_DE-kerstin-low de_DE-ramona-low
EXPOSE 5000
USER nobody
CMD ["python3", "-m", "piper.http_server", "--host", "0.0.0.0", "--port", "5000", "--data-dir", "/voices", "-m", "de_DE-thorsten-high"]
