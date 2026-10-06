FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml uv.lock README.md ./
COPY src ./src

RUN uv sync --frozen --no-dev

ENV PATH="/app/.venv/bin:${PATH}"
ENV PORT=8080
ENV GUARDIAN_UVICORN_APP="guardianbackend.api.app:app"

CMD ["sh", "-c", "uvicorn --app-dir src ${GUARDIAN_UVICORN_APP} --host 0.0.0.0 --port 8080"]
