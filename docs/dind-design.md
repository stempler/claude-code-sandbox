# Docker-in-Docker (DinD) Design

**Date:** 2026-04-16  
**Status:** Implemented  
**Feature flag:** `--enable-docker` on `bin/code-sandbox`

---

## Why DinD is needed

Some tasks an agent runs require Docker: testcontainers-based integration tests, building images from Dockerfiles, running `docker-compose` stacks. Without DinD, these tasks fail immediately because no Docker runtime is available inside the sandbox.

---

## Approach chosen: rootless Podman

Five options were evaluated:

| Option | Extra caps needed | Daemon overhead | Firewall bypass risk |
|--------|-----------------|-----------------|----------------------|
| `--privileged` DinD | Full root + all caps | dockerd + containerd | High — root UID bypasses iptables |
| Minimal-capability DinD | `SYS_ADMIN`, seccomp=unconfined | dockerd + containerd | High |
| Sysbox | Needs kernel module / sysbox-runc | runc replacement | Low |
| **Rootless Podman** | `SYS_ADMIN` (for shared mount), targeted seccomp | None (daemonless) | **None — traffic exits as devuser UID** |
| Docker socket proxy | None | dockerd on host | Low, but leaks host daemon |

Rootless Podman was chosen because:
- Daemonless — no long-running daemon, low overhead
- Traffic from inner containers appears as `devuser` UID in the outer container's network namespace, so the existing iptables rules continue to apply without modification
- No host Docker socket is exposed — inner containers use Podman's own runtime
- Inner containers run in user namespaces (UID 100000–165535), limiting host-escape paths

---

## How it works end-to-end

### Outer container flags (`--enable-docker`)

```
--cap-add SYS_ADMIN          — needed for mount --make-rshared
--device /dev/fuse           — needed for fuse-overlayfs storage driver
--device /dev/net/tun        — needed for pasta network backend
--pids-limit 512             — higher limit for inner container processes
--memory 8g                  — more headroom for nested workloads
--security-opt seccomp=config/dind-seccomp.json
```

The seccomp profile (`config/dind-seccomp.json`) is Docker's default profile plus these additions:

| Syscall(s) | Why added |
|-----------|-----------|
| `clone`, `clone3` | User namespace creation |
| `unshare` | Namespace isolation for rootless containers |
| `mount`, `umount2` | fuse-overlayfs overlay mounts |
| `pivot_root`, `chroot` | Container root filesystem setup |
| `setns` | Entering container namespaces |
| `keyctl`, `add_key`, `request_key` | Session keyrings used by crun |
| `open_tree`, `move_mount`, `fsopen`, `fsmount`, `fspick`, `mount_setattr` | New Linux mount API (kernel 5.2+) used by newer crun versions |

### Entrypoint initialization (`entrypoint.sh`, `ENABLE_DOCKER=true` block)

1. `mount --make-rshared /` — makes the root mount shared so Podman can set up bind mounts inside inner containers. Docker creates containers with a private root mount by default; without this, `newuidmap` (the setuid-root helper for user namespace UID mapping) fails with "Operation not permitted" when Podman tries to enter its user namespace setup.

2. Creates `$XDG_RUNTIME_DIR` (`/run/user/<UID>`) — required by rootless Podman for its socket and temp files.

3. Writes `containers.conf` with:
   - `http_proxy = true` — propagates proxy env vars into inner containers
   - `env = [...]` — explicitly sets `http_proxy`, `https_proxy`, `no_proxy` in every inner container
   - `default_sysctls = []` — suppresses Podman's default sysctl writes (`net.ipv4.ping_group_range` etc.) which fail because `/proc/sys` is read-only inside Docker
   - `pidns = "host"` — inner containers share the outer container's PID namespace instead of creating their own. Required because Docker's outer container is **not** in the init PID namespace; when Podman creates a user namespace inside this nested PID namespace, the kernel blocks mounting `/proc` for security reasons.
   - `utsns = "host"` — inner containers share the outer container's UTS namespace. Required alongside `pidns=host` because when PID is shared, setting a new hostname (`sethostname`) in a user namespace also fails.
   - `netns = "host"` — inner containers share the outer container's network namespace. **Critical for proxy access** — see the Networking section below.
   - `runtime = "crun"` — use crun (lighter than runc, handles this namespace configuration better)

4. Writes `storage.conf` to use `fuse-overlayfs` as the overlay storage driver (required for overlay-on-overlay since the outer container itself uses overlayfs, and kernel overlay-in-kernel-overlay is blocked).

5. Pre-creates `$RUNTIME_DIR/podman/` — `podman system service` will fail silently with "no such file or directory" if this directory does not exist.

6. Starts `podman system service --time=0 unix://$SOCKET` — the Docker-compatible REST API. This lets standard Docker tooling (`docker` CLI, testcontainers) communicate with Podman as if it were Docker.

