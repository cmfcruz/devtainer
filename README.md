# devtainer

A small Docker-based development container for running repository tooling, Codex, Git, and pre-commit hooks away from the host.

The main goal is supply-chain isolation. Pre-commit hooks can install pinned but transitive npm, Python, and other packages. Some projects also require `npm install`, `npm ci`, or similar package-manager commands to populate `node_modules`, which executes dependency lifecycle scripts and expands the amount of third-party code involved in day-to-day development. This project puts those installs and hook executions inside a throwaway container to limit the blast radius while still allowing normal Git and Codex workflows from inside the container.

## What It Builds

`Dockerfile` builds an Ubuntu 26.04 image with:

- Bash, Git, GnuPG, curl, build tools, Neovim, ripgrep, fd, ShellCheck, `yamllint`, `yq`, `actionlint`, and `kubectl`
- Node via nvm
- `@openai/codex`
- Python via pyenv
- `pre-commit`

The image creates a non-root user matching the host username, UID, and GID passed by `install.sh`, so bind-mounted workspace files keep normal ownership.

Codex is wrapped inside the image with:

```bash
--sandbox=danger-full-access --ask-for-approval=on-request
```

That disables Codex's internal sandbox because the container is the isolation boundary, but keeps approval prompts enabled.

## Install

Run:

```bash
./install.sh
```

This builds the Docker image, then installs host launchers at:

```bash
~/bin/dev
~/bin/dev-init
~/bin/dev-sign
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

`dev` is the Codex-capable mode. It mounts `~/.codex` read-write, does not mount host dependency caches, and does not mount the host GPG agent.

Use `dev-init` for dependency installation and pre-commit environment setup:

```bash
dev-init npm install
dev-init npm ci
dev-init pip install -r requirements.txt
dev-init pre-commit install
dev-init pre-commit install-hooks
dev-init pre-commit run --all-files
```

`dev-init` mounts dedicated host dependency caches, does not mount `~/.codex`, and does not mount the host GPG agent. Use `pre-commit install` to install the Git hook script, and `pre-commit install-hooks` to download and build the hook environments in the shared pre-commit cache.

Use `dev-sign` for code signing without container network access:

```bash
dev-sign git commit -S -m "signed change"
dev-sign git tag -s v1.0.0
```

`dev-sign` runs with `--network none`. It mounts the host GPG agent extra socket when available, public GPG keyring files read-only when present, and the dedicated pre-commit cache so already-initialized hooks can run during `git commit`. It does not mount `~/.codex`, npm cache, or pip cache.

If a commit needs a pre-commit hook environment that is not already in the shared pre-commit cache, `dev-sign git commit` cannot fetch it because networking is disabled. Warm the cache first:

```bash
dev-init pre-commit install-hooks
dev-init pre-commit run --all-files
dev-sign git commit -S -m "signed change"
```

Or, after running checks separately, sign without rerunning hooks:

```bash
dev-sign git commit -S --no-verify -m "signed change"
```

Or pass a command to any launcher:

```bash
dev codex
dev bash
dev git status
dev-init bash
dev-init pre-commit run --all-files
dev-sign bash
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

## Host Mounts

All three launchers mount only a small set of host paths.

`dev` mounts:

```text
$PWD                           -> /workspace
~/.codex                       -> ~/.codex
~/.gitconfig                   -> ~/.gitconfig:ro
~/.gitmessage                  -> ~/.gitmessage:ro
~/.config/nvim                 -> ~/.config/nvim:ro
```

`dev-init` mounts:

```text
$PWD                           -> /workspace
~/.cache/devtainer/pre-commit  -> ~/.cache/pre-commit
~/.cache/devtainer/npm         -> ~/.cache/npm
~/.cache/devtainer/pip         -> ~/.cache/pip
~/.gitconfig                   -> ~/.gitconfig:ro
~/.gitmessage                  -> ~/.gitmessage:ro
~/.config/nvim                 -> ~/.config/nvim:ro
```

`dev-sign` mounts:

```text
$PWD                           -> /workspace
~/.cache/devtainer/pre-commit  -> ~/.cache/pre-commit
~/.gitconfig                   -> ~/.gitconfig:ro
~/.gitmessage                  -> ~/.gitmessage:ro
~/.config/nvim                 -> ~/.config/nvim:ro
$(gpgconf --list-dirs agent-extra-socket) -> ~/.gnupg/S.gpg-agent
~/.gnupg/pubring.kbx           -> ~/.gnupg/pubring.kbx:ro, when present
~/.gnupg/trustdb.gpg           -> ~/.gnupg/trustdb.gpg:ro, when present
```

Pre-commit normally stores hook environments in `~/.cache/pre-commit`, or in `PRE_COMMIT_HOME` when that variable is set. `dev-init` and `dev-sign` set `PRE_COMMIT_HOME=~/.cache/pre-commit` inside the container and back it with the dedicated host directory `~/.cache/devtainer/pre-commit`. Use `dev-init` to initialize or update hook environments because it has network access; `dev-sign` can only reuse hook environments that are already present.

`dev-init` also sets `NPM_CONFIG_CACHE=~/.cache/npm` and `PIP_CACHE_DIR=~/.cache/pip` inside the container, backed by dedicated host directories under `~/.cache/devtainer`. This avoids reinstalling dependency artifacts on every throwaway container run without mounting the host's broader `~/.cache`.

To reset cached dependency environments:

```bash
rm -rf ~/.cache/devtainer/pre-commit ~/.cache/devtainer/npm ~/.cache/devtainer/pip
```

`dev` and `dev-init` do not mount the host GPG agent socket or private GPG key files.

`dev-sign` mounts the host GPG agent extra socket into the container at `~/.gnupg/S.gpg-agent`, but it does not mount private GPG key files. In particular, `~/.gnupg/private-keys-v1.d` is not mounted.

## Git Signing

Start the host GPG agent:

```bash
gpgconf --launch gpg-agent
```

Confirm the extra socket exists:

```bash
gpgconf --list-dirs agent-extra-socket
```

Inside the no-network signing container, configure Git signing if your mounted `~/.gitconfig` does not already do so:

```bash
dev-sign git config user.signingkey YOUR_KEY_ID
dev-sign git config commit.gpgsign true
dev-sign git config gpg.program gpg
```

Verify GPG signing:

```bash
dev-sign bash -lc "printf 'test\n' | gpg --local-user YOUR_KEY_ID --clearsign"
```

Verify Git signing:

```bash
dev-sign git commit --allow-empty -S -m "test signed commit"
dev-sign git log -1 --show-signature
```

## Security Model

This setup is designed so pre-commit hooks and package installers run in the container, not directly on the host.

Important boundaries:

- The container does not receive your private GPG key files.
- The host GPG agent socket is mounted only by `dev-sign`.
- `dev-sign` runs with Docker networking disabled.
- `dev-init` persists downloaded pre-commit, npm, and pip cache data across container runs. `dev-sign` also mounts the pre-commit cache so warmed hooks can run offline during commits. This is a speed and ergonomics tradeoff; malicious install code could persist there until the caches are deleted.
- `dev` mounts `~/.codex` read-write because Codex needs its config/auth state. Treat it as sensitive.
- `dev` does not mount host dependency caches.
- `dev-init` does not mount `~/.codex`.
- The current repository is mounted read-write so development commands can edit files.

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

`type -a dev-init` should resolve to:

```text
~/bin/dev-init
```

`type -a dev-sign` should resolve to:

```text
~/bin/dev-sign
```
