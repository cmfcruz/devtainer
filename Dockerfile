# syntax=docker/dockerfile:1

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=dev

# Pin these deliberately. Update after reviewing upstream releases.
ARG NVM_VERSION=v0.40.3
ARG NODE_VERSION=24.16.0
ARG CODEX_VERSION=0.145.0
ARG CLAUDE_CODE_VERSION=2.1.318
ARG PYENV_RELEASE=v2.6.28
ARG PYENV_COMMIT_SHA=485090e7131630b191305316571c06e4ecac3a35
ARG PYTHON_VERSION=3.12.13
ARG PIP_VERSION=26.1.1
ARG PRE_COMMIT_VERSION=4.6.0
ARG SAFE_CHAIN_VERSION=1.5.3
ARG YQ_VERSION=v4.53.2
ARG ACTIONLINT_VERSION=1.7.12
ARG STYLUA_VERSION=2.5.2
ARG KUBECTL_VERSION=v1.36.0
ARG HELM_VERSION=v4.2.0
ARG HELM_SIGNING_KEY_FINGERPRINT=BF888333D96A1C18E2682AAED79D67C9EC016739
ARG BUOY_VERSION=v3.0.0
ARG USER_UID=1000
ARG USER_GID=1000

ENV HOME=/home/${USERNAME}
ENV NVM_DIR=${HOME}/.nvm
ENV PYENV_ROOT=${HOME}/.pyenv
ENV SHELL=/bin/bash
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8

# Base tools:
# - ca-certificates/curl/git: needed for nvm/npm/binary CLI/dev workflows
# - bash: explicit shell
# - build-essential/pkg-config: useful for native npm packages/dev builds
# - lib*/xz-utils/tk-dev: CPython build dependencies for pyenv
# - ripgrep/fd-find/neovim/shellcheck/jq/yamllint: useful inside the container
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        gh \
        git \
        gnupg \
        jq \
        less \
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
        unzip \
        wl-clipboard \
        xz-utils \
        yamllint \
        zlib1g-dev \
    && test "$(locale charmap)" = "UTF-8" \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install CLI tools from pinned upstream releases, verifying each
# downloaded artifact against the release checksum files.
# Checksum verification intentionally uses scoped `cd /tmp` subshells.
# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) yq_arch="linux_amd64"; actionlint_arch="linux_amd64"; kubectl_arch="amd64"; helm_arch="amd64"; stylua_arch="linux-x86_64" ;; \
        arm64) yq_arch="linux_arm64"; actionlint_arch="linux_arm64"; kubectl_arch="arm64"; helm_arch="arm64"; stylua_arch="linux-aarch64" ;; \
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
    helm_archive="helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz"; \
    curl -fsSLo "/tmp/${helm_archive}" "https://get.helm.sh/${helm_archive}"; \
    curl -fsSLo "/tmp/${helm_archive}.sha256sum" "https://get.helm.sh/${helm_archive}.sha256sum"; \
    curl -fsSLo "/tmp/${helm_archive}.asc" "https://github.com/helm/helm/releases/download/${HELM_VERSION}/${helm_archive}.asc"; \
    curl -fsSLo /tmp/helm-keys "https://raw.githubusercontent.com/helm/helm/main/KEYS"; \
    mkdir -m 0700 /tmp/helm-gnupg; \
    gpg --batch --homedir /tmp/helm-gnupg --import /tmp/helm-keys; \
    gpg --batch --homedir /tmp/helm-gnupg --fingerprint "${HELM_SIGNING_KEY_FINGERPRINT}"; \
    (cd /tmp && sha256sum -c "${helm_archive}.sha256sum"); \
    gpg --batch --homedir /tmp/helm-gnupg --verify "/tmp/${helm_archive}.asc" "/tmp/${helm_archive}"; \
    tar -xzf "/tmp/${helm_archive}" -C /tmp "linux-${helm_arch}/helm"; \
    install -m 0755 "/tmp/linux-${helm_arch}/helm" /usr/local/bin/helm; \
    stylua_archive="stylua-${stylua_arch}.zip"; \
    curl -fsSLo "/tmp/${stylua_archive}" "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/${stylua_archive}"; \
    stylua_digest="$(curl -fsSL "https://api.github.com/repos/JohnnyMorganz/StyLua/releases/tags/v${STYLUA_VERSION}" | jq -r --arg name "${stylua_archive}" '.assets[] | select(.name == $name) | .digest')"; \
    stylua_sha256="${stylua_digest#sha256:}"; \
    test "${stylua_sha256}" != "${stylua_digest}"; \
    [[ "${stylua_sha256}" =~ ^[a-f0-9]{64}$ ]]; \
    echo "${stylua_sha256}  /tmp/${stylua_archive}" | sha256sum -c -; \
    unzip -o -d /tmp "/tmp/${stylua_archive}" stylua; \
    install -m 0755 /tmp/stylua /usr/local/bin/stylua; \
    rm -rf /tmp/yq /tmp/yq-checksums /tmp/yq.sha256 "/tmp/${actionlint_archive}" /tmp/actionlint-checksums /tmp/actionlint.sha256 /tmp/actionlint /tmp/kubectl /tmp/kubectl.sha256 "/tmp/${helm_archive}" "/tmp/${helm_archive}.sha256sum" "/tmp/${helm_archive}.asc" /tmp/helm-keys /tmp/helm-gnupg "/tmp/linux-${helm_arch}" "/tmp/${stylua_archive}" /tmp/stylua; \
    yq --version; \
    yamllint --version; \
    actionlint -version; \
    kubectl version --client=true; \
    helm version --short; \
    stylua --version

