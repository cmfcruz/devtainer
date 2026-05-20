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
ARG PIP_VERSION=26.1.1
ARG PRE_COMMIT_VERSION=4.6.0
ARG SAFE_CHAIN_VERSION=1.5.3
ARG YQ_VERSION=v4.53.2
ARG ACTIONLINT_VERSION=1.7.12
ARG KUBECTL_VERSION=v1.36.0
ARG USER_UID=1000
ARG USER_GID=1000

ENV HOME=/home/${USERNAME}
ENV NVM_DIR=${HOME}/.nvm
ENV PYENV_ROOT=${HOME}/.pyenv
ENV SHELL=/bin/bash

# Base tools:
# - ca-certificates/curl/git: needed for nvm/npm/codex/dev workflows
# - bash: explicit shell
# - build-essential/pkg-config: useful for native npm packages/dev builds
# - lib*/xz-utils/tk-dev: CPython build dependencies for pyenv
# - ripgrep/fd-find/neovim/shellcheck/yamllint: useful inside the container
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
        tmux \
        xz-utils \
        yamllint \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install CLI tools from pinned upstream releases, verifying each
# downloaded artifact against the release checksum files.
# Checksum verification intentionally uses scoped `cd /tmp` subshells.
# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) yq_arch="linux_amd64"; actionlint_arch="linux_amd64"; kubectl_arch="amd64" ;; \
        arm64) yq_arch="linux_arm64"; actionlint_arch="linux_arm64"; kubectl_arch="arm64" ;; \
        *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${yq_arch}"; \
    curl -fsSLo /tmp/yq-checksums "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums"; \
    awk -v name="yq_${yq_arch}" '$1 == name { print $19 "  yq" }' /tmp/yq-checksums > /tmp/yq.sha256; \
    test -s /tmp/yq.sha256; \
    (cd /tmp && sha256sum -c yq.sha256); \
    install -m 0755 /tmp/yq /usr/local/bin/yq; \
    actionlint_tag="v${ACTIONLINT_VERSION}"; \
    actionlint_archive="actionlint_${ACTIONLINT_VERSION}_${actionlint_arch}.tar.gz"; \
    curl -fsSLo "/tmp/${actionlint_archive}" "https://github.com/rhysd/actionlint/releases/download/${actionlint_tag}/${actionlint_archive}"; \
    curl -fsSLo /tmp/actionlint-checksums "https://github.com/rhysd/actionlint/releases/download/${actionlint_tag}/actionlint_${ACTIONLINT_VERSION}_checksums.txt"; \
    grep "  ${actionlint_archive}$" /tmp/actionlint-checksums > /tmp/actionlint.sha256; \
    test -s /tmp/actionlint.sha256; \
    (cd /tmp && sha256sum -c actionlint.sha256); \
    tar -xzf "/tmp/${actionlint_archive}" -C /tmp actionlint; \
    install -m 0755 /tmp/actionlint /usr/local/bin/actionlint; \
    curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl"; \
    curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl.sha256"; \
    (cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -); \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    rm -f /tmp/yq /tmp/yq-checksums /tmp/yq.sha256 "/tmp/${actionlint_archive}" /tmp/actionlint-checksums /tmp/actionlint.sha256 /tmp/actionlint /tmp/kubectl /tmp/kubectl.sha256; \
    yq --version; \
    yamllint --version; \
    actionlint -version; \
    kubectl version --client=true

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
RUN <<'EOF'
set -euo pipefail
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/install-nvm.sh
PROFILE=/dev/null bash /tmp/install-nvm.sh
rm -f /tmp/install-nvm.sh
set +u
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"
nvm install "${NODE_VERSION}"
nvm alias default "${NODE_VERSION}"
nvm use default
set -u
npm config set fund false
npm config set audit false
curl -fsSL "https://github.com/AikidoSec/safe-chain/releases/download/${SAFE_CHAIN_VERSION}/install-safe-chain.sh" -o /tmp/install-safe-chain.sh
sh /tmp/install-safe-chain.sh --ci --install-dir "${HOME}/.safe-chain"
rm -f /tmp/install-safe-chain.sh
export PATH="${HOME}/.safe-chain/shims:${HOME}/.safe-chain/bin:${PATH}"
hash -r
safe-chain --version
npm safe-chain-verify
npm install -g "@openai/codex"
npm cache clean --force
mkdir -p "${HOME}/.local/bin"
CODEX_REAL_BIN="$(command -v codex)"
cat > "${HOME}/.local/bin/codex" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
exec "${CODEX_REAL_BIN}" --sandbox=danger-full-access --ask-for-approval=on-request "\$@"
SCRIPT
chmod +x "${HOME}/.local/bin/codex"
"${HOME}/.local/bin/codex" --version
EOF

