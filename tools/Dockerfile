# Toolbox image for `make lint`: every linter pinned, nothing to install on the Mac.
# Binaries are copied from the tools' official images.
FROM ghcr.io/yannh/kubeconform:v0.8.0 AS kubeconform
FROM registry.k8s.io/kustomize/kustomize:v5.8.3 AS kustomize
FROM ghcr.io/opentofu/opentofu:1.13.9-minimal AS tofu

FROM python:3.12.16-slim-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      yamllint==1.38.0 \
      ruff==0.17.5 \
      shellcheck-py==0.11.0.1

COPY --from=kubeconform /kubeconform /usr/local/bin/kubeconform
COPY --from=kustomize /app/kustomize /usr/local/bin/kustomize
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# The repository is bind-mounted here and may be owned by another uid.
RUN git config --system --add safe.directory /work
ENV HOME=/tmp
WORKDIR /work
