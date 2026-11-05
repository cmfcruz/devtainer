# Devtainer Security Review Prompt

Review devtainer for security vulnerabilities, with particular attention to the
dedicated-token-to-container GitHub credential handoff. Review both the current
working tree and the committed changes: there are unrelated local tool and sandbox
changes that also affect the overall security posture. Make no changes initially.

Intended behavior:

- The builder's username, UID, GID, and home are used inside the image.
- Host-only setup-github opens a fine-grained PAT form prefilled with read access
  to Contents, Actions, and Pull requests. Hidden input and isolated gh API login
  validation precede atomic saving of a named credential profile (600/700).
- Setup validates identity, not grants; the user must select only read permissions.
- Both launchers read only the selected dedicated profile. Missing/unsafe profiles
  fail closed; no fallback to the full-access host login or token environment exists.
- They create a unique temporary directory (700) and hosts.yml/config.yml (600),
  mount it read-only at the container user's ~/.config/gh, and set GH_CONFIG_DIR.
- No host gh config or OS keyring is mounted. No credential is passed through
  Docker arguments or token environment variables. The persistent credential store
  itself is not mounted.
- The entrypoint clears token overrides and restores the expected GH_CONFIG_DIR
  after loading the persistent home environment.
- The launcher removes temporary credentials after exit and handled signals.

Inspect install.sh, generated dev/devil launchers, the Dockerfile/entrypoint,
tests, security profiles, mounts, persistent home handling, and documentation.
Use synthetic credentials only. Never print, retrieve, upload, or use real secrets.

Assess:

1. Credential leaks through tracing, logs, argv, exported environment, temporary
   files, Docker metadata, persistent volumes, build layers, and error paths.
2. Temporary file permissions, races, symlinks, malicious TMPDIR values, mount
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
ensuring no credential file persists in devil's home volume after exit.

Report concrete findings first, ordered by severity, with file/line references,
attack prerequisites, impact, reproduction using fake secrets, and a minimal fix.
Separate verified vulnerabilities from design tradeoffs and untested concerns.
Identify important missing tests. Do not treat the intended use of gh authentication
as a vulnerability by itself, and do not claim that passing unit tests proves the
container secure. If no actionable findings exist, say so and list residual risks
and verification limits.
