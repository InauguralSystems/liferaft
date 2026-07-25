# Self-contained dev/CI image for liferaft.
#
# liferaft is a *consumer* of EigenScript: it runs .eigs programs against the
# runtime. This image builds EigenScript at a pinned tag and puts it on PATH,
# so the image is fully reproducible and the tag below IS the version pin —
# bump EIGS_REF to move the runtime under the suite.
#
# The same image backs Codespaces AND CI (.github/workflows/tests.yml runs the
# suite inside it via devcontainers/ci), so "green in my Codespace" and "green
# in CI" can't drift. Building from source (rather than FROM a published
# runtime image) keeps this working for a private repo with no cross-repo
# package-pull credentials.
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
 && rm -rf /var/lib/apt/lists/*

# Build + install EigenScript at the pinned tag onto /usr/local (binary on
# PATH, stdlib at /usr/local/lib/eigenscript — found relative to the binary).
ARG EIGS_REF=v0.32.0
RUN git clone --depth 1 --branch "${EIGS_REF}" \
        https://github.com/InauguralSystems/EigenScript.git /tmp/eigs \
 && make -C /tmp/eigs install PREFIX=/usr/local CC=gcc \
 && rm -rf /tmp/eigs

WORKDIR /workspaces/liferaft