# Install pyenv from a pinned release and verified commit, then install Python
# and pre-commit with that pyenv-managed interpreter.
RUN <<'EOF'
set -euo pipefail
git clone --depth 1 --branch "${PYENV_RELEASE}" https://github.com/pyenv/pyenv.git "${PYENV_ROOT}"
test "$(git -C "${PYENV_ROOT}" rev-parse HEAD)" = "${PYENV_COMMIT_SHA}"
export PATH="${HOME}/.safe-chain/shims:${HOME}/.safe-chain/bin:${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
pyenv install "${PYTHON_VERSION}"
pyenv global "${PYTHON_VERSION}"
pyenv rehash
pip install --no-cache-dir "pip==${PIP_VERSION}"
pyenv rehash
pip install --no-cache-dir "pre-commit==${PRE_COMMIT_VERSION}"
pyenv rehash
pip --version
python --version
pre-commit --version
EOF

ENV PATH=${HOME}/.safe-chain/shims:${HOME}/.safe-chain/bin:${HOME}/.local/bin:${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}

# Make nvm/node/codex and pyenv/python available to both CMD commands and
# interactive shells. Safe Chain is prepended after nvm/pyenv initialization so
# package manager commands resolve through its shims.
RUN <<'EOF'
set -euo pipefail
cat > "${HOME}/.devtainer-env" <<'SCRIPT'
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh" --no-use
  nvm use --silent default >/dev/null
fi

export PYENV_ROOT="$HOME/.pyenv"
if [[ -d "$PYENV_ROOT/bin" ]]; then
  export PATH="$PYENV_ROOT/bin:$PATH"
fi
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init - bash)"
fi

export PATH="$HOME/.safe-chain/shims:$HOME/.safe-chain/bin:$HOME/.local/bin:$PATH"
export GPG_TTY="$(tty 2>/dev/null || true)"
export DEVTAINER_ENV_LOADED=1
SCRIPT
cat >> "${HOME}/.bashrc" <<'SCRIPT'
if [[ "${DEVTAINER_ENV_LOADED:-}" != "1" && -f "$HOME/.devtainer-env" ]]; then
  # shellcheck source=/dev/null
  . "$HOME/.devtainer-env"
fi
if [[ -n "${NVM_DIR:-}" && -s "$NVM_DIR/bash_completion" ]]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/bash_completion"
fi
SCRIPT
mkdir -p "${HOME}/.gnupg"
chmod 700 "${HOME}/.gnupg"
EOF

RUN <<'EOF'
set -euo pipefail
cat > "${HOME}/.local/bin/devtainer-entrypoint" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 0 ]]; then
  set -- bash
fi
if [[ -f "$HOME/.devtainer-env" ]]; then
  set +u
  # shellcheck source=/dev/null
  . "$HOME/.devtainer-env"
  set -u
fi
exec "$@"
SCRIPT
chmod +x "${HOME}/.local/bin/devtainer-entrypoint"
EOF

WORKDIR /workspace

ENTRYPOINT ["devtainer-entrypoint"]
CMD ["bash"]
