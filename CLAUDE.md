# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

A portable, hardened Docker sandbox for running Claude Code agents with defense-in-depth security controls. It provides an isolated container environment with egress firewall, privilege separation, and locked permission settings to safely run Claude Code on arbitrary codebases.

## Running / Testing

```bash
# Run the sandbox (builds image, mounts cwd as /workspace)
bin/code-sandbox -- [command]

# Skip rebuilding the image
bin/code-sandbox --no-build -- [command]

# Interactive shell
bin/code-sandbox

# Run Claude agent on a task
bin/code-sandbox -- claude -p "your task" --max-turns 20

# Enable Docker (Podman) inside the sandbox for testcontainers / docker builds
bin/code-sandbox --enable-docker -- claude -p "run the tests" --max-turns 30

# Run security test suite (28 checks)
bash test-sandbox.sh

# Run security tests including Docker-in-Docker checks
bash test-sandbox.sh --enable-docker

# View Squid proxy logs
proxy-log [all|denied|allowed|follow]
```

## Architecture

### Four Defense Layers (in priority order)

1. **Permission Settings** (`config/.claude/settings.json`) — explicit allow/deny lists for what Claude Code can execute; locked root-owned/immutable at container startup
2. **Egress Firewall** (`init-firewall.sh`) — Squid proxy (domain allowlist) + iptables default-deny OUTPUT policy
3. **Non-root Agent** — container starts as root, drops to `devuser` via `gosu` after initialization
4. **Container Isolation** — no Docker socket/SSH keys/host credentials mounted; 2 CPU / 4 GB RAM / 100 PID limits

### Key Files

| File | Role |
|------|------|
| `Dockerfile` | Ubuntu 26.04 base; installs Python, mise, gosu, iptables, Squid, Podman, Claude Code |
| `entrypoint.sh` | Root startup: UID/GID remap → update CLIs → lock settings → init firewall → [DinD init] → drop to devuser |
| `init-firewall.sh` | Configures Squid + iptables (allows loopback, DNS, Anthropic CIDR; denies everything else for devuser) |
| `lock-settings.sh` | Copies canonical config from image to `/home/devuser/.claude/`, makes all files root-owned read-only; selects DinD profile when `ENABLE_DOCKER=true` |
| `bin/code-sandbox` | Host-side launcher: builds image, mounts cwd, passes HOST_UID/GID, reuses container per workspace |
| `proxy-log.sh` | Reads Squid access logs from inside the running container |
| `config/.claude/settings.json` | Active permission profile (currently permissive) |
| `config-dind/.claude/settings.json` | DinD permission profile — same as permissive but allows `docker *` and `podman *` |
| `config/dind-seccomp.json` | Custom seccomp profile for DinD mode (adds `unshare`, `mount`, `setns` to Docker default) |
| `settings-profiles/strict.json` | No arbitrary shell/Python; only explicitly listed commands |
| `settings-profiles/permissive.json` | Allows `python *`; relies on firewall as primary defense |
| `settings-profiles/dind-permissive.json` | Permissive + Docker/Podman commands; for use with `--enable-docker` |

### Network Flow

All `devuser` traffic → Squid proxy (localhost:3128) → domain allowlist → internet.  
Anthropic API CIDR (`160.79.104.0/23:443`) is also allowed directly via iptables.  
iptables rejects anything that bypasses the proxy.

### Docker-in-Docker Mode (`--enable-docker`)

Use `bin/code-sandbox --enable-docker` when the task needs Docker (testcontainers, `docker build`, docker-compose stacks).

**What it does:**
- Installs and starts rootless **Podman** inside the sandbox (daemonless, no `--privileged` needed)
- Provides a Docker-compatible API socket at `$DOCKER_HOST` so `docker` CLI and testcontainers work unchanged
- Sets `TESTCONTAINERS_RYUK_DISABLED=true` (Ryuk is incompatible with Podman and unnecessary in an ephemeral sandbox)
- Loads the DinD settings profile (unlocks `docker *` and `podman *` commands)
- Adds container registry domains (docker.io, ghcr.io, gcr.io, quay.io) to the Squid allowlist
- Increases resource limits: 512 PIDs, 8 GB RAM

**Security model unchanged:**
- No `--privileged` on the outer container — only a targeted seccomp profile (`config/dind-seccomp.json`) that adds `unshare`/`mount`/`setns`
- Inner containers use **user namespaces** (UID 100000–165535) — they cannot escape to host resources
- Inner container traffic uses `pasta` networking (shares `devuser`'s network namespace), so all egress still exits as `devuser` UID → still blocked by iptables → must go through Squid → domain-filtered
- No host Docker socket is mounted; inner containers use Podman's own runtime

**Testcontainers configuration:**
```bash
# These are set automatically by the entrypoint when --enable-docker is active:
DOCKER_HOST=unix:///run/user/<UID>/podman/podman.sock
TESTCONTAINERS_RYUK_DISABLED=true
```

**Add extra registries if needed** (e.g. for private images):
```
# .sandbox-domains
registry.mycompany.com
```

### Container Reuse

`bin/code-sandbox` derives a deterministic container name from the workspace path. If the container already exists for that workspace, it attaches to it rather than creating a new one.

### Credential Persistence

A `claude-state-home` Docker volume persists Claude auth and OpenCode credentials across runs. Git identity is inherited from `git config user.name/email` on the host.

### Security Test Suite

`test-sandbox.sh` runs 28 automated checks covering: settings lock enforcement, iptables rules, privilege escalation attempts, sensitive path exposure, and firewall bypass attempts. CI runs this on every push/PR via `.github/workflows/security-tests.yml`.

## Commit Convention

Uses Conventional Commits: `feat:`, `fix:`, `refactor:`, `test:`, `ci:`, `chore:`, `docs:`. Include JIRA refs in the footer (e.g., `ING-123`) when applicable.