# Rename Ubuntu's default non-root user used for bind-mounted workspace files.
RUN groupmod --new-name "${USERNAME}" ubuntu \
    && groupmod --gid "${USER_GID}" "${USERNAME}" \
    && usermod --login "${USERNAME}" --uid "${USER_UID}" --gid "${USER_GID}" --home "/home/${USERNAME}" --move-home --shell /bin/bash ubuntu \
    && chown -R "${USER_UID}:${USER_GID}" "/home/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install nvm, Node, Codex, and Claude Code as the non-root user.
#
# Notes:
# - This avoids sudo/global package writes.
# - We install a pinned Node 24 LTS release rather than "node" latest.
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
case "$(dpkg --print-architecture)" in
    amd64)
        codex_arch="x86_64-unknown-linux-musl"
        claude_platform="linux-x64"
        ;;
    arm64)
        codex_arch="aarch64-unknown-linux-musl"
        claude_platform="linux-arm64"
        ;;
    *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share"
codex_archive="codex-package-${codex_arch}.tar.gz"
codex_url="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${codex_archive}"
curl -fsSLo "/tmp/${codex_archive}" "${codex_url}"
codex_digest="$(curl -fsSL "https://api.github.com/repos/openai/codex/releases/tags/rust-v${CODEX_VERSION}" | jq -r --arg name "${codex_archive}" '.assets[] | select(.name == $name) | .digest')"
codex_sha256="${codex_digest#sha256:}"
test "${codex_sha256}" != "${codex_digest}"
[[ "${codex_sha256}" =~ ^[a-f0-9]{64}$ ]]
echo "${codex_sha256}  /tmp/${codex_archive}" | sha256sum -c -
rm -rf "${HOME}/.local/share/codex"
mkdir -p "${HOME}/.local/share/codex"
tar -xzf "/tmp/${codex_archive}" -C "${HOME}/.local/share/codex"
rm -f "/tmp/${codex_archive}"
CODEX_REAL_BIN="${HOME}/.local/share/codex/bin/codex"
test -x "${CODEX_REAL_BIN}"
cat > "${HOME}/.local/bin/codex" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
exec "${CODEX_REAL_BIN}" --sandbox=danger-full-access --ask-for-approval=on-request "\$@"
SCRIPT
chmod +x "${HOME}/.local/bin/codex"
claude_manifest="$(curl -fsSL "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/manifest.json")"
claude_sha256="$(jq -r --arg platform "${claude_platform}" '.platforms[$platform].checksum // empty' <<<"${claude_manifest}")"
[[ "${claude_sha256}" =~ ^[a-f0-9]{64}$ ]]
curl -fsSLo "${HOME}/.local/bin/claude" "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/${claude_platform}/claude"
mkdir -p "${HOME}/.local/share/claude"
CLAUDE_REAL_BIN="${HOME}/.local/share/claude/claude"
mv "${HOME}/.local/bin/claude" "${CLAUDE_REAL_BIN}"
echo "${claude_sha256}  ${CLAUDE_REAL_BIN}" | sha256sum -c -
chmod +x "${CLAUDE_REAL_BIN}"
cat > "${HOME}/.local/bin/claude" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
exec "${CLAUDE_REAL_BIN}" --permission-mode=auto "\$@"
SCRIPT
chmod +x "${HOME}/.local/bin/claude"
"${HOME}/.local/bin/codex" --version
"${HOME}/.local/bin/claude" --version
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

