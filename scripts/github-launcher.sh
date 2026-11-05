# shellcheck shell=bash
# Embedded in both host launchers. Never trace pasted or stored credentials.
github_trace=false
# Used by the embedded config-mount block in install.sh.
# shellcheck disable=SC2034
[[ $- != *x* ]] || github_trace=true
set +x

github_name=default
github_setup=false
if [[ "${1:-}" == setup-github ]]; then
  github_setup=true
  shift
  if [[ $# -gt 1 ]]; then
    printf 'Usage: %s setup-github [name]\n' "${0##*/}" >&2
    exit 1
  fi
  github_name="${1:-default}"
elif [[ "${1:-}" == --github-token ]]; then
  if [[ $# -lt 2 ]]; then
    printf 'Usage: %s --github-token NAME [command ...]\n' "${0##*/}" >&2
    exit 1
  fi
  github_name="$2"
  shift 2
fi
if [[ ! "$github_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  printf 'Token names must start with a letter or digit and contain only letters, digits, _ or -.\n' >&2
  exit 1
fi

github_dir="$HOME/.config/devtainer/github"
github_file="$github_dir/$github_name.credential"
if [[ "$github_setup" == true ]]; then
  if [[ ! -t 0 ]]; then
    printf 'setup-github needs an interactive terminal; token input is hidden.\n' >&2
    exit 1
  fi
  if ! command -v gh > /dev/null 2>&1; then
    printf 'setup-github requires GitHub CLI (gh) on the host to validate the token.\n' >&2
    exit 1
  fi
  github_url='https://github.com/settings/personal-access-tokens/new?name=devtainer-read-only&expires_in=30&contents=read&actions=read&pull_requests=read'
  printf 'Create a fine-grained token for the desired owner and selected repositories.\n'
  printf 'Use only Contents, Actions, and Pull requests: Read-only; Metadata is included.\n'
  printf 'The token form can be edited. Setup validates the login, not its permissions.\n%s\n' "$github_url"
  if command -v xdg-open > /dev/null 2>&1 && xdg-open "$github_url" < /dev/null > /dev/null 2>&1; then
    printf 'Opened the token form in your browser.\n'
  elif command -v gio > /dev/null 2>&1 && gio open "$github_url" < /dev/null > /dev/null 2>&1; then
    printf 'Opened the token form in your browser.\n'
  elif [[ "$(uname -s)" == Darwin ]] && command -v open > /dev/null 2>&1 && open "$github_url" < /dev/null > /dev/null 2>&1; then
    printf 'Opened the token form in your browser.\n'
  else
    printf 'Open the URL above manually if no browser opened.\n' >&2
  fi
  printf 'Saving token "%s" for dev and devil; an existing token with this name will be replaced.\n' "$github_name"
  if ! IFS= read -rs -p 'Paste token (hidden; empty cancels): ' github_token; then
    printf '\nCancelled; no token changed.\n' >&2
    exit 1
  fi
  printf '\n'
  if [[ -z "$github_token" ]]; then
    printf 'Cancelled; no token changed.\n'
    exit 0
  fi
  if [[ ! "$github_token" =~ ^github_pat_[a-zA-Z0-9_]+$ ]]; then
    printf 'Expected a fine-grained token beginning with github_pat_. No token changed.\n' >&2
    exit 1
  fi
  umask 077
  if [[ -L "$github_dir" ]]; then
    printf 'Refusing a symlinked devtainer credential directory.\n' >&2
    exit 1
  fi
  mkdir -p "$github_dir"
  if [[ ! -O "$github_dir" ]]; then
    printf 'The devtainer credential directory must be owned by this user.\n' >&2
    exit 1
  fi
  chmod 700 "$github_dir"
  github_tmp="$(mktemp -d "$github_dir/.setup.XXXXXXXXXX")"
  # Invoked by the EXIT trap.
  # shellcheck disable=SC2329
  cleanup_github_setup() { rm -rf -- "$github_tmp"; }
  trap cleanup_github_setup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'version: 1\n' > "$github_tmp/config.yml"
  printf 'github.com:\n    oauth_token: "%s"\n' "$github_token" > "$github_tmp/hosts.yml"
  if ! github_user="$(
    unset GH_TOKEN GITHUB_TOKEN GH_DEBUG
    export GH_CONFIG_DIR="$github_tmp"
    gh api --hostname github.com user --jq .login 2> /dev/null
  )"; then
    printf 'GitHub could not validate this token. Check the token and network connection; no saved token changed.\n' >&2
    exit 1
  fi
  if [[ ! "$github_user" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    printf 'GitHub returned an invalid account name; no saved token changed.\n' >&2
    exit 1
  fi
  printf '%s\n%s\n' "$github_user" "$github_token" > "$github_tmp/credential"
  chmod 600 "$github_tmp/credential"
  mv -fT -- "$github_tmp/credential" "$github_file"
  unset github_token github_user
  printf 'Saved %s (mode 600). Start a new container to use it.\n' "$github_file"
  exit 0
fi
