# devtainer

A small Docker-based development container for running repository tooling, Codex, Git, and pre-commit hooks away from the host.

The main goal is supply-chain isolation. Pre-commit hooks can install pinned but transitive npm, Python, and other packages. Some projects also require `npm install`, `npm ci`, or similar package-manager commands to populate `node_modules`, which executes dependency lifecycle scripts and expands the amount of third-party code involved in day-to-day development. This project puts those installs and hook executions inside a throwaway container to limit the blast radius while still allowing normal Git and Codex workflows from inside the container.

## What It Builds

`Dockerfile` builds an Ubuntu 26.04 image with:

- Bash, Git, GnuPG, curl, build tools, Neovim, ripgrep, fd, ShellCheck, `yamllint`, `yq`, `actionlint`, `stylua`, and `kubectl`
- Node via nvm, pinned in the Dockerfile
- `@openai/codex`, pinned in the Dockerfile
- Claude Code, pinned in the Dockerfile
- [`buoy.nvim`](https://github.com/cmfcruz/buoy.nvim), a Neovim plugin cloned into the image that runs Codex or Claude Code in a popup and feeds the agent live editor context through a prompt hook and a private agent CLI
- Python via pyenv
- `pre-commit`

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

Run:

```bash
./install.sh
```

This builds the Docker image, then installs host launchers at:

```bash
~/bin/dev
~/bin/devil
```

The default image tag is:

```bash
devtainer:26.04
```

Override it during install if you need a different local tag:

```bash
IMAGE_NAME=my-devtainer:26.04 ./install.sh
```

If needed, it also idempotently adds this to `~/.bashrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

Open a new shell, or run:

```bash
source ~/.bashrc
```

## Usage

From any repository:

```bash
dev
```

`dev` is the Claude Code-capable mode. It mounts `~/.claude` and `~/.claude.json` read-write, mounts dedicated host dependency caches, and mounts the host GPG agent extra socket and public keyring for code signing when available.

With no arguments, both `dev` and `devil` open a tmux session named after the host directory you launched from, starting a shell in `/workspace`. Periods and colons in directory names become underscores because tmux reserves those characters. For example, launching from `~/code/my.app` creates session `my_app`. The session attaches if it already exists in that container. Sessions last for the lifetime of the container; the `devil` home volume persists files, not running sessions. Pass a command to override the default, such as `dev nvim .` or `devil bash`.

Use `devil` for a persistent container home backed by a Docker named volume:

```bash
devil
```

The volume is named `devil-<host username>` and mounted at `/home`. On first use, Docker initializes the empty volume from the image's `/home`, including the default tmux and Neovim settings baked into the image. The managed Codex and Claude Code wrappers are also installed at `/usr/local/bin/codex` and `/usr/local/bin/claude` so existing `devil` volumes created by older images can still use them after rebuilding devtainer.

`dev` handles dependency installation and pre-commit environment setup:

```bash
dev npm install
dev npm ci
dev pip install -r requirements.txt
dev pre-commit install
dev pre-commit install-hooks
dev pre-commit run --all-files
```

Use `pre-commit install` to install the Git hook script, and `pre-commit install-hooks` to download and build the hook environments in the shared pre-commit cache.

Code signing also runs in `dev`:

```bash
dev git commit -S -m "signed change"
dev git tag -s v1.0.0
```

`dev` mounts the host GPG agent extra socket when available and public GPG keyring files read-only when present, so signing uses the host agent. Private key files are never mounted. Because `dev` also mounts the shared pre-commit cache, a signed commit reuses already-built hook environments; to skip hooks entirely, use `--no-verify`:

```bash
dev git commit -S --no-verify -m "signed change"
```

Or pass a command to either launcher:

```bash
dev claude
dev bash
dev git status
dev pre-commit run --all-files
devil bash
devil claude
```

The hook config checks shell formatting/linting, Dockerfile linting, Markdown linting, YAML syntax, private-key leaks, merge conflict markers, line endings, trailing whitespace, executable shebangs, and stale pre-commit excludes.

The current directory is mounted at:

```bash
/workspace
```

The container is run with:

- `--rm`
- `--cap-drop ALL`
- `--security-opt no-new-privileges`

## UTF-8 And Neovim

The image defaults to `C.UTF-8` so shells, tmux, Git, Python, and Neovim can read and write UTF-8 text such as Japanese characters without switching command output to a Japanese locale.

Verify the active character map with:

```bash
dev bash -lc 'locale charmap'
devil bash -lc 'locale charmap'
```

Both commands should print:

```text
UTF-8
```

`devil` uses a self-contained home volume, so devtainer also installs a managed Neovim UTF-8 plugin inside that volume. Existing custom Neovim configuration is left in place; only `~/.config/nvim/plugin/devtainer-utf8.lua` is created or refreshed when it is already marked as managed by devtainer.

If Japanese text appears as boxes or missing glyphs, change the host terminal font to one with Japanese glyph coverage. The container controls encoding; the terminal controls glyph rendering.

## Clipboard

The container has no X or Wayland clipboard provider, so Neovim is configured to route the system clipboard (`unnamedplus`) through [OSC 52](https://github.com/neovim/neovim/pull/25872) escape sequences. Yanks to the `+`/`*` registers are sent to the host clipboard via the terminal emulator, and pastes read from it, so copy and paste integrate with the host without mounting any host clipboard socket.

This requires a terminal emulator with OSC 52 support enabled (Ghostty, kitty, WezTerm, iTerm2, recent Windows Terminal, and others). If clipboard integration does not work, confirm your terminal allows OSC 52 clipboard writes/reads.

## Neovim Agent Popup

The image clones [`buoy.nvim`](https://github.com/cmfcruz/buoy.nvim), so Neovim inside every devtainer mode automatically loads it. The plugin does two things:

- Toggles the agent's official TUI (Codex or Claude Code) in a popup window with `:Buoy` or `<F2>`.
- Enriches every prompt you submit with a snapshot of the live editor state (cwd, current file, cursor, visual selection, and open buffers) through a `UserPromptSubmit` hook, and gives the agent a private, session-scoped CLI to read buffer ranges and diagnostics or move the cursor mid-turn — so you can say "refactor this selection" without pasting code.

The plugin is installed at `/usr/local/share/nvim/site/pack/devtainer/start/buoy.nvim`, a system runtime path that is not under `$HOME`. This keeps it active even in `dev`, where the host `~/.config/nvim` and `~/.local/share/nvim` are mounted read-only over the container home. A managed sibling file initializes the plugin on startup, selecting Claude Code in `dev` and Codex in `devil` to match each mode's default agent. `devil` sets `DEVTAINER_AGENT=codex` in its launcher; set that variable yourself to override the agent in either mode.

buoy.nvim doesn't use an MCP server: it wires up the prompt hook, the private CLI, and its own agent instructions itself when it launches the agent, so the `codex` and `claude` wrappers carry no buoy-specific flags and nothing is seeded into `~/.codex` or `~/.claude.json`. The entrypoint removes the `AGENTS.md` guidance file that older devtainer images seeded into `$CODEX_HOME` (only the copy carrying the `Managed by devtainer.` marker; a file of your own is never touched).

## Host GitHub CLI Configuration

Both `dev` and `devil` mount your host `~/.config/gh` read-only when it
exists, so `gh` can reuse your host login and settings. Host `GH_CONFIG_DIR`
and `XDG_CONFIG_HOME` overrides are respected. Run `./install.sh`
on the host to regenerate both launchers, then start a new container.

The mounted login has the same GitHub permissions as on the host. Read-only
mounting prevents config changes; it does not restrict GitHub API access.
If your host login stores its token in an OS keyring, the config mount alone
cannot provide that token inside the container. Login and account changes
should be made on the host.

## Host Mounts

The launchers mount only a small set of host paths.

`dev` mounts:

```text
$PWD                           -> /workspace
~/.claude                      -> ~/.claude
~/.claude.json                 -> ~/.claude.json
~/.gitconfig                   -> ~/.gitconfig:ro
~/.gitmessage                  -> ~/.gitmessage:ro
~/.config/nvim                 -> ~/.config/nvim:ro
~/.cache/devtainer/pre-commit  -> ~/.cache/pre-commit
~/.cache/devtainer/npm         -> ~/.cache/npm
~/.cache/devtainer/pip         -> ~/.cache/pip
$(gpgconf --list-dirs agent-extra-socket) -> ~/.gnupg/S.gpg-agent, when available
~/.gnupg/pubring.kbx           -> ~/.gnupg/pubring.kbx:ro, when present
~/.gnupg/trustdb.gpg           -> ~/.gnupg/trustdb.gpg:ro, when present
```

`devil` mounts:

```text
$PWD                           -> /workspace
devil-<host username>           -> /home, as a Docker named volume
```

Pre-commit normally stores hook environments in `~/.cache/pre-commit`, or in `PRE_COMMIT_HOME` when that variable is set. `dev` sets `PRE_COMMIT_HOME=~/.cache/pre-commit` inside the container and backs it with the dedicated host directory `~/.cache/devtainer/pre-commit`, so hook environments persist across throwaway container runs.

`dev` also sets `NPM_CONFIG_CACHE=~/.cache/npm` and `PIP_CACHE_DIR=~/.cache/pip` inside the container, backed by dedicated host directories under `~/.cache/devtainer`. This avoids reinstalling dependency artifacts on every throwaway container run without mounting the host's broader `~/.cache`.

To reset cached dependency environments:

```bash
rm -rf ~/.cache/devtainer/pre-commit ~/.cache/devtainer/npm ~/.cache/devtainer/pip
```

`dev` mounts the host GPG agent extra socket into the container at `~/.gnupg/S.gpg-agent`, but it does not mount private GPG key files. In particular, `~/.gnupg/private-keys-v1.d` is not mounted, so the private key stays on the host and signing happens in the host agent over the socket.

## Git Signing

Start the host GPG agent:

```bash
gpgconf --launch gpg-agent
```

Confirm the extra socket exists:

```bash
gpgconf --list-dirs agent-extra-socket
```

Inside `dev`, configure Git signing if your mounted `~/.gitconfig` does not already do so:

```bash
dev git config user.signingkey YOUR_KEY_ID
dev git config commit.gpgsign true
dev git config gpg.program gpg
```

Verify GPG signing:

```bash
dev bash -lc "printf 'test\n' | gpg --local-user YOUR_KEY_ID --clearsign"
```

Verify Git signing:

```bash
dev git commit --allow-empty -S -m "test signed commit"
dev git log -1 --show-signature
```

## Security Model

This setup is designed so pre-commit hooks and package installers run in the container, not directly on the host. The container limits the blast radius of a supply-chain attack or prompt injection to what is explicitly mounted; anything not on the mount list stays out of reach.

`dev` is a single container that runs untrusted code (npm installs, pre-commit hooks) alongside your Claude Code credentials and GPG signing socket. Understand what that co-location exposes.

Still protected — never mounted into any container:

- Private GPG key files. Signing uses the host GPG agent over its extra socket; `~/.gnupg/private-keys-v1.d` is not mounted, so the private key never leaves the host and cannot be extracted.
- SSH keys, cloud credentials (`~/.aws`, `~/.config/gcloud`, and similar), and everything else in your host home outside the explicit mount list.
- Any repository or file outside the current directory (`$PWD`).

Exposed to code running in `dev` — treat as reachable by a compromised dependency or injected prompt:

- `~/.claude` and `~/.claude.json`, mounted read-write because Claude Code needs its config/auth state. A malicious process in `dev` can read and, with network access, exfiltrate these. Treat them as sensitive, and rotate Claude credentials if you suspect compromise.
- The GPG agent extra socket. The extra socket restricts key-management operations, but a compromised process can still ask the agent to produce signatures while the socket is mounted.
- The pre-commit, npm, and pip caches, which persist across container runs. Malicious install code could persist there until the caches are deleted.
- The current repository, mounted read-write so development commands can edit files.

If an old alias or shell function shadows `~/bin/dev`, remove it:

```bash
unalias dev 2>/dev/null || true
unset -f dev 2>/dev/null || true
hash -r
type -a dev
```

`type -a dev` should resolve to:

```text
~/bin/dev
```
