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

# Credentials: place .sandbox-secrets.yaml in the workspace to inject
# sandbox-specific credentials. Resolved on host, wiped from container after placement.

# Run security test suite
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
4. **Container Isolation** — no Docker socket/SSH keys/host credentials mounted; 2 CPU / 4 GB RAM / 512 PID limits

### Key Files

| File | Role |
|------|------|
| `Dockerfile` | Ubuntu 26.04 base; installs Python, mise, gosu, iptables, Squid, Podman, Claude Code |
| `entrypoint.sh` | Root startup: UID/GID remap → update CLIs → lock settings → init firewall → [DinD init: `sandbox::reharden_proc_paths` runs first, then `sandbox::setup_rootless_podman`] → drop to devuser |
| `init-firewall.sh` | Configures Squid + iptables (allows loopback, DNS, Anthropic CIDR; denies everything else for devuser) |
| `lock-settings.sh` | Copies canonical config from image to `/home/devuser/.claude/`, makes all files root-owned read-only; preserves the user's `enabledPlugins` across the overwrite (so installed plugins stay enabled across restarts); overlays DinD tree and merges `settings.overrides.json` when `ENABLE_DOCKER=true` |
| `bin/code-sandbox` | Host-side launcher: builds image, mounts cwd, passes HOST_UID/GID, reuses container per workspace |
| `sandbox-exec` | Thin wrapper used as the `docker exec` target; sources `/etc/environment` (proxy, DinD vars) before exec'ing the user command |
| `proxy-log.sh` | Reads Squid access logs from inside the running container |
| `config/.claude/settings.json` | Active permission profile (currently permissive); single source of truth for both normal and DinD mode |
| `config-dind/.claude/settings.overrides.json` | DinD-only settings diff — `jq`-merged on top of base at startup; adds `docker *`/`podman *` allows, removes the docker deny |
| `config/dind-seccomp.json` | Custom seccomp profile for DinD mode (adds `unshare`, `mount`, `setns` to Docker default) |
| `settings-profiles/strict.json` | No arbitrary shell/Python; only explicitly listed commands |
| `settings-profiles/permissive.json` | Allows `python *`; relies on firewall as primary defense |
| `settings-profiles/dind-permissive.json` | Permissive + Docker/Podman commands; for use with `--enable-docker` |
| `render-credentials.sh` | Container-side credential rendering; reads payload, renders gomplate templates, locks files, wipes payload |
| `.sandbox-secrets.yaml` | Per-project credential config (not in image; placed in workspace root on host) |
| `sandbox-templates/` | Built-in gomplate templates for common formats (gradle-properties, dotenv, npmrc, netrc) |

### Network Flow

All `devuser` traffic → Squid proxy (localhost:3128) → domain allowlist → internet.  
Anthropic API CIDR (`160.79.104.0/23:443`) is also allowed directly via iptables.  
iptables rejects anything that bypasses the proxy.  
JVM tools (Gradle, Maven, `java`) are pointed at the proxy via `JAVA_TOOL_OPTIONS` in `/etc/environment`; they ignore `http_proxy`/`https_proxy` and only read proxy *system properties*.

### Docker-in-Docker Mode (`--enable-docker`)

Use `bin/code-sandbox --enable-docker` when the task needs Docker (testcontainers, `docker build`, docker-compose stacks).

**What it does:**
- Installs and starts rootless **Podman** inside the sandbox (daemonless, no `--privileged` needed)
- Provides a Docker-compatible API socket at `$DOCKER_HOST` so `docker` CLI and testcontainers work unchanged
- Sets `TESTCONTAINERS_RYUK_DISABLED=true` (Ryuk is incompatible with Podman and unnecessary in an ephemeral sandbox)
- Loads the DinD settings profile (unlocks `docker *` and `podman *` commands)
- Adds container registry domains (docker.io, ghcr.io, gcr.io, quay.io) to the Squid allowlist
- Increases the memory limit to 8 GB (PID limit stays at 512, same as the base profile)
- Enables **bridge networking** for inner containers: `docker compose` stacks get
  their own netavark network with aardvark-dns, so services resolve each other by
  name. Standalone containers still default to host netns (keeping the
  `localhost:3128` proxy path).

