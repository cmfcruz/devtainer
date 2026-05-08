# syntax=docker/dockerfile:1

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=dev

# Pin these deliberately. Update after reviewing upstream releases.
ARG NVM_VERSION=v0.40.3
ARG NODE_VERSION=24
ARG PYENV_RELEASE=v2.6.28
ARG PYENV_COMMIT_SHA=485090e7131630b191305316571c06e4ecac3a35
ARG PYTHON_VERSION=3.12.13
ARG PRE_COMMIT_VERSION=4.6.0
ARG USER_UID=1000
ARG USER_GID=1000

ENV HOME=/home/${USERNAME}
ENV NVM_DIR=${HOME}/.nvm
ENV NODE_VERSION=${NODE_VERSION}
ENV PYENV_ROOT=${HOME}/.pyenv
ENV PYTHON_VERSION=${PYTHON_VERSION}
ENV PATH=${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${HOME}/.local/bin:${PATH}
ENV SHELL=/bin/bash

# Base tools:
# - ca-certificates/curl/git: needed for nvm/npm/codex/dev workflows
# - bash: explicit shell
# - build-essential/pkg-config: useful for native npm packages/dev builds
# - lib*/xz-utils/tk-dev: CPython build dependencies for pyenv
# - ripgrep/fd-find/neovim: useful inside the container
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        gnupg \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libncursesw5-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        libxmlsec1-dev \
        neovim \
        pkg-config \
        ripgrep \
        shellcheck \
        tk-dev \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Rename Ubuntu's default non-root user used for bind-mounted workspace files.
RUN groupmod --new-name "${USERNAME}" ubuntu \
    && groupmod --gid "${USER_GID}" "${USERNAME}" \
    && usermod --login "${USERNAME}" --uid "${USER_UID}" --gid "${USER_GID}" --home "/home/${USERNAME}" --move-home --shell /bin/bash ubuntu \
    && chown -R "${USER_UID}:${USER_GID}" "/home/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install nvm, Node, and Codex as the non-root user.
#
# Notes:
# - This avoids sudo npm/global package writes.
# - We install Node 24 LTS-style rather than "node" latest.
# - We disable npm fund/audit noise in container builds.
RUN curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/install-nvm.sh \
    && bash /tmp/install-nvm.sh \
    && . "${NVM_DIR}/nvm.sh" \
    && nvm install ${NODE_VERSION} \
    && nvm alias default ${NODE_VERSION} \
    && nvm use default \
    && npm config set fund false \
    && npm config set audit false \
    && npm install -g "@openai/codex" \
    && npm cache clean --force \
    && mkdir -p "${HOME}/.local/bin" \
    && CODEX_REAL_BIN="$(command -v codex)" \
    && printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'exec "'"${CODEX_REAL_BIN}"'" --sandbox=danger-full-access --ask-for-approval=on-request "$@"' \
        > "${HOME}/.local/bin/codex" \
    && chmod +x "${HOME}/.local/bin/codex" \
    && codex --version

# Install pyenv from a pinned release and verified commit, then install Python
# and pre-commit with that pyenv-managed interpreter.
RUN git clone --depth 1 --branch "${PYENV_RELEASE}" https://github.com/pyenv/pyenv.git "${PYENV_ROOT}" \
    && test "$(git -C "${PYENV_ROOT}" rev-parse HEAD)" = "${PYENV_COMMIT_SHA}" \
    && pyenv install "${PYTHON_VERSION}" \
    && pyenv global "${PYTHON_VERSION}" \
    && pyenv exec python -m pip install --upgrade pip \
    && pyenv exec python -m pip install "pre-commit==${PRE_COMMIT_VERSION}" \
    && pyenv rehash \
    && python --version \
    && pre-commit --version

# Make nvm/node/codex and pyenv/python available in interactive shells.
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use' >> ~/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"' >> ~/.bashrc \
    && echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc \
    && echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc \
    && echo 'eval "$(pyenv init - bash)"' >> ~/.bashrc \
    && echo 'export GPG_TTY="$(tty 2>/dev/null || true)"' >> ~/.bashrc \
    && mkdir -p ~/.gnupg \
    && chmod 700 ~/.gnupg

WORKDIR /workspace

CMD ["bash"]
