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

# Run security test suite (28 checks)
bash test-sandbox.sh

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
| `Dockerfile` | Ubuntu 26.04 base; installs Python, mise, gosu, iptables, Squid, Claude Code |
| `entrypoint.sh` | Root startup: UID/GID remap → update CLIs → lock settings → init firewall → drop to devuser |
| `init-firewall.sh` | Configures Squid + iptables (allows loopback, DNS, Anthropic CIDR; denies everything else for devuser) |
| `lock-settings.sh` | Copies canonical config from image to `/home/devuser/.claude/`, makes all files root-owned read-only |
| `bin/code-sandbox` | Host-side launcher: builds image, mounts cwd, passes HOST_UID/GID, reuses container per workspace |
| `proxy-log.sh` | Reads Squid access logs from inside the running container |
| `config/.claude/settings.json` | Active permission profile (currently permissive) |
| `settings-profiles/strict.json` | No arbitrary shell/Python; only explicitly listed commands |
| `settings-profiles/permissive.json` | Allows `python *`; relies on firewall as primary defense |

### Network Flow

All `devuser` traffic → Squid proxy (localhost:3128) → domain allowlist → internet.  
Anthropic API CIDR (`160.79.104.0/23:443`) is also allowed directly via iptables.  
iptables rejects anything that bypasses the proxy.

### Container Reuse

`bin/code-sandbox` derives a deterministic container name from the workspace path. If the container already exists for that workspace, it attaches to it rather than creating a new one.

### Credential Persistence

A `claude-state-home` Docker volume persists Claude auth and OpenCode credentials across runs. Git identity is inherited from `git config user.name/email` on the host.

### Security Test Suite

`test-sandbox.sh` runs 28 automated checks covering: settings lock enforcement, iptables rules, privilege escalation attempts, sensitive path exposure, and firewall bypass attempts. CI runs this on every push/PR via `.github/workflows/security-tests.yml`.

## Commit Convention

Uses Conventional Commits: `feat:`, `fix:`, `refactor:`, `test:`, `ci:`, `chore:`, `docs:`. Include JIRA refs in the footer (e.g., `ING-123`) when applicable.
