#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-devtainer:26.04}"

build_flags=()
no_cache=false
skip_build=false

usage() {
  cat << EOF
Usage: ${0##*/} [--no-cache] [--skip-build]

  --no-cache   Build the image without using Docker's layer cache. Use this to
               force a fresh \`git clone\` of pinned dependencies (e.g. buoy.nvim)
               when the pinned branch has moved but the ref name is unchanged.
  --skip-build Regenerate host launchers without rebuilding the image.
  -h, --help   Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)
      build_flags+=(--no-cache)
      no_cache=true
      shift
      ;;
    --skip-build)
      skip_build=true
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

if [[ "${skip_build}" == true && "${no_cache}" == true ]]; then
  echo "--skip-build cannot be combined with --no-cache" >&2
  exit 1
fi

USERNAME="$(id -un)"
USER_UID="$(id -u)"
USER_GID="$(id -g)"

if [[ "${skip_build}" == true ]]; then
  echo "Skipping image build; regenerating launchers for ${IMAGE_NAME}"
else
  echo "Building ${IMAGE_NAME} using USERNAME=${USERNAME}, USER_UID=${USER_UID}, USER_GID=${USER_GID}"
  docker build \
    ${build_flags[@]+"${build_flags[@]}"} \
    --build-arg USERNAME="${USERNAME}" \
    --build-arg USER_UID="${USER_UID}" \
    --build-arg USER_GID="${USER_GID}" \
    -f Dockerfile \
    -t "${IMAGE_NAME}" \
    .
fi

BIN_DIR="${HOME}/bin"
DEV_BIN="${BIN_DIR}/dev"
SECCOMP_PROFILE_DIR="${HOME}/.config/devtainer"
SECCOMP_PROFILE="${SECCOMP_PROFILE_DIR}/claude-sandbox-seccomp.json"
mkdir -p "${BIN_DIR}" "${SECCOMP_PROFILE_DIR}"
install -m 0644 security/claude-sandbox-seccomp.json "${SECCOMP_PROFILE}"

# Quote install-time values as shell literals; generated dev has no repo dependency.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'image_name=%q\n' "$IMAGE_NAME"
  printf 'builder_uid=%q\n' "$USER_UID"
  printf 'container_home=%q\n' "/home/$USERNAME"
  printf 'seccomp_profile=%q\n' "$SECCOMP_PROFILE"
  cat scripts/session-launcher.sh scripts/run-container.sh \
    scripts/github-config.sh scripts/wayland.sh scripts/start-container.sh
} > "$DEV_BIN"
chmod +x "$DEV_BIN"
echo "Installed $DEV_BIN. Use dev for session dev, or dev --session personal for a separate persistent home."

# Retire only launchers carrying our old generated signatures. No volume migration.
for legacy in "$BIN_DIR/devil" "$BIN_DIR/dev-secure"; do
  if [[ -f "$legacy" ]] && grep -Fq 'docker_args=(' "$legacy" &&
    { grep -Fq 'volume_name="devil-' "$legacy" || grep -Fq 'PRE_COMMIT_HOME=' "$legacy"; }; then
    rm -f -- "$legacy"
    echo "Removed obsolete generated launcher $legacy; its old volumes are untouched."
  fi
done

BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"
if ! grep -Fxq "export PATH=\"\$HOME/bin:\$PATH\"" "${BASHRC}"; then
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/bin:$PATH"' >> "${BASHRC}"
  echo "Added ${BIN_DIR} to PATH in ${BASHRC}"
fi
