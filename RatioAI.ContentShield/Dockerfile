FROM mcr.microsoft.com/mirror/docker/library/python:3.11-slim

LABEL org.opencontainers.image.title="contentshield" \
      org.opencontainers.image.version="1.0.2" \
      org.opencontainers.image.description="ContentShield orchestrator with opt-in latency metrics via X-Include-Latency header; CVE-patched build" \
      com.ratioai.build.variant="latency-enabled" \
      com.ratioai.feature.latency_header="X-Include-Latency" \
      com.ratioai.contract.compat="contentshield:1.0.1"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

# Patch the base image's build tooling (python:3.11-slim ships vulnerable
# pip 24.0 and a setuptools that vendors an old wheel / jaraco.context) and
# install a patched uv for the build. Without this the published image is
# flagged even though these packages are only used at build time.
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir uv==0.9.6
COPY pyproject.toml uv.lock README.md ./
COPY src ./src

# Build the runtime venv, then drop build-only tooling (uv) and the uv cache
# so none of it lingers in the final image for the scanner to flag.
RUN uv sync --frozen --no-dev \
    && pip uninstall -y uv \
    && rm -rf /root/.cache /tmp/*

ENV PATH="/app/.venv/bin:$PATH"

# Drop root: run the service as an unprivileged user.
RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin app \
    && chown -R app:app /app
USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).read()"

CMD ["uvicorn", "contentshield.app:app", "--host", "0.0.0.0", "--port", "8080"]