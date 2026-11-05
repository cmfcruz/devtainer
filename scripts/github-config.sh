# shellcheck shell=bash
# Inputs supplied by the installer or preceding launcher fragments.
: "${github_trace:?}" "${github_file:?}" "${github_dir:?}" "${github_name:?}" "${dev_session:?}" "${container_gh_config:?}"
# Disable tracing before retrieving or expanding any credential.
gh_trace="$github_trace"
set +x
gh_config_tmp="$(mktemp -d "${TMPDIR:-/tmp}/devtainer-gh.XXXXXXXXXX")"
cleanup_gh_config() {
  rm -rf -- "$gh_config_tmp"
}
trap cleanup_gh_config EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$gh_config_tmp"
# Prevent alternate access through /workspace or another host directory mount.
gh_config_tmp="$(cd "$gh_config_tmp" && pwd -P)"
for gh_mount_arg in "${docker_args[@]}"; do
  gh_mount_source="${gh_mount_arg%%:*}"
  [[ "$gh_mount_arg" == /*:* && -d "$gh_mount_source" ]] || continue
  gh_mount_source="$(cd "$gh_mount_source" && pwd -P)"
  if [[ "$gh_mount_source" == / || "$gh_config_tmp/" == "$gh_mount_source/"* ]]; then
    printf 'devtainer: temporary credentials would be exposed through a host directory mount; set TMPDIR outside mounted directories.\n' >&2
    exit 1
  fi
done
if [[ ! -f "$github_file" || -L "$github_file" || ! -O "$github_file" || -L "$github_dir" || ! -O "$github_dir" ]]; then
  printf 'devtainer: GitHub account binding for session "%s" is missing or unsafe. Run: %s --session %s setup-github\n' "$github_name" "${0##*/}" "$dev_session" >&2
  exit 1
fi
if [[ "$(stat -c %a "$github_file")" != 600 || "$(stat -c %a "$github_dir")" != 700 ]]; then
  printf 'devtainer: GitHub account file must have mode 600 and its directory mode 700. Run setup-github again.\n' >&2
  exit 1
fi
# Keep host account-selection state out of the mounted workspace.
github_store="$(cd "$github_dir" && pwd -P)/github.account"
host_gh_config="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
if [[ -d "$host_gh_config" ]]; then
  host_gh_config="$(cd "$host_gh_config" && pwd -P)"
else
  host_gh_config=""
fi
for gh_mount_arg in "${docker_args[@]}"; do
  gh_mount_source="${gh_mount_arg%%:*}"
  [[ "$gh_mount_arg" == /*:* && -d "$gh_mount_source" ]] || continue
  gh_mount_source="$(cd "$gh_mount_source" && pwd -P)"
  if [[ "$gh_mount_source" == / || "$github_store" == "$gh_mount_source/"* ||
    (-n "$host_gh_config" && ("$host_gh_config" == "$gh_mount_source" || "$host_gh_config/" == "$gh_mount_source/"*)) ]]; then
    printf 'devtainer: the host GitHub configuration would be exposed through a host directory mount. Launch from a project directory outside that store.\n' >&2
    exit 1
  fi
done
mapfile -t gh_account < "$github_file"
if [[ "${#gh_account[@]}" != 1 || ! "${gh_account[0]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  printf 'devtainer: malformed GitHub account binding. Run setup-github again.\n' >&2
  exit 1
fi
gh_user="${gh_account[0]}"
# Explicit account selection preserves session identity if the host active user changes.
if ! gh_token="$(host_gh auth token --hostname github.com --user "$gh_user" 2> /dev/null)"; then
  printf 'devtainer: cannot retrieve the host gh credential for account %s. Sign in to that account on the host.\n' "$gh_user" >&2
  exit 1
fi
if [[ ! "$gh_token" =~ ^[a-zA-Z0-9_]+$ ]]; then
  printf 'devtainer: host gh returned an empty or malformed credential.\n' >&2
  exit 1
fi
(
  umask 077
  printf 'github.com:\n    user: "%s"\n    oauth_token: "%s"\n    git_protocol: https\n    users:\n        "%s":\n            oauth_token: "%s"\n' "$gh_user" "$gh_token" "$gh_user" "$gh_token" > "$gh_config_tmp/hosts.yml"
)
# gh auth status migrates configs without a schema marker, even with users set.
(
  umask 077
  printf 'version: 1\n' > "$gh_config_tmp/config.yml"
)
unset gh_token gh_user gh_account
docker_args+=(
  --mount "type=bind,source=$gh_config_tmp,target=$container_gh_config,readonly"
  -e "GH_CONFIG_DIR=$container_gh_config"
)
if [[ "$gh_trace" == true ]]; then
  set -x
fi
