# shellcheck shell=bash
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
