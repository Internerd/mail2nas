FROM python:3.12-slim

# cups-client provides `lp`, for printers that are a queue on a CUPS server.
# It is a client only - no printing daemon runs in this container.
# ghostscript renders documents for printers addressed directly over IPP
# (ipp://...) that do not take PDF: PWG raster / URF, see render.py.
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    cups-client \
    ghostscript \
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
# The web UI - where everything is configured.
EXPOSE 8080
ENTRYPOINT ["python", "-m", "mail2nas.main"]
