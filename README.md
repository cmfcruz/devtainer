# devtainer

A small Docker-based development container for running repository tooling, Codex, Git, and pre-commit hooks away from the host.

The main goal is supply-chain isolation. Pre-commit hooks can install pinned but transitive npm, Python, and other packages. Some projects also require `npm install`, `npm ci`, or similar package-manager commands to populate `node_modules`, which executes dependency lifecycle scripts and expands the amount of third-party code involved in day-to-day development. This project puts those installs and hook executions inside a throwaway container to limit the blast radius while still allowing normal Git and Codex workflows from inside the container.

## What It Builds

`Dockerfile` builds an Ubuntu 26.04 image with:

- Bash, Git, GitHub CLI (`gh`), GnuPG, curl, build tools, Neovim, ripgrep, fd, ShellCheck, `yamllint`, `yq`, `actionlint`, `stylua`, `kubectl`, Claude Code sandbox dependencies (`bubblewrap` and `socat`), and the Docker CLI (no Docker engine)
- Node via nvm, pinned in the Dockerfile
- `@openai/codex`, pinned in the Dockerfile
- Claude Code, pinned in the Dockerfile
- [`buoy.nvim`](https://github.com/cmfcruz/buoy.nvim), a Neovim plugin cloned into the image that runs Codex or Claude Code in a popup and feeds the agent live editor context through a prompt hook and a private agent CLI
- Python via pyenv
- `pre-commit`

The image includes the Docker CLI only. The `dev` launcher does not expose the host Docker socket, so a workflow that needs a Docker daemon must opt into an external daemon connection explicitly.

The image creates a non-root user matching the host username, UID, and GID passed by `install.sh`, so bind-mounted workspace files keep normal ownership.

Codex is wrapped inside the image with:

```bash
--sandbox=danger-full-access --ask-for-approval=on-request
```

That disables Codex's internal sandbox because the container is the isolation boundary, but keeps approval prompts enabled.

Claude Code is wrapped inside the image with:

```bash
--permission-mode=auto
```

That lets `dev claude` run in auto mode, which uses a classifier to skip prompts for routine actions while still pausing on riskier ones. Pass an explicit permission mode, such as `dev claude --permission-mode default` for a stricter one-off session or `dev claude --permission-mode bypassPermissions` to skip all prompts.

## Install

The host needs Linux, Bash 4+, Docker, and `flock` (util-linux). Host `gh` is also
needed for GitHub setup and container launches. The image uses the builder's username, UID, and GID.

```bash
bash install.sh
```

This builds `devtainer:26.04` and installs `~/bin/dev`. Use `IMAGE_NAME` to select
another image tag. The installer adds `~/bin` to the host Bash PATH if needed.
Use `bash install.sh --skip-build` after a launcher-only change; `--no-cache`
forces a fresh image build. Those two options cannot be combined.

There is no migration. The generated `devil` and `dev-secure` launchers are retired;
old Docker volumes, host caches, and old GitHub profiles are left untouched. They
are not imported into the new sessions. Configure credentials and tools afresh.
Custom commands at the legacy launcher paths are not overwritten or deleted.

## Named Sessions

```bash
dev                             # default session: dev
dev --session personal          # independent personal environment
dev --session personal claude   # override the default tmux command
```

A session selects persistent account state, not a running container. Each launch
creates a new container from the same image, mounts the current project at
`/workspace`, and attaches the selected session's home volume at `/home`:

```text
dev       -> devtainer-<builder UID>-dev-home
personal  -> devtainer-<builder UID>-personal-home
```

Claude/Codex logins, configuration, shell settings, Git identity, Neovim data,
caches, and tools installed under home persist independently in each volume.
Configure them inside the selected session. Host Claude state, Git and Neovim
configuration, dependency caches, and the host GPG agent are not mounted.
The container home is `/home/<build username>`, regardless of the host home path.

Session names contain 1-48 letters, digits, underscores, or hyphens, starting with
a letter or digit. Session options precede subcommands and container commands:

```bash
dev --session personal setup-github
dev --session personal reset-home
dev --session personal git status
```

With no command, tmux uses the current project directory's name, replacing periods
and colons with underscores. This tmux name is independent of the account session.
Running tmux processes end with their container; the home volume persists files.
Multiple containers can use one session home concurrently, so account changes and
home-file edits are shared within that session. Use different sessions for account
separation; the project mount remains shared if you select the same project.

The bundled buoy.nvim plugin defaults to Claude Code for all sessions. Use
`DEVTAINER_AGENT=codex dev --session personal` to select Codex, or configure
`DEVTAINER_AGENT` in that session's home environment. Claude Code and Codex are
available directly in every session.

## GitHub Access Through Host gh

Dev retrieves GitHub credentials through the host's saved `gh` login and keyring.
No personal access token creation or token pasting is needed. Sign in to the
accounts you need using `gh auth login --hostname github.com` on the host.

Bind each session to a host account once:

```bash
dev setup-github                         # bind dev to the host's active account
dev --session personal setup-github YOUR_PERSONAL_USERNAME
```

An explicit username selects an account already saved in host `gh`, without
switching the host's active account. Omitting it selects the currently active
host account. Setup checks that `gh` can retrieve that account's token, then
atomically saves only its username at:

```text
~/.config/devtainer/sessions/<session>/github.account
```

The session directory is mode `700` and the account file mode `600`. Setup runs
without Docker or a terminal prompt and leaves an existing binding unchanged if
retrieval fails. It does not create a second permanent token store or modify the
host login. Old PAT `*.credential` and `*.token` files are left untouched and are
not read; rerun setup to save the account binding.

Each launch uses `gh auth token --hostname github.com --user <bound-account>`.
Switching the host's active account does not change an existing session's binding.
A missing binding or unavailable credential fails launch; dev never substitutes
another session or active account. Host `GH_CONFIG_DIR` and `XDG_CONFIG_HOME`
are respected; `GH_TOKEN`, `GITHUB_TOKEN`, and `GH_DEBUG` overrides are removed
from the host retrieval subprocess. Local retrieval does not validate expiration
or repository access with GitHub. See [gh auth token](https://cli.github.com/manual/gh_auth_token).

**The container receives the host credential's full permissions.** A read-only
mount does not make GitHub access read-only. Code in the container can read and
copy the credential, read permitted private data, and perform writes allowed by
that token. The host account's organization and SSO policies still apply.

The token is copied into a temporary directory (mode `700`), containing
`hosts.yml` and `config.yml` (mode `600`). Schema version `1` prevents config
migration on the read-only mount. The directory is mounted at the container
user's `~/.config/gh`, and `GH_CONFIG_DIR` points there. The host gh configuration,
keyring, and session account-binding files are not mounted.

Tokens are not passed through Docker arguments or token environment variables.
Shell tracing is disabled during retrieval and writing. The entrypoint clears
initial token overrides after loading its home environment; later interactive
shell configuration can still change environment settings.

Temporary snapshots are removed after exit, Docker failure, and handled HUP, INT,
and TERM signals. SIGKILL or a host crash can leave plaintext snapshots under
`${TMPDIR:-/tmp}`. Remove leftovers after their containers stop. The temporary root
must be available to a local Docker daemon and outside the project mount. A
workspace exposing the host gh config or session account configuration is rejected.

Host credential changes take effect on the next launch. Rebind an account by
running setup again. Removing the account from host `gh` prevents new retrieval;
revoke the credential on GitHub to invalidate existing snapshots. Resetting a
home keeps the session's account binding.

GitHub CLI `2.103.3` is installed from the pinned upstream release with SHA-256
verification for amd64 and arm64. Check access with:

```bash
dev gh auth status
dev --session personal gh auth status
```

## Reset a Session Home

```bash
dev reset-home
dev --session personal reset-home
```

The command displays the exact volume and requires typing the selected session
name in an interactive terminal. It deletes that volume's logins, shell state,
settings, caches, and home-installed tools. The next launch initializes a fresh
home from the image. The host account binding and mounted project files are kept.
A missing home volume is already reset and requires no confirmation.

Reset refuses homes used by another launcher or attached to any Docker container,
including stopped containers. Stop and remove those containers first. Shared
session locks allow concurrent launches and prevent a reset from racing them.
Ownership labels must match the builder UID and session; arbitrary or old volumes
are not adopted or deleted. Volume removal is never forced.

Rebuilding the image and resetting a home are separate operations. Image rebuilds
update system-level tools but do not replace an existing volume's home-installed
runtimes or configuration. Reset the affected session to seed those from the new
image. A reset is not a complete compromise recovery: inspect the workspace and
Git hooks, revoke exposed credentials, and rebuild from trusted sources as needed.

## Clipboard, Neovim, and Signing

When Wayland is available, `dev` mounts its socket at `/run/host-wayland/wayland-0`
and exposes it to clipboard tools. This gives container code host clipboard access
and any further capabilities offered by the compositor. Without Wayland, Neovim
uses OSC 52, subject to terminal support and clipboard permissions.

The image uses UTF-8 (`C.UTF-8`) and includes a Neovim UTF-8 plugin. The bundled
buoy.nvim plugin lives in the system runtime, outside session homes, and connects
agents to live editor context without sharing the host's Neovim state.

Git identity and signing credentials are configured within each session. No host
GPG socket or keyring is automatically shared. Private keys created in a session
are part of that session's home state and are deleted by `reset-home`.

## Container Sandbox

All sessions retain the existing `dev` sandbox configuration: dropped capabilities,
`no-new-privileges`, a [seccomp profile](security/claude-sandbox-seccomp.json), and
the [devtainer AppArmor profile](security/devtainer-nested-sandbox.apparmor).
Claude Code's nested sandbox needs Bubblewrap and socat, included in the image.
Install and load the AppArmor profile on the Docker host before first launch:

```bash
sudo install -m 0644 security/devtainer-nested-sandbox.apparmor /etc/apparmor.d/devtainer-nested-sandbox
sudo apparmor_parser -r /etc/apparmor.d/devtainer-nested-sandbox
```

The launcher uses `systempaths=unconfined` for Bubblewrap to create its nested
`/proc`. The custom profiles allow namespace and mount operations to all processes
in the container, while capabilities remain dropped. These settings expose more
kernel surface than standard Docker defaults. An unloaded named AppArmor profile
causes Docker to reject the launch. `DEVTAINER_APPARMOR_PROFILE` selects a different
loaded profile, but its restrictions may prevent Claude's nested sandbox working.

## Security Boundary

These are separate home environments, not complete isolation from the host or
from each other. All sessions use the same image and host kernel, can reach the
network, can access their selected host GitHub credential, and can change the mounted
workspace. The host Wayland socket is shared when available. A malicious process
can persist inside its session home until reset.

The launcher does not share host Claude configuration, host home caches, host
Git/Neovim settings, the host GPG agent, SSH keys, cloud credentials, or the Docker
socket. However, anything inside the directory selected as the workspace is
reachable. Do not use a broad workspace containing sensitive host files. Project
scripts and Git hooks changed inside a container can execute later on the host.
Path policies under `~/.config/gh` may constrain an agent's sandboxed tools, but do
not make credentials inaccessible to arbitrary code running as the container user.
