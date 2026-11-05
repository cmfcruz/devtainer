# shellcheck shell=bash
# Inputs supplied by the installer or preceding launcher fragments.
: "${builder_uid:?}"
# Parsed before subcommands so home state and credentials share one identity.
dev_session=dev
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      if [[ $# -lt 2 ]]; then
        printf 'Usage: dev [--session NAME] [setup-github | reset-home | command ...]\n' >&2
        exit 1
      fi
      dev_session="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h | --help)
      printf '%s\n' 'Usage: dev [--session NAME] [setup-github | reset-home | command ...]' \
        'Default session: dev. No command opens a directory-named tmux session.' \
        'setup-github saves the selected session GitHub token.' \
        'reset-home deletes the selected session home after confirmation.'
      exit 0
      ;;
    -*)
      printf 'Unknown dev option: %s. Use dev --help.\n' "$1" >&2
      exit 1
      ;;
    *) break ;;
  esac
done
if [[ ! "$dev_session" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$ ]]; then
  printf 'Session names must contain 1-48 letters, digits, underscores, or hyphens and start with a letter or digit.\n' >&2
  exit 1
fi
volume_name="devtainer-${builder_uid}-${dev_session}-home"
session_dir="$HOME/.config/devtainer/sessions/$dev_session"

# Shared locks allow several containers in a session; resetting needs exclusivity.
prepare_session_lock() {
  if [[ -L "$session_dir" ]]; then
    printf 'Refusing a symlinked session directory.\n' >&2
    exit 1
  fi
  (
    umask 077
    mkdir -p "$session_dir"
  )
  if [[ ! -O "$session_dir" ]]; then
    printf 'The session directory must be owned by this user.\n' >&2
    exit 1
  fi
  chmod 700 "$session_dir"
  if [[ -L "$session_dir/home.lock" ]]; then
    printf 'Refusing a symlinked session lock.\n' >&2
    exit 1
  fi
  (
    umask 077
    touch "$session_dir/home.lock"
  )
  exec 9< "$session_dir/home.lock"
}
verify_session_volume() {
  local identity
  identity="$(docker volume inspect --format '{{ index .Labels "devtainer.managed" }}:{{ index .Labels "devtainer.uid" }}:{{ index .Labels "devtainer.session" }}' "$volume_name")"
  if [[ "$identity" != "true:$builder_uid:$dev_session" ]]; then
    printf 'Refusing volume %s: its devtainer ownership labels do not match this session.\n' "$volume_name" >&2
    exit 1
  fi
}

if [[ "${1:-}" == reset-home ]]; then
  if [[ $# -ne 1 ]]; then
    printf 'Usage: dev [--session NAME] reset-home\n' >&2
    exit 1
  fi
  prepare_session_lock
  if ! flock --nonblock --exclusive 9; then
    printf 'Session %s is in use. Stop its containers before resetting the home.\n' "$dev_session" >&2
    exit 1
  fi
  existing_volume="$(docker volume ls --quiet --filter "name=^${volume_name}$")"
  if [[ -z "$existing_volume" ]]; then
    printf 'Session %s has no home volume to reset.\n' "$dev_session"
    exit 0
  fi
  verify_session_volume
  attached="$(docker ps --all --quiet --filter "volume=$volume_name")"
  if [[ -n "$attached" ]]; then
    printf 'Volume %s is attached to a container. Remove that container before resetting.\n' "$volume_name" >&2
    exit 1
  fi
  printf 'Reset session "%s": delete volume %s, including logins, settings, caches, and home-installed tools.\n' "$dev_session" "$volume_name"
  printf 'The workspace and the session\x27s saved GitHub profile are kept.\n'
  if [[ ! -t 0 ]]; then
    printf 'reset-home requires an interactive terminal for confirmation.\n' >&2
    exit 1
  fi
  if ! IFS= read -r -p "Type the session name ($dev_session) to delete its home: " reset_confirmation; then
    exit 1
  fi
  if [[ "$reset_confirmation" != "$dev_session" ]]; then
    printf 'Cancelled; no volume deleted.\n'
    exit 0
  fi
  # Docker also refuses removal if another client attaches during confirmation.
  verify_session_volume
  docker volume rm "$volume_name"
  printf 'Home reset. The next dev launch initializes it from the image.\n'
  exit 0
fi

if [[ "${1:-}" != setup-github ]]; then
  prepare_session_lock
  if ! flock --nonblock --shared 9; then
    printf 'Session %s is being reset. Try again after the reset finishes.\n' "$dev_session" >&2
    exit 1
  fi
fi
