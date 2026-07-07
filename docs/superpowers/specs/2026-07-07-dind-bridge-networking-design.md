# Bridge networking for Docker-in-Docker (compose service discovery)

**Date:** 2026-07-07
**Status:** Approved
**Files touched:** `bin/code-sandbox`, `lib/sandbox-init.sh`, `entrypoint.sh`, `Dockerfile`, `test-sandbox.sh`, `CLAUDE.md`

## Problem

In `--enable-docker` mode, inner containers share `devuser`'s network namespace
(`netns = "host"` in the generated `containers.conf`). This is load-bearing for
the security model: all inner-container traffic exits as `devuser`, so it is
subject to the same iptables rules and can only reach the internet through Squid
on `localhost:3128`.

The cost of `netns = "host"` is that inner containers **cannot form a bridge
network**. They all share one loopback and one IP, so they cannot be addressed
individually and cannot resolve each other by name. `docker compose` stacks that
rely on service-to-service DNS (app → `postgres`, app → `redis`) therefore fail.

When Podman *does* attempt to stand up a bridge, netavark writes network sysctls
(`net.ipv4.ip_forward`, per-interface `rp_filter`, …). Docker mounts `/proc/sys`
read-only by default in the outer container, so those writes fail with
`Read-only file system` and the bridge never comes up.

## Goal

Let `docker compose` stacks in `--enable-docker` mode resolve and reach each
other **by service name**, without regressing the existing single-container
behaviour or the egress security model.

Scope is deliberately narrow: the containers in these stacks talk **only to each
other** (app + datastores, images already available). They do **not** need
external internet at runtime. Image pulls are unaffected — Podman-the-engine
pulls in the host netns through the existing proxy, so only running-container
runtime traffic is in scope here.

## Design

### Networking model — hybrid (host default, bridge on request)

The container-default netns stays `host`. Standalone `podman run` / `docker run`
containers keep sharing `devuser`'s loopback, keep `http_proxy=localhost:3128`,
and keep external egress through Squid — exactly as today. Nothing on the
common single-container path regresses.

Bridge behaviour appears only when a network is explicitly requested. A
`docker compose up` creates a project network; Podman puts those services on a
**netavark bridge** with **aardvark-dns**, so they resolve each other by service
name. An explicit `--network <name>` overrides the `netns = "host"` *default* in
`containers.conf` (the default applies only when no network is chosen).

Egress for bridged containers needs no new plumbing. Their masqueraded traffic
leaves the rootless netns → pasta → outer netns as `devuser`, which is not on
the iptables allowlist → REJECT. So bridged containers are **externally isolated
by default**, while inter-container traffic and aardvark DNS never leave the
rootless netns. Requirement met; posture preserved.

> **Load-bearing assumption — validate first.** That an explicit compose network
> overrides the `netns = "host"` default is standard Podman behaviour, but it is
> the linchpin of this design. **Implementation step 1 is an empirical check:**
> `--enable-docker`, bring up a two-service compose stack, confirm the services
> land on a bridge and resolve each other by name — *not* on host netns. If this
> assumption were false, we would be pushed into re-plumbing the proxy for every
> container (out of scope here) and must stop and re-design.

### Mechanism — writable `/proc/sys/net`, nothing else (M1)

Two moving parts.

**1. `bin/code-sandbox` (DinD branch only).** Add to the DinD `DOCKER_ARGS`
block (alongside the existing SYS_ADMIN / seccomp / apparmor lines):

```
--security-opt "systempaths=unconfined"
```

This removes Docker's read-only bind over `/proc/sys` so netavark can write the
`net.*` sysctls the bridge needs.

**2. `entrypoint.sh` (DinD path, as root, before `setup_rootless_podman`).**
`systempaths=unconfined` also drops *every other* `/proc` protection, so we
immediately re-apply them, ending in a state where **only `/proc/sys/net` is
writable**:

- Re-mask Docker's default `maskedPaths` (`/proc/kcore`, `/proc/keys`,
  `/proc/sysrq-trigger`, `/proc/latency_stats`, `/proc/sched_debug`,
  `/sys/firmware`, …): bind `/dev/null` over files, a read-only tmpfs over
  directories — mirroring what runc does.