7. Sets `DOCKER_HOST`, `TESTCONTAINERS_RYUK_DISABLED=true`, `XDG_RUNTIME_DIR` in the environment and in `/etc/environment` (so `docker exec` sessions inherit them).

### Network flow for inner containers

With `netns = "host"`, inner containers share the outer container's network namespace. This means:

```
Inner container process
  → loopback connection to localhost:3128
  → Squid (running on outer container's loopback, port 3128)
  → Squid checks domain allowlist
  → outbound TCP as UID "proxy" (allowed by iptables)
  → internet
```

**Why `netns = "host"` is necessary:**
Podman's default network backend for rootless containers is `pasta` (from the `passt` package). pasta creates a virtual tap interface in the inner container and tunnels traffic to the outer container's network namespace. However, pasta does **not** forward the inner container's loopback traffic to the outer container's loopback. When the inner container has `http_proxy=http://localhost:3128`, `localhost` means the *inner* container's loopback — where nothing is listening. With `netns = "host"`, the inner container shares the outer container's actual loopback, where Squid is running.

**Security properties with `netns = "host"`:**
- Inner container processes are seen by iptables with their remapped UIDs (100000+ due to user namespace mapping). These UIDs are not in any iptables allow rule for direct outbound.
- The loopback rule (`-o lo -j ACCEPT`) applies to all UIDs, so inner containers can reach Squid at `127.0.0.1:3128`.
- All other outbound TCP from inner containers is REJECT'd — same as for devuser itself.
- Inner containers therefore have exactly the same egress policy as the agent: proxy-only, domain-filtered.

**Known limitation — inner containers cannot have isolated networks:**
`netns = "host"` means all inner containers share the outer container's single network namespace. Inner containers cannot be put on separate bridge networks and cannot communicate with each other via container IPs (they all share the same network stack). For most testcontainer and single-image use cases this is fine, but it would break use cases that rely on multi-container networking (e.g., a docker-compose stack where containers communicate via service names). See the "Possible improvements" section.

### Storage

Podman uses `fuse-overlayfs` (via `mount_program`) instead of the kernel's overlay driver. This is required because:
- The outer container's rootfs is already an overlay filesystem
- Kernel overlay-within-kernel-overlay is blocked on most kernels
- `fuse-overlayfs` runs in userspace, bypassing this restriction
- Performance is somewhat lower than native overlayfs but acceptable for CI workloads

Container images pulled by Podman are stored under `/home/devuser/.local/share/containers/storage/`. Since `/home/devuser` is the `claude-state-home` Docker named volume, images persist across sandbox restarts, which avoids re-pulling on every run.

### Docker CLI compatibility

`podman-docker` (installed in the image) provides `/usr/bin/docker` as a shim that delegates to `podman`. Combined with `DOCKER_HOST` pointing to the Podman API socket, standard `docker` commands work transparently. This covers most testcontainers use cases since testcontainers uses the Docker CLI or Docker socket, not Podman directly.

