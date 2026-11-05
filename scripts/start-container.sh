# shellcheck shell=bash
# Inputs supplied by the installer or preceding launcher fragments.
: "${builder_uid:?}" "${dev_session:?}" "${volume_name:?}" "${image_name:?}" "${docker_args:?}"
# Validate the credential before creating any persistent home state.
docker volume create \
  --label devtainer.managed=true \
  --label "devtainer.uid=$builder_uid" \
  --label "devtainer.session=$dev_session" \
  "$volume_name" > /dev/null
verify_session_volume
docker run "${docker_args[@]}" "$image_name" "$@"