ENV NODE_BIN=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin
ENV PATH=${HOME}/.safe-chain/shims:${HOME}/.safe-chain/bin:${HOME}/.local/bin:${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${NODE_BIN}:${PATH}

# Make nvm/node/codex/claude and pyenv/python available to both CMD commands and
# interactive shells. Safe Chain is prepended after nvm/pyenv initialization so
# package manager commands resolve through its shims.
RUN <<'EOF'
set -euo pipefail
cat > "${HOME}/.devtainer-env" <<'SCRIPT'
export LANG="${LANG:-C.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-C.UTF-8}"

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

export PATH="$HOME/.safe-chain/shims:$HOME/.safe-chain/bin:$HOME/.local/bin:$NODE_BIN:$PATH"
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
cat > "${HOME}/.tmux.conf" <<'SCRIPT'
# Enable extended-keys to allow shift+enter in Codex
set -s extended-keys on
set -as terminal-features ',xterm-ghostty:extkeys'
set -as terminal-features ',xterm:extkeys'

# Use Vim keys in copy/scroll mode
setw -g mode-keys vi
set -g mouse on
set -g history-limit 50000

# Split panes with easier bindings
bind | split-window -h
bind - split-window -v

# Move between panes with Vim keys
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize panes with Vim keys
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# Prompt before killing all tmux sessions
bind b confirm-before -p "Kill tmux server? (y/n)" kill-server
SCRIPT

mkdir -p "${HOME}/.config/nvim"
cat > "${HOME}/.config/nvim/init.lua" <<'SCRIPT'
vim.opt.autoread = true
vim.opt.clipboard = "unnamedplus"
vim.opt.encoding = "utf-8"

-- When the launcher mounts the host Wayland socket (dev/devil set
-- WAYLAND_DISPLAY), let Neovim's default provider use wl-copy/wl-paste so
-- yanks land directly in the host clipboard. Otherwise fall back to OSC 52
-- escape sequences, which require a terminal emulator that supports them.
local has_wayland = vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1
if not has_wayland then
  local ok_osc52, osc52 = pcall(require, "vim.ui.clipboard.osc52")
  if ok_osc52 then
    vim.g.clipboard = {
      name = "OSC 52",
      copy = {
        ["+"] = osc52.copy("+"),
        ["*"] = osc52.copy("*"),
      },
      paste = {
        ["+"] = osc52.paste("+"),
        ["*"] = osc52.paste("*"),
      },
    }
  end
end

vim.opt.fileencoding = "utf-8"
vim.opt.fileencodings = { "ucs-bom", "utf-8", "default", "latin1" }
vim.opt.mouse = "a"
vim.opt.number = true
vim.opt.relativenumber = true

vim.api.nvim_create_autocmd(
  { "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" },
  { command = "checktime" }
)
SCRIPT
EOF

USER root

RUN <<'EOF'
set -euo pipefail
mkdir -p /usr/local/lib/devtainer
install -m 0755 "${HOME}/.local/share/codex/bin/codex" /usr/local/lib/devtainer/codex
cat > /usr/local/bin/codex <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/lib/devtainer/codex --sandbox=danger-full-access --ask-for-approval=on-request "$@"
SCRIPT
chmod +x /usr/local/bin/codex

install -m 0755 "${HOME}/.local/share/claude/claude" /usr/local/lib/devtainer/claude
cat > /usr/local/bin/claude <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/lib/devtainer/claude --permission-mode=auto "$@"
SCRIPT
chmod +x /usr/local/bin/claude

cat > /usr/local/bin/devtainer-entrypoint <<'SCRIPT'
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
# Use the mounted gh login even when a persistent home exports stale tokens.
unset GH_TOKEN GITHUB_TOKEN
export GH_CONFIG_DIR="$HOME/.config/gh"
if [[ "${DEVIL_MODE:-}" == "true" ]]; then
  export PATH="/usr/local/bin:$PATH"
  nvim_plugin_dir="$HOME/.config/nvim/plugin"
  nvim_utf8_plugin="$nvim_plugin_dir/devtainer-utf8.lua"
  mkdir -p "$nvim_plugin_dir"
  if [[ ! -f "$nvim_utf8_plugin" ]] || grep -Fq "Managed by devtainer." "$nvim_utf8_plugin"; then
    cat > "$nvim_utf8_plugin" <<'LUA'
-- Managed by devtainer.
vim.opt.encoding = "utf-8"
vim.opt.fileencoding = "utf-8"
vim.opt.fileencodings = { "ucs-bom", "utf-8", "default", "latin1" }
LUA
  fi
fi
# buoy.nvim injects its own editor-context guidance when it launches the
# agent (Claude Code via --append-system-prompt, Codex via app-server
# developer instructions), so devtainer no longer seeds a Codex AGENTS.md.
# Remove a stale copy from older images — but only the one we managed, so a
# user's own AGENTS.md is never touched.
codex_agents="${CODEX_HOME:-$HOME/.codex}/AGENTS.md"
if [[ -f "$codex_agents" ]] && grep -Fq "Managed by devtainer." "$codex_agents"; then
  rm -f "$codex_agents"
fi
exec "$@"
SCRIPT
chmod +x /usr/local/bin/devtainer-entrypoint
EOF

# Install buoy.nvim from GitHub so Neovim auto-loads it in every devtainer mode.
# It lives in the system site dir (not under $HOME), so the read-only host
# ~/.config/nvim and ~/.local/share/nvim mounts used by `dev` never shadow it.
RUN git clone --depth 1 --branch "${BUOY_VERSION}" https://github.com/cmfcruz/buoy.nvim \
    /usr/local/share/nvim/site/pack/devtainer/start/buoy.nvim

RUN <<'EOF'
set -euo pipefail
# Auto-initialize the bundled plugin (publishes the RPC socket + context
# autocmds, registers :Buoy) via a tiny sibling "start" package, so
# setup() runs in all modes regardless of the user's mounted init.lua.
setup_dir=/usr/local/share/nvim/site/pack/devtainer/start/devtainer-buoy/plugin
mkdir -p "${setup_dir}"
cat > "${setup_dir}/devtainer-buoy.lua" <<'LUA'
-- Managed by devtainer: auto-load the bundled buoy.nvim plugin so the
-- running agent (Codex / Claude Code) gets live editor context through
-- buoy's prompt hook and private agent CLI.
local ok, buoy = pcall(require, "buoy")
if not ok then
  return
end

-- dev defaults its agent to Claude Code; devil sets DEVTAINER_AGENT=codex
-- in its launcher. Set DEVTAINER_AGENT explicitly to override either.
local agent = vim.env.DEVTAINER_AGENT == "codex" and "codex" or "claude"
buoy.setup({ agent = agent })
LUA
EOF

USER ${USERNAME}
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/devtainer-entrypoint"]
CMD ["bash"]