`TESTCONTAINERS_RYUK_DISABLED=true` is required because Ryuk (testcontainers' resource reaper daemon) attempts to connect to the Docker socket and manage container lifecycle in a way that is incompatible with Podman's REST API. Since the sandbox is fully ephemeral anyway (it is removed when the agent session ends), Ryuk's cleanup function is unnecessary.

### Firewall domain allowlist additions

When `ENABLE_DOCKER=true`, `init-firewall.sh` adds these container registry domains to Squid's allowlist:

```
.docker.io
.docker.com
.production.cloudflare.docker.com
.ghcr.io
.gcr.io
.quay.io
.registry.k8s.io
```

**Note:** Docker has recently begun serving image layer blobs from `*.r2.cloudflarestorage.com` (Cloudflare R2). This domain is **not** currently in the allowlist. Attempting to pull a Docker Hub image directly (not via a cached layer) will fail with a 403 from Squid. The workaround is to add `.r2.cloudflarestorage.com` to the project's `.sandbox-domains` file or to the default list in `init-firewall.sh`. See "Possible improvements" below.

---

## Limitations and known issues

### 1. Inner containers cannot have isolated bridge networks

All inner containers share `netns = "host"` (the outer container's network namespace). Podman's default bridge network mode is disabled. Consequences:
- Containers cannot communicate with each other via container-assigned IPs or DNS hostnames
- `docker-compose` service discovery (e.g., `mysql:3306`) will not work unless the compose file uses `network_mode: host`
- Port conflicts are possible if two inner containers try to bind the same port

**Workaround for testcontainers:** Most testcontainers use cases launch a single container and connect from the test process — this works fine with host networking. The test process and the testcontainer share the same network namespace, so `localhost:<mapped-port>` works as expected.

**Workaround for multi-container:** Use `network_mode: host` in `docker-compose.yml` and reference services via `localhost`. Not always possible with third-party compose files.

### 2. `sethostname` is not possible in inner containers

With `utsns = "host"`, inner containers cannot set their own hostname. This is rarely a problem in practice but some containers (particularly those that use the hostname for configuration) may behave unexpectedly.

### 3. `/proc` limitations

With `pidns = "host"`, inner containers see the outer container's full process list in `/proc`. There is no PID namespace isolation — a process inside an inner container can see (and potentially signal) all other processes in the outer container. This is a security trade-off made necessary by the kernel's restriction on mounting proc in nested PID namespaces.

### 4. Docker Hub blob downloads may fail

As noted above, Docker Hub routes image layer downloads through `r2.cloudflarestorage.com` which is not in the default allowlist. Images not already cached in the Podman image store will fail to pull. The image store persists in the `claude-state-home` volume, so images pulled once remain available.

### 5. `podman system service` socket directory must be pre-created

`podman system service unix:///path/to/sock` fails silently if the parent directory does not exist. The entrypoint pre-creates `$RUNTIME_DIR/podman/` to avoid this. If the entrypoint is bypassed (e.g., in tests using `--entrypoint bash`), this directory must be created manually.

---

## Possible improvements

### A. Re-enable inner container network isolation

The root cause of `netns = "host"` is that pasta's loopback forwarding does not work in this environment (inner container's `localhost` is isolated from the outer container's `localhost`). Two approaches could restore isolation while keeping proxy access:

**Option A1: Configure pasta to forward port 3128**
Podman supports `-p 3128:3128` style configuration in `containers.conf` for pasta port forwarding. If pasta can be configured to forward `127.0.0.1:3128` from the outer to the inner container's loopback, then per-container network namespaces become usable again. This needs further investigation — pasta's loopback forwarding documentation is sparse and the behavior may differ between Podman/pasta versions.

**Option A2: Run a Squid instance accessible via the bridge gateway**
Instead of (or in addition to) `netns = "host"`, start a second Squid instance bound to `0.0.0.0:3128` in the outer container. Then the proxy would be reachable at the bridge gateway IP (e.g., `10.88.0.1:3128`) from containers that have their own network namespace. The `http_proxy` env var would need to be set dynamically to `http://<gateway>:3128` rather than `localhost:3128`. This is more complex but would restore full network isolation between inner containers.

### B. Add `r2.cloudflarestorage.com` to the DinD allowlist

Docker Hub now serves image blobs from this domain. Adding `.r2.cloudflarestorage.com` to the container registry domain list in `init-firewall.sh` would allow fresh image pulls to work without manually seeding the Podman image cache or adding it to `.sandbox-domains`.

Trade-off: `r2.cloudflarestorage.com` is a general Cloudflare R2 CDN domain, not specific to Docker Hub. Allowing it gives inner containers broader access to any content hosted on that CDN.

### C. Separate Docker volume for Podman image storage

Currently the Podman image cache lives in `/home/devuser/.local/share/containers/` which is part of the `claude-state-home` volume (shared with Claude credentials, OpenCode auth, etc.). If the image cache grows large it will compete for space with auth data. A separate `podman-storage` Docker volume could be mounted at `/home/devuser/.local/share/containers/` when `--enable-docker` is active.

### D. Restore PID namespace isolation

`pidns = "host"` was needed because the kernel blocks mounting `/proc` inside a user namespace when the outer container is not in the init PID namespace. Two approaches to restore isolation:

**Option D1: Investigate `--privileged` for the outer container**
With `--privileged`, the outer container is in the init PID namespace context and inner containers can mount `/proc` normally. This comes at the cost of full privilege escalation on the outer container — incompatible with the sandbox's security model.

**Option D2: Newer kernel / Podman version behavior**
This restriction has been the subject of kernel discussions. Future kernel versions may relax it for containers with `CAP_SYS_ADMIN` in a user namespace. Worth retesting on kernel upgrades.

### E. Docker-compose support

Currently `docker-compose` (or `podman compose`) would work for single-container setups but multi-container networking is broken due to `netns = "host"`. If docker-compose support is needed, the network isolation improvement (Option A) should be implemented first.

---

## Relevant files

| File | Role |
|------|------|
| `bin/code-sandbox` | Adds `--cap-add SYS_ADMIN`, `--device /dev/fuse`, `--device /dev/net/tun`, higher limits, and the seccomp profile when `--enable-docker` is used |
| `config/dind-seccomp.json` | Seccomp profile — Docker's default + DinD-specific syscalls |
| `entrypoint.sh` | DinD init block: shared mount, runtime dir, containers.conf, socket startup |
| `init-firewall.sh` | Adds container registry domains to Squid allowlist when `ENABLE_DOCKER=true` |
| `lock-settings.sh` | Overlays `config-dind/` tree on top of base and merges `settings.overrides.json` when `ENABLE_DOCKER=true` |
| `config-dind/.claude/settings.overrides.json` | DinD settings diff — adds docker/podman allow rules, removes docker deny; merged into base `settings.json` at startup |
| `test-sandbox.sh` | DinD test suite (8 checks, run with `--enable-docker`) |
