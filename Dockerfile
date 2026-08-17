FROM python:3.12-slim

# cups-client provides `lp`, which is how attachments are printed. It is a
# client only - no printing daemon runs in this container; it talks to the
# CUPS server named per printer (or to the host's, via CUPS_SERVER).
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    cups-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mail2nas ./mail2nas

RUN useradd --create-home --uid 1000 mail2nas \
    && mkdir -p /mnt/nas /data \
    && chown -R mail2nas:mail2nas /mnt/nas /data
USER mail2nas

ENV PYTHONUNBUFFERED=1
# Only listened on when WEB_ENABLED=true (mapping web UI).
EXPOSE 8080
ENTRYPOINT ["python", "-m", "mail2nas.main"]
