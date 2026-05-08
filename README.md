# devtainer

A small Docker-based development container for running repository tooling, Codex, Git, and pre-commit hooks away from the host.

The main goal is supply-chain isolation. Pre-commit hooks can install pinned but transitive npm, Python, and other packages. Some projects also require `npm install`, `npm ci`, or similar package-manager commands to populate `node_modules`, which executes dependency lifecycle scripts and expands the amount of third-party code involved in day-to-day development. This project puts those installs and hook executions inside a throwaway container to limit the blast radius while still allowing normal Git commits, including GPG-signed commits, from inside the container.

## What It Builds

`Dockerfile` builds an Ubuntu 26.04 image with:

- Bash, Git, GnuPG, curl, build tools, Neovim, ripgrep, fd, and ShellCheck
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

This builds the Docker image, then installs a host launcher at:

```bash
~/bin/dev
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

Or pass a command:

```bash
dev bash
dev pre-commit run --all-files
dev git status
```

For this repository, install and run the project hooks inside the dev container:

```bash
dev pre-commit install
dev pre-commit run --all-files
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

The launcher mounts only a small set of host paths:

```text
$PWD                           -> /workspace
~/.cache/devtainer/pre-commit  -> ~/.cache/pre-commit
~/.codex                       -> ~/.codex
~/.gitconfig                   -> ~/.gitconfig:ro
~/.gitmessage                  -> ~/.gitmessage:ro
~/.config/nvim                 -> ~/.config/nvim:ro
```

Pre-commit normally stores hook environments in `~/.cache/pre-commit`, or in `PRE_COMMIT_HOME` when that variable is set. The launcher sets `PRE_COMMIT_HOME=~/.cache/pre-commit` inside the container and backs it with the dedicated host directory `~/.cache/devtainer/pre-commit`. This avoids reinstalling pinned hook environments on every throwaway container run without mounting the host's broader `~/.cache`.

To reset cached hook environments:

```bash
rm -rf ~/.cache/devtainer/pre-commit
```

For GPG signing, it also mounts the host GPG agent extra socket, when available:

```bash
gpgconf --list-dirs agent-extra-socket
```

into the container at the normal GPG agent socket path:

```bash
~/.gnupg/S.gpg-agent
```

If present, these public GPG files are mounted read-only:

```text
~/.gnupg/pubring.kbx
~/.gnupg/trustdb.gpg
```

Private GPG keys are not copied into the image or mounted into the container. In particular, `~/.gnupg/private-keys-v1.d` is not mounted.

## Git Signing

Start the host GPG agent:

```bash
gpgconf --launch gpg-agent
```

Confirm the extra socket exists:

```bash
gpgconf --list-dirs agent-extra-socket
```

Inside the container, configure Git signing if your mounted `~/.gitconfig` does not already do so:

```bash
git config user.signingkey YOUR_KEY_ID
git config commit.gpgsign true
git config gpg.program gpg
```

Verify GPG signing:

```bash
printf 'test\n' | gpg --local-user YOUR_KEY_ID --clearsign
```

Verify Git signing:

```bash
git commit --allow-empty -S -m "test signed commit"
git log -1 --show-signature
```

## Security Model

This setup is designed so pre-commit hooks and package installers run in the container, not directly on the host.

Important boundaries:

- The container does not receive your private GPG key files.
- The host GPG agent socket allows signing requests while mounted.
- A compromised container should not be able to steal private GPG keys, but it may ask the host agent to sign data.
- Host confirmation, pinentry, hardware-token touch policy, and GPG agent cache settings still matter.
- `~/.cache/devtainer/pre-commit` persists downloaded hook environments across container runs. This is a speed tradeoff; malicious hook code could persist there until the cache is deleted.
- `~/.codex` is mounted read-write because Codex needs its config/auth state. Treat it as sensitive.
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
