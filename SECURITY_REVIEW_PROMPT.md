# Devtainer Security Review Prompt

Review devtainer for security vulnerabilities, with particular attention to the
host-gh-to-container GitHub credential handoff. Review both the current
working tree and the committed changes: there are unrelated local tool and sandbox
changes that also affect the overall security posture. Make no changes initially.

Intended behavior:

- The builder's username, UID, GID, and home are used inside the image.
- dev defaults to session dev; --session personal selects a separate persistent
  home volume; GitHub credentials always follow the active host gh account. Subcommands always follow the session.
- No previous volumes or profiles are migrated. Host Claude/Git/Neovim state,
  caches, and GPG sockets are not mounted. Wayland is still shared when available.
- reset-home checks volume labels and attachments, takes an exclusive per-session
  lock, and requires typing the session name. It removes only that home volume.
  Normal launches hold shared locks; the host GitHub login and workspaces are kept.
- No setup-github command or saved session-to-account binding is required.
  Old account bindings and PAT files are ignored and left untouched.
- Every launch reads the current host gh username and retrieves that account's
  token through the host keyring/config. A host account switch affects subsequent
  launches in all sessions. Retrieval failure never selects another saved account.
- No account name or token is persistently stored by this flow.
- The token retains all host permissions, including writes. This is intentional.
- GH_TOKEN/GITHUB_TOKEN/GH_DEBUG are removed during host retrieval, while host
  GH_CONFIG_DIR/XDG_CONFIG_HOME selection is respected.
- They create a unique temporary directory (700) and hosts.yml/config.yml (600),
  mount it read-only at the container user's ~/.config/gh, and set GH_CONFIG_DIR.
- No host gh config or OS keyring is mounted. No credential is passed through
  Docker arguments or token environment variables. The host gh configuration
  itself is not mounted.
- The entrypoint clears token overrides and restores the expected GH_CONFIG_DIR
  after loading the persistent home environment.
- The launcher removes temporary credentials after exit and handled signals.

Inspect install.sh, the generated dev launcher and scripts/ fragments, the Dockerfile/entrypoint,
tests, security profiles, mounts, persistent home handling, and documentation.
Use synthetic credentials only. Never print, retrieve, upload, or use real secrets.

Assess:

1. Credential leaks through tracing, logs, argv, exported environment, temporary
   files, Docker metadata, persistent volumes, build layers, and error paths.
2. Session/home/profile separation, reset scope, volume ownership, locks, confirmation,
   temporary file permissions, races, symlinks, malicious TMPDIR values, mount
   parsing, concurrent launches, cleanup on errors/signals, and SIGKILL limitations.
3. YAML/shell injection, malformed token handling, host credential selection,
   unexpected config overrides, gh version compatibility, and account rotation.
4. Whether mount destinations consistently remain under the container user's
   home and whether documented path policies provide the protection claimed.
5. The distinction between blocking direct secret reads and allowing an agent to
   invoke authenticated gh commands. Read-only mounts do not restrict API writes.
6. Broader container boundaries: sandbox profiles, capabilities, host sockets,
   config mounts, command wrappers, and persistent home initialization.

Run safe, relevant tests after inspecting them. Where Docker is available, propose
or run container checks using fake credentials, including read-only mounting and
ensuring no credential file persists in a session's home volume after exit.

Report concrete findings first, ordered by severity, with file/line references,
attack prerequisites, impact, reproduction using fake secrets, and a minimal fix.
Separate verified vulnerabilities from design tradeoffs and untested concerns.
Identify important missing tests. Do not treat the intended use of gh authentication
as a vulnerability by itself, and do not claim that passing unit tests proves the
container secure. If no actionable findings exist, say so and list residual risks
and verification limits.
