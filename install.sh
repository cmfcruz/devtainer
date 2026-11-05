#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-devtainer:26.04}"

build_flags=()

usage() {
  cat << EOF
Usage: ${0##*/} [--no-cache]

  --no-cache   Build the image without using Docker's layer cache. Use this to
               force a fresh \`git clone\` of pinned dependencies (e.g. buoy.nvim)
               when the pinned branch has moved but the ref name is unchanged.
  -h, --help   Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)
      build_flags+=(--no-cache)
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

USERNAME="$(id -un)"
USER_UID="$(id -u)"
USER_GID="$(id -g)"

echo "Building ${IMAGE_NAME} using USERNAME=${USERNAME}, USER_UID=${USER_UID}, USER_GID=${USER_GID}"

docker build \
  ${build_flags[@]+"${build_flags[@]}"} \
  --build-arg USERNAME="${USERNAME}" \
  --build-arg USER_UID="${USER_UID}" \
  --build-arg USER_GID="${USER_GID}" \
  -f Dockerfile \
  -t "${IMAGE_NAME}" \
  .

BIN_DIR="${HOME}/bin"
DEV_BIN="${BIN_DIR}/dev"
DEVIL_BIN="${BIN_DIR}/devil"
OLD_DEV_SECURE_BIN="${BIN_DIR}/dev-secure"
WORK_DIR="/workspace"
# Single host-side cache root mounted as the container's $HOME/.cache. Mounting
# the cache root itself (rather than individual subdirs under it) keeps the
# directory owned by this user inside the container: Docker creates missing
# bind-mount *parents* as root, which left $HOME/.cache unwritable for tools
# that use the XDG default and are not explicitly redirected below.
CACHE_DIR="${HOME}/.cache/devtainer"

mkdir -p "${BIN_DIR}" "${CACHE_DIR}" "${HOME}/.claude" "${HOME}/.config/nvim" "${HOME}/.local/share/nvim"
touch "${HOME}/.gitconfig"
touch "${HOME}/.gitmessage"
touch "${HOME}/.tmux.conf"
touch "${HOME}/.claude.json"

DEFAULT_COMMAND_SCRIPT=$(
  cat << 'SCRIPT'
if [[ $# -eq 0 ]]; then
  session_name="$(basename "$PWD")"
  # tmux reserves periods and colons in session targets.
  session_name="${session_name//[.:]/_}"
  [[ "$session_name" != / ]] || session_name=workspace
  set -- tmux new-session -A -s "$session_name" -c /workspace
fi
SCRIPT
)

DEVIL_COMMAND_SCRIPT="${DEFAULT_COMMAND_SCRIPT}"

# Prefer the host gh login unless a named devtainer token was requested.
GH_CONFIG_ARGS_SCRIPT=$(
  cat << 'SCRIPT'
host_gh_config="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
if [[ "${github_explicit:-false}" != true && -d "$host_gh_config" ]]; then
  # Clear the implicit default token so it cannot shadow the host login.
  github_args=()
  docker_args+=(
    -v "$host_gh_config:$HOME/.config/gh:ro"
    -e "GH_CONFIG_DIR=$HOME/.config/gh"
  )
fi
SCRIPT
)

# Mount the host Wayland compositor socket so clipboard tools inside the
# container (wl-copy/wl-paste, used by Neovim's clipboard provider) talk to
# the host clipboard. WAYLAND_DISPLAY is set to an absolute path (supported
# by libwayland) so XDG_RUNTIME_DIR stays untouched inside the container.
# Skipped silently when no Wayland session is present.
WAYLAND_ARGS_SCRIPT=$(
  cat << 'SCRIPT'
host_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
host_wayland_socket="${host_runtime_dir}/${WAYLAND_DISPLAY:-}"
if [[ "${WAYLAND_DISPLAY:-}" == /* ]]; then
  host_wayland_socket="${WAYLAND_DISPLAY}"
fi
if [[ -n "${WAYLAND_DISPLAY:-}" && -S "${host_wayland_socket}" ]]; then
  docker_args+=(
    -e WAYLAND_DISPLAY=/run/host-wayland/wayland-0
    -v "${host_wayland_socket}:/run/host-wayland/wayland-0"
  )
fi
SCRIPT
)

# Mount the host GPG agent extra socket and public keyring files so commits and
# tags can be signed inside the container using the host GPG agent. Private key
# files are never mounted; signing runs in the host agent over the extra socket.
# Skipped with a warning when the agent's extra socket is not available.
GPG_ARGS_SCRIPT=$(
  cat << 'SCRIPT'
gpg_dir="$HOME/.gnupg"
container_agent_socket="$gpg_dir/S.gpg-agent"
host_extra_socket="$(gpgconf --list-dirs agent-extra-socket 2>/dev/null || true)"
if [[ -S "$host_extra_socket" ]]; then
  docker_args+=(-v "$host_extra_socket:$container_agent_socket")
else
  printf 'dev: warning: host GPG extra socket not found; signing will not work until the agent is running.\n' >&2
fi

if [[ -f "$gpg_dir/pubring.kbx" ]]; then
  docker_args+=(-v "$gpg_dir/pubring.kbx:$gpg_dir/pubring.kbx:ro")
fi

if [[ -f "$gpg_dir/trustdb.gpg" ]]; then
  docker_args+=(-v "$gpg_dir/trustdb.gpg:$gpg_dir/trustdb.gpg:ro")
fi
SCRIPT
)

echo "Installing ${DEV_BIN}, which starts an interactive Claude Code-capable dev container with the current directory mounted at ${WORK_DIR}, the hostname set to the current directory name, ${HOME}/.claude and ${HOME}/.claude.json mounted into the same home paths inside the container, Git and tmux config plus Neovim config and data mounted read-only, a dedicated host cache root mounted as \$HOME/.cache, and the host GPG agent extra socket and public keyring mounted for code signing when available. Run \`dev\` to open a directory-named tmux session, or append a command like \`dev claude\` to override it."
cat > "${DEV_BIN}" << EOF
#!/usr/bin/env bash
set -euo pipefail

${DEFAULT_COMMAND_SCRIPT}

docker_args=(
  --rm
  -it
  --cap-drop ALL
  --security-opt no-new-privileges
  --hostname "\$(basename "\$PWD")"
  -e TERM=xterm-256color
  -e GPG_TTY=/dev/tty
  -e GNUPGHOME="\$HOME/.gnupg"
  -e PRE_COMMIT_HOME="\$HOME/.cache/pre-commit"
  -e NPM_CONFIG_CACHE="\$HOME/.cache/npm"
  -e PIP_CACHE_DIR="\$HOME/.cache/pip"
  -v "\$PWD:${WORK_DIR}"
  -v "\$HOME/.claude:\$HOME/.claude"
  -v "\$HOME/.claude.json:\$HOME/.claude.json"
  -v "\$HOME/.gitconfig:\$HOME/.gitconfig:ro"
  -v "\$HOME/.gitmessage:\$HOME/.gitmessage:ro"
  -v "\$HOME/.tmux.conf:\$HOME/.tmux.conf:ro"
  -v "\$HOME/.config/nvim:\$HOME/.config/nvim:ro"
  -v "\$HOME/.local/share/nvim:\$HOME/.local/share/nvim:ro"
  -v "${CACHE_DIR}:\$HOME/.cache"
)

${GH_CONFIG_ARGS_SCRIPT}

${WAYLAND_ARGS_SCRIPT}

${GPG_ARGS_SCRIPT}

docker run "\${docker_args[@]}" "${IMAGE_NAME}" "\$@"
EOF

chmod +x "${DEV_BIN}"

echo "Installed dev at ${DEV_BIN}"

echo "Installing ${DEVIL_BIN}, which starts an interactive dev container with Docker volume devil-${USERNAME} mounted as /home for persistent, self-contained container home state. Run \`devil\` to open a directory-named tmux session, or append a command like \`devil codex\` to override it."
cat > "${DEVIL_BIN}" << EOF
#!/usr/bin/env bash
set -euo pipefail

${DEVIL_COMMAND_SCRIPT}

volume_name="devil-${USERNAME}"
docker volume create "\$volume_name" >/dev/null

docker_args=(
  --rm
  -it
  --cap-drop ALL
  --security-opt no-new-privileges
  --hostname "\$(basename "\$PWD")"
  -e TERM=xterm-256color
  -e DEVIL_MODE=true
  -e DEVTAINER_AGENT=codex
  -v "\$volume_name:/home"
  -v "\$PWD:${WORK_DIR}"
)

${GH_CONFIG_ARGS_SCRIPT}

${WAYLAND_ARGS_SCRIPT}

docker run "\${docker_args[@]}" "${IMAGE_NAME}" "\$@"
EOF

chmod +x "${DEVIL_BIN}"

echo "Installed devil at ${DEVIL_BIN}"

if [[ -f "${OLD_DEV_SECURE_BIN}" ]]; then
  if grep -Fq 'PRE_COMMIT_HOME' "${OLD_DEV_SECURE_BIN}" &&
    grep -Fq 'NPM_CONFIG_CACHE' "${OLD_DEV_SECURE_BIN}" &&
    grep -Fq 'docker_args=(' "${OLD_DEV_SECURE_BIN}"; then
    rm -f "${OLD_DEV_SECURE_BIN}"
    echo "Removed old dev-secure launcher at ${OLD_DEV_SECURE_BIN}"
  else
    echo "Found ${OLD_DEV_SECURE_BIN}, but it does not look like a devtainer-generated launcher; leaving it in place."
  fi
fi

BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"
if ! grep -Fxq "export PATH=\"\$HOME/bin:\$PATH\"" "${BASHRC}"; then
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/bin:$PATH"' >> "${BASHRC}"
  echo "Added ${BIN_DIR} to PATH in ${BASHRC}"
fi
