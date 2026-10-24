FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/data

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install ".[embed]" \
    && useradd --uid 10001 --home-dir /data --no-create-home kb \
    && mkdir /data && chown kb /data

# The clone of the notes, the index and the embedding model all live on the volume.
USER kb
VOLUME /data
EXPOSE 8800

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8800/health')"

CMD ["kb", "serve", "--host", "0.0.0.0", "--port", "8800", "--repo-dir", "/data/.claude-sync"]
