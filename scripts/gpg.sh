# shellcheck shell=bash
: "${container_home:?}" "${docker_args:?}"

# Sign through the host agent without mounting private key files.
gpg_dir="$HOME/.gnupg"
container_gpg_dir="$container_home/.gnupg"
host_extra_socket="$(gpgconf --list-dirs agent-extra-socket 2> /dev/null || true)"
docker_args+=(-e GPG_TTY=/dev/tty -e "GNUPGHOME=$container_gpg_dir")
if [[ -S "$host_extra_socket" ]]; then
  docker_args+=(-v "$host_extra_socket:$container_gpg_dir/S.gpg-agent")
else
  printf 'dev: warning: host GPG extra socket not found; signing will not work until the agent is running.\n' >&2
fi

for gpg_file in pubring.kbx trustdb.gpg; do
  if [[ -f "$gpg_dir/$gpg_file" ]]; then
    docker_args+=(-v "$gpg_dir/$gpg_file:$container_gpg_dir/$gpg_file:ro")
  fi
done
