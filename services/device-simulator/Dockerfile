# Stages: deps -> test (ruff + pytest, used by `make test` and CI) ; deps -> runtime (shipped image)
ARG PYTHON_IMAGE=python:3.12.16-slim-trixie

FROM ${PYTHON_IMAGE} AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

FROM base AS deps
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM deps AS test
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY pyproject.toml .
COPY src ./src
COPY tests ./tests
RUN ruff check src tests && ruff format --check src tests && pytest -q

FROM base AS runtime
LABEL org.opencontainers.image.source="https://github.com/andrea-claro/integration-platform-lab" \
      org.opencontainers.image.description="device-simulator: virtual sensors publishing telemetry over MQTT" \
      org.opencontainers.image.licenses="MIT"
COPY --from=deps /opt/venv /opt/venv
COPY src ./src
# The build context may carry restrictive host permissions (umask 077): make the code
# world-readable (root-owned, not writable by the app user).
RUN chmod -R a+rX /app/src
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src
# Fixed numeric uid so Kubernetes can verify runAsNonRoot; nothing is written at runtime,
# so the image works with readOnlyRootFilesystem.
USER 10001:10001
# Fail the build, not the container, if the runtime user cannot import the app.
RUN python -c "import device_simulator.main"
EXPOSE 8080
ENTRYPOINT ["python", "-m", "device_simulator"]
