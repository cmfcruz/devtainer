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
needed for GitHub setup. The image uses the builder's username, UID, and GID.

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

## Dedicated Read-only GitHub Access

GitHub profiles follow the selected session. The default and personal session
must each be configured independently, even if they previously used `devil`:

```bash
dev setup-github
dev --session personal setup-github
```

Setup runs on the host without Docker. It opens a token form with a 30-day
expiration and **Contents**, **Actions**, and **Pull requests** set to **Read-only**.
Choose the resource owner and selected repositories. Metadata read is included.
The form can be edited: grant no write permissions. Setup validates token format
and account login, not its permissions. GitHub enforces the actual grants.
See [GitHub's fine-grained token documentation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

Paste the token at the hidden prompt. Host `gh` validates it through an isolated
temporary config, without changing your normal login. A failed validation or
cancelled prompt preserves the saved profile. If a browser cannot open, use the
printed URL. A fine-grained token covers one resource owner; organization approval
may be required even after the login check succeeds.

The profile is stored on the host at:

```text
~/.config/devtainer/sessions/<session>/github.credential
```

The session directory is mode `700`, and the credential file is mode `600`. Account
and token are replaced atomically together. The old `--github-token` option and
positional profile names are removed; use `--session` for all session selection.
Old `github/*.credential` and `*.token` files are never used as fallbacks.

At launch, only that session's credential is copied into a temporary directory
(mode `700`), containing `hosts.yml` and `config.yml` (mode `600`). Schema version
`1` prevents configuration migration on the read-only mount. This directory is
mounted at the container user's `~/.config/gh`, and `GH_CONFIG_DIR` points there.
The host gh config, keyring, and persistent profile store are not mounted.

Credentials are not passed through Docker arguments or token environment
variables. Shell tracing is disabled during credential handling. Missing, unsafe,
or malformed profiles stop launch; another session or the host's full-access login
is never used instead. Normal launches require neither host `gh` nor API access.
The entrypoint clears initial token overrides after loading its home environment.
Later interactive shell configuration can still override environment settings.

Temporary snapshots are removed after exit, Docker failure, and handled HUP, INT,
and TERM signals. SIGKILL or a host crash can leave plaintext snapshots under
`${TMPDIR:-/tmp}`. Remove leftovers after their containers stop. The temporary root
must be available to a local Docker daemon and outside the project mount. A
workspace containing the persistent credential store is also rejected.

Rotate a profile by running setup again, then start a new container. Deleting its
host file prevents future use; revoke it on GitHub to invalidate running copies.
Resetting a home keeps its host profile. An exposed PAT or private repository data
can still be copied by container code; read-only grants restrict GitHub writes,
not reads or exfiltration.

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
home from the image. The host GitHub profile and mounted project files are kept.
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
network, can access their dedicated GitHub credential, and can change the mounted
workspace. The host Wayland socket is shared when available. A malicious process
can persist inside its session home until reset.

The launcher does not share host Claude configuration, host home caches, host
Git/Neovim settings, the host GPG agent, SSH keys, cloud credentials, or the Docker
socket. However, anything inside the directory selected as the workspace is
reachable. Do not use a broad workspace containing sensitive host files. Project
scripts and Git hooks changed inside a container can execute later on the host.
Path policies under `~/.config/gh` may constrain an agent's sandboxed tools, but do
not make credentials inaccessible to arbitrary code running as the container user.
