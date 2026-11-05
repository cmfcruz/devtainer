# shellcheck shell=bash
# Inputs supplied by the installer or preceding launcher fragments.
: "${builder_uid:?}" "${dev_session:?}" "${container_home:?}" "${volume_name:?}" "${seccomp_profile:?}"
if [[ $# -eq 0 ]]; then
  tmux_session="$(basename "$PWD")"
  tmux_session="${tmux_session//[.:]/_}"
  [[ "$tmux_session" != / ]] || tmux_session=workspace
  set -- tmux new-session -A -s "$tmux_session" -c /workspace
fi

# Used by the subsequent mount and startup fragments.
# shellcheck disable=SC2034
docker_args=(
  --rm
  -it
  --cap-drop ALL
  --security-opt no-new-privileges
  --security-opt "seccomp=$seccomp_profile"
  --security-opt "apparmor=${DEVTAINER_APPARMOR_PROFILE:-devtainer-nested-sandbox}"
  --security-opt systempaths=unconfined
  --hostname "$(basename "$PWD")"
  --label devtainer.managed=true
  --label "devtainer.session=$dev_session"
  --label "devtainer.uid=$builder_uid"
  -e TERM=xterm-256color
  -e "HOME=$container_home"
  -e "DEVTAINER_SESSION=$dev_session"
  -e "DEVTAINER_AGENT=${DEVTAINER_AGENT:-claude}"
  -v "$volume_name:/home"
  -v "$PWD:/workspace"
)
# shellcheck disable=SC2034
container_gh_config="$container_home/.config/gh"
