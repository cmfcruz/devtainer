# shellcheck shell=bash
# Inputs supplied by the installer or preceding launcher fragments.
: "${dev_session:?}" "${session_dir:?}"
# Never trace credentials, including tokens retrieved through the host keyring.
github_trace=false
# Used by the subsequent config-mount fragment.
# shellcheck disable=SC2034
[[ $- != *x* ]] || github_trace=true
set +x

# Respect host config/keyring selection, but ignore credential env overrides.
host_gh() (
  unset GH_TOKEN GITHUB_TOKEN GH_DEBUG
  command gh "$@"
)

github_name="$dev_session"
github_dir="$session_dir"
github_file="$github_dir/github.account"
if [[ "${1:-}" == setup-github ]]; then
  shift
  if [[ $# -gt 1 ]]; then
    printf 'Usage: dev [--session NAME] setup-github [ACCOUNT]\n' >&2
    exit 1
  fi
  if [[ $# -eq 1 ]]; then
    github_user="$1"
  elif ! github_user="$(host_gh config get user --host github.com 2> /dev/null)"; then
    printf 'Cannot find the active host GitHub account. Run gh auth login --hostname github.com on the host, then setup-github again.\n' >&2
    exit 1
  fi
  if [[ ! "$github_user" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    printf 'Expected a GitHub account name containing letters, digits, or hyphens.\n' >&2
    exit 1
  fi
  if ! github_token="$(host_gh auth token --hostname github.com --user "$github_user" 2> /dev/null)"; then
    printf 'Cannot retrieve the host gh credential for account %s. Sign in to that account with gh auth login on the host. No session binding changed.\n' "$github_user" >&2
    exit 1
  fi
  if [[ ! "$github_token" =~ ^[a-zA-Z0-9_]+$ ]]; then
    printf 'Host gh returned an empty or malformed credential. No session binding changed.\n' >&2
    exit 1
  fi
  unset github_token
  umask 077
  if [[ -L "$github_dir" ]]; then
    printf 'Refusing a symlinked session directory.\n' >&2
    exit 1
  fi
  mkdir -p "$github_dir"
  if [[ ! -O "$github_dir" ]]; then
    printf 'The session directory must be owned by this user.\n' >&2
    exit 1
  fi
  chmod 700 "$github_dir"
  github_tmp="$(mktemp "$github_dir/.account.XXXXXXXXXX")"
  trap 'rm -f -- "$github_tmp"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "$github_user" > "$github_tmp"
  chmod 600 "$github_tmp"
  mv -fT -- "$github_tmp" "$github_file"
  printf 'Session "%s" now uses host gh account "%s". Its token is retrieved on each launch with the host login permissions.\n' "$github_name" "$github_user"
  exit 0
fi
