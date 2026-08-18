# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build dependencies in an isolated layer so the final image never
# carries compiler toolchains or pip's cache.
# ---------------------------------------------------------------------------
FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65 AS builder

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir --user -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image.
# ---------------------------------------------------------------------------
FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65 AS runtime

LABEL org.opencontainers.image.title="hepapi-case-study" \
      org.opencontainers.image.description="Containerized task manager used for the Hepapi DevOps case study"

# curl is required for the container HEALTHCHECK below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 service \
    && useradd --uid 1000 --gid service --shell /usr/sbin/nologin --create-home service

WORKDIR /srv/service

COPY --from=builder /root/.local /home/service/.local
COPY --chown=service:service run.py classes.py ./
COPY --chown=service:service templates ./templates
COPY --chown=service:service docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

ENV PATH=/home/service/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER service

EXPOSE 5000

# curl -f already exits non-zero on an HTTP error, so no shell is needed here.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=5 \
    CMD ["curl", "-fsS", "http://localhost:5000/"]

ENTRYPOINT ["entrypoint.sh"]
CMD ["python", "run.py"]
