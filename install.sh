#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-devtainer:26.04}"

USERNAME="$(id -un)"
USER_UID="$(id -u)"
USER_GID="$(id -g)"

echo "Building ${IMAGE_NAME} using USERNAME=${USERNAME}, USER_UID=${USER_UID}, USER_GID=${USER_GID}"

docker build \
  --build-arg USERNAME="${USERNAME}" \
  --build-arg USER_UID="${USER_UID}" \
  --build-arg USER_GID="${USER_GID}" \
  -f Dockerfile \
  -t "${IMAGE_NAME}" \
  .

BIN_DIR="${HOME}/bin"
DEV_BIN="${BIN_DIR}/dev"
WORK_DIR="/workspace"
PRE_COMMIT_CACHE_DIR="${HOME}/.cache/devtainer/pre-commit"

mkdir -p "${BIN_DIR}" "${PRE_COMMIT_CACHE_DIR}" "${HOME}/.codex" "${HOME}/.config/nvim"
touch "${HOME}/.gitconfig"
touch "${HOME}/.gitmessage"

echo "Installing ${DEV_BIN}, which starts an interactive dev container with the current directory mounted at ${WORK_DIR}, the hostname set to the current directory name, ${HOME}/.codex mounted into the same home path inside the container, Git and Neovim config mounted read-only, a dedicated pre-commit cache mounted at ${PRE_COMMIT_CACHE_DIR}, and the host GPG agent extra socket mounted as the container GPG agent socket when available. Run \`dev\` to use the image default command, or append a command like \`dev bash\` to override it."
cat > "${DEV_BIN}" << EOF
#!/usr/bin/env bash
set -euo pipefail

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
  -v "\$PWD:${WORK_DIR}"
  -v "${PRE_COMMIT_CACHE_DIR}:\$HOME/.cache/pre-commit"
  -v "\$HOME/.codex:\$HOME/.codex"
  -v "\$HOME/.gitconfig:\$HOME/.gitconfig:ro"
  -v "\$HOME/.gitmessage:\$HOME/.gitmessage:ro"
  -v "\$HOME/.config/nvim:\$HOME/.config/nvim:ro"
)

gpg_dir="\$HOME/.gnupg"
container_agent_socket="\$gpg_dir/S.gpg-agent"
host_extra_socket="\$(gpgconf --list-dirs agent-extra-socket 2>/dev/null || true)"
if [[ -S "\$host_extra_socket" ]]; then
  docker_args+=(-v "\$host_extra_socket:\$container_agent_socket")
else
  printf 'dev: warning: host GPG extra socket not found; commit signing will not work until the agent is running.\\n' >&2
fi

if [[ -f "\$gpg_dir/pubring.kbx" ]]; then
  docker_args+=(-v "\$gpg_dir/pubring.kbx:\$gpg_dir/pubring.kbx:ro")
fi

if [[ -f "\$gpg_dir/trustdb.gpg" ]]; then
  docker_args+=(-v "\$gpg_dir/trustdb.gpg:\$gpg_dir/trustdb.gpg:ro")
fi

docker run "\${docker_args[@]}" "${IMAGE_NAME}" "\$@"
EOF

chmod +x "${DEV_BIN}"

echo "Installed dev at ${DEV_BIN}"
BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"
if ! grep -Fxq "export PATH=\"\$HOME/bin:\$PATH\"" "${BASHRC}"; then
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/bin:$PATH"' >> "${BASHRC}"
  echo "Added ${BIN_DIR} to PATH in ${BASHRC}"
fi