- Re-apply read-only to the other default `readonlyPaths` (`/proc/bus`,
  `/proc/fs`, `/proc/irq`).
- Re-apply read-only to `/proc/sys` as a whole, then **punch `/proc/sys/net`
  back to read-write**:
  `mount --bind /proc/sys/net /proc/sys/net` →
  `mount -o remount,bind,rw /proc/sys/net`.
  This keeps `/proc/sys/kernel`, `/proc/sys/vm`, etc. protected — important,
  because in this non-userns container those map to *host* kernel params.

The re-masks are applied by root at startup, before privileges are dropped. The
agent then runs as `devuser` with no `CAP_SYS_ADMIN`, so it cannot unwind them.
This is a lightly weaker form of Docker's kernel-locked mounts, but sufficient
against an unprivileged `devuser`.

**Net security delta:** confined to `--enable-docker` (which already grants
SYS_ADMIN + a custom seccomp profile). The realistic residual exposure is
`/proc/sys/net` being writable by root and the re-masks not being kernel-locked
— both acceptable within the DinD trust boundary, and both covered by tests.

### File-level changes

- **`bin/code-sandbox`** — add `--security-opt "systempaths=unconfined"` to the
  DinD `DOCKER_ARGS` branch (~line 274–284).
- **`lib/sandbox-init.sh`** — add a namespaced function
  `sandbox::reharden_proc_paths` encapsulating the re-masking above. The default
  masked/readonly path lists live here as arrays with a comment noting they
  mirror runc's defaults (re-check on base-image bumps). In
  `setup_rootless_podman`, add `network_backend = "netavark"` under `[engine]`
  in the generated `containers.conf`, making the backend explicit rather than
  relying on the image default. `netns = "host"` stays as-is.
- **`entrypoint.sh`** — call `sandbox::reharden_proc_paths` as the *first* step
  inside the `ENABLE_DOCKER=true` branch, before `setup_rootless_podman` (the
  rootless netns is created during setup, so proc state must be correct first).
- **`Dockerfile`** — verify `netavark` and `aardvark-dns` are installed; add
  `aardvark-dns` explicitly if it is not a dependency of the `podman` package on
  Ubuntu 26.04. Name resolution silently degrades without aardvark-dns, so this
  is pinned explicitly.

### Tests (`test-sandbox.sh`, `--enable-docker` path only)

Two security-regression, two functional:

- **Re-hardening held (security):** `/proc/sys/kernel/hostname` (or
  `/proc/sysrq-trigger`) is **not** writable, and `/proc/kcore` is still masked.
- **`/proc/sys/net` writable (enabler):** a `net.*` sysctl is writable.
- **Inter-container DNS (functional):** a minimal two-service compose stack comes
  up; service A resolves and reaches service B by name.
- **Bridged egress still blocked (security):** from inside a bridged container,
  an external fetch fails.

Gated to the existing `--enable-docker` test path.

### Documentation

- **`CLAUDE.md`** — update the Docker-in-Docker section: document the hybrid
  model (host-netns default; compose stacks get an egress-isolated netavark
  bridge with aardvark-dns), and add `systempaths=unconfined` + the re-hardening
  step to the "Security model" bullets with the honest trade-off note (writable
  `/proc/sys/net`, re-masks not kernel-locked, DinD-only).
- Mirror the one-liner into the `config-dind` docs where the DinD settings diff
  is described.

## Non-goals

- No external egress for bridged containers (scope B). They stay isolated by
  default; a compose service needing the internet at runtime is out of scope and
  would require re-plumbing the proxy onto a routable address.
- No change to the non-Docker sandbox, the firewall rules, or the permission
  settings.
- No change to the container-default netns (`host` stays default).

## Verification

- Implementation step 1 (the load-bearing assumption check) passes: compose
  services land on a bridge and resolve each other by name.
- `test-sandbox.sh --enable-docker` passes, including the four new checks.
- `test-sandbox.sh` (no Docker) still passes unchanged.
- Manual: bring up a real app + Postgres compose stack; app connects to
  `postgres` by name; the same app cannot reach an external host.