**Security model unchanged:**
- No `--privileged` on the outer container — only a targeted seccomp profile
  (`config/dind-seccomp.json`) that adds `unshare`/`mount`/`setns`, plus
  `--security-opt systempaths=unconfined` so rootless netavark can write the
  `net.*` sysctls a bridge needs. `systempaths=unconfined` strips all of Docker's
  default `/proc` protections, so `entrypoint.sh` (via
  `sandbox::reharden_proc_paths`) immediately re-applies runc's default masks and
  read-only paths and re-opens **only** `/proc/sys/net`. Residual exposure:
  `/proc/sys/net` writable by root and the re-masks not being kernel-locked — both
  scoped to `--enable-docker` and covered by `test-sandbox.sh`.
- Bridged inner containers have **no external egress**: their masqueraded traffic
  exits as `devuser` and hits the same iptables REJECT, so they can only talk to
  each other, not the internet.
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

### Credential Injection (`.sandbox-secrets.yaml`)

Place a `.sandbox-secrets.yaml` file in the workspace root to inject sandbox-specific credentials into the container. These should be credentials created specifically for the sandbox (not your personal keys), to limit blast radius and simplify rotation.

**Configuration format:**

```yaml
secrets:
  NEXUS_USER:
    source: gopass show ci/nexus/user    # any shell command; stdout = value
  NEXUS_PASS:
    source: gopass show ci/nexus/password
  NPM_TOKEN:
    source: sops -d --extract '["npm_token"]' secrets.enc.yaml

targets:
  - template: gradle-properties          # built-in template name
    dest: /home/devuser/.gradle/gradle.properties
    secrets:
      - name: NEXUS_USER
        as: nexusUser                    # alias for Gradle naming convention
      - name: NEXUS_PASS
        as: nexusPassword
  - template: dotenv
    dest: /workspace/.env.sandbox
    secrets:
      - NEXUS_USER                       # shorthand: no alias
  - template: .sandbox-templates/npmrc.tpl  # custom template (relative to workspace)
    dest: /home/devuser/.npmrc
    secrets:
      - name: NPM_TOKEN
        as: authToken
```

**Host requirements:** `yq` (Go-based) and `jq` must be installed on the host:
```bash
brew install yq jq    # macOS
apt install jq yq     # Debian/Ubuntu
```

**Security model:**
- Secrets are resolved on the host (where gopass/sops/etc. live); never stored in the image
- Resolved values pass into the container via a tmpfs-backed file, wiped from the host filesystem before `docker run`
- Inside the container, `render-credentials.sh` renders templates and wipes the payload before the agent starts
- Rendered credential files are `root:devuser 0444` — readable by tools (Gradle, npm) but not modifiable by the agent
- Auto-generated deny rules in `settings.json` block the agent from reading them via Claude Code's Read tool or `cat`

**Built-in templates** (in `/usr/local/share/sandbox-templates/`):

| Template name | Format | Expected secret names |
|---|---|---|
| `gradle-properties` | Java `.properties` (key=value) | any (iterates all) |
| `dotenv` | Shell `.env` (KEY="value") | any (iterates all) |
| `npmrc` | npm auth config | `authToken` (required), `registry` (optional) |
| `netrc` | netrc machine/login/password | `machine`, `login`, `password` (all required) |

Custom templates can be placed in `.sandbox-templates/` in the workspace and referenced by name, or by path relative to workspace root (e.g. `.sandbox-templates/myfile.tpl`).

### Container Reuse

`bin/code-sandbox` derives a deterministic container name from the workspace path. If the container already exists for that workspace, it attaches to it rather than creating a new one.

### Credential Persistence

A `claude-state-home` Docker volume persists Claude auth and OpenCode credentials across runs. Git identity is inherited from `git config user.name/email` on the host.

The volume is mounted at `/home/devuser`, so installed Claude plugins (under `~/.claude/plugins/`) and their marketplaces persist too. Plugin *enablement*, however, lives in `~/.claude/settings.json` under `enabledPlugins`, which `lock-settings.sh` overwrites with the image canonical on every start — so the lock step explicitly captures `enabledPlugins` from the prior settings and re-merges it after the copy, keeping enabled plugins enabled across restarts (everything else still comes from the locked canonical).

### Security Test Suite

`test-sandbox.sh` runs automated checks covering: settings lock enforcement, iptables rules, privilege escalation attempts, sensitive path exposure, firewall bypass attempts, and credential injection. CI runs this on every push/PR via `.github/workflows/security-tests.yml`.

## Commit Convention

Uses Conventional Commits: `feat:`, `fix:`, `refactor:`, `test:`, `ci:`, `chore:`, `docs:`. Include JIRA refs in the footer (e.g., `ING-123`) when applicable.
