ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:0f5b26b9518d002b6173fd61daad821fa340635ebfec5bba471013f9ca114579

FROM ${PYTHON_IMAGE} AS builder
ARG UV_VERSION=0.9.26
WORKDIR /build/server
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
RUN python -m pip install --no-cache-dir "uv==${UV_VERSION}"
COPY server/pyproject.toml server/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY server/src ./src
RUN uv sync --frozen --no-dev --no-editable

FROM ${PYTHON_IMAGE} AS runtime
ARG APP_VERSION=dev
ARG COMMIT_SHA=unknown
LABEL org.opencontainers.image.title="MakerSeed Diagnostic Report Generator" \
      org.opencontainers.image.source="https://github.com/liwlin/innovation-diagnostic-report-generator" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${COMMIT_SHA}"
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates fonts-wqy-zenhei \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 makerseed \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin makerseed
WORKDIR /opt/app
COPY --from=builder /build/server/.venv /opt/app/.venv
COPY server/alembic.ini /opt/app/server/alembic.ini
COPY server/alembic /opt/app/server/alembic
COPY index.html support.js doc-page.js "科创方向诊断报告生成器.dc.html" /opt/app/static/
COPY assets /opt/app/static/assets
COPY shared /opt/app/static/shared
COPY vendor /opt/app/static/vendor
COPY nas-web /opt/app/static/nas-web
ENV PATH="/opt/app/.venv/bin:${PATH}" \
    MKSEED_APP_VERSION="${APP_VERSION}" \
    MKSEED_COMMIT_SHA="${COMMIT_SHA}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/opt/app/.venv/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=3).read()"]
CMD ["/opt/app/.venv/bin/python", "-m", "uvicorn", "makerseed_app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--no-access-log"]
