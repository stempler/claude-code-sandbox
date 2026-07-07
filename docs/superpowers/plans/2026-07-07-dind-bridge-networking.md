# DinD Bridge Networking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `docker compose` stacks in `--enable-docker` mode resolve and reach each other by service name, without regressing the single-container path or the egress security model.

**Architecture:** Keep `netns = "host"` as the container default (standalone containers keep the `localhost:3128` proxy path). Bridge behaviour appears only when a network is explicitly requested (compose): those containers land on a netavark bridge with aardvark-dns and are egress-isolated for free (masqueraded traffic exits as `devuser` → iptables REJECT). The one enabling change is making `/proc/sys/net` writable in DinD mode so netavark can configure the bridge — done via `--security-opt systempaths=unconfined` plus a startup step that re-masks every other `/proc` path, leaving only `/proc/sys/net` writable.

**Tech Stack:** Bash, Docker (outer container), rootless Podman + netavark + aardvark-dns (inner), iptables/Squid egress firewall.

## Global Constraints

- All changes are gated to `--enable-docker` (DinD) mode. The non-Docker sandbox, firewall rules, and permission settings must not change.
- The container-default netns stays `host`. Do not change the `netns = "host"` line in `containers.conf`.
- New dependencies use their latest releases (per repo convention); `netavark`/`aardvark-dns` come from the Ubuntu 26.04 `apt` repo.
- Bridged containers must have **no external egress** (scope: inter-container only). Any test proving external reachability from a bridged container is a failure.
- Conventional Commits. Branch `feat/dind-bridge-networking` carries no JIRA ref, so no footer.
- The DinD test suite is run with `bash test-sandbox.sh --enable-docker`. It rebuilds the image at the start (step 1 of the suite builds via `--entrypoint true`), so edits to `lib/sandbox-init.sh` (copied into the image) take effect on the next full run.

---

### Task 1: M1 mechanism — writable `/proc/sys/net`, everything else re-masked

Make `/proc/sys/net` the *only* writable path under `/proc/sys` in DinD mode. `--security-opt systempaths=unconfined` removes Docker's read-only `/proc/sys` bind (so netavark can write `net.*` sysctls) but also unmasks every other protected `/proc` path; a startup function re-applies runc's default masks and read-only paths, then re-opens only `/proc/sys/net`.

**Files:**
- Modify: `bin/code-sandbox` (DinD `DOCKER_ARGS` branch, ~line 274–284)
- Modify: `lib/sandbox-init.sh` (add `sandbox::reharden_proc_paths`)
- Modify: `entrypoint.sh` (DinD branch, ~line 100)
- Test: `test-sandbox.sh` (DinD test block, after `sandbox::write_proxy_environment` ~line 550)

**Interfaces:**
- Produces: `sandbox::reharden_proc_paths()` — a Bash function (no args, no return value) that must be called **as root** and **before** `sandbox::setup_rootless_podman`. After it runs: `/proc/sys/net/*` is writable; `/proc/sys/kernel/*`, `/proc/sys/vm/*`, `/proc/kcore`, `/proc/bus`, `/proc/fs`, `/proc/irq`, `/proc/sysrq-trigger` are not.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests (assertions only, no reharden call yet)**

In `test-sandbox.sh`, in the DinD test block, immediately **after** the line `sandbox::write_proxy_environment` (~line 550) and **before** `sandbox::setup_rootless_podman` (~line 553), insert:

```bash
# ── M1: /proc/sys/net writable, rest of /proc/sys and masked paths not ────
if echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
    echo "TEST_DIND_PROC_SYS_NET_WRITABLE=PASS"
else
    echo "TEST_DIND_PROC_SYS_NET_WRITABLE=FAIL (/proc/sys/net/ipv4/ip_forward not writable)"
fi

CUR_HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo x)
if echo "$CUR_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null; then
    echo "TEST_DIND_PROC_SYS_KERNEL_RO=FAIL (/proc/sys/kernel/hostname writable — host kernel param exposed)"
else
    echo "TEST_DIND_PROC_SYS_KERNEL_RO=PASS"
fi

if [ -s /proc/kcore ]; then
    echo "TEST_DIND_PROC_KCORE_MASKED=FAIL (/proc/kcore not masked)"
else
    echo "TEST_DIND_PROC_KCORE_MASKED=PASS"
fi
```

- [ ] **Step 2: Run tests to verify the net-writable one fails**

Run: `bash test-sandbox.sh --enable-docker 2>&1 | grep -E 'proc sys net writable|proc sys kernel ro|proc kcore masked'`
Expected:
- `FAIL: dind proc sys net writable ...` (Docker still mounts `/proc/sys` read-only — this is the red we want)
- `PASS: dind proc sys kernel ro` (all of `/proc/sys` is read-only by default)
- `PASS: dind proc kcore masked` (Docker masks it by default)

- [ ] **Step 3: Add `systempaths=unconfined` to the DinD launch args**

In `bin/code-sandbox`, in the `if $ENABLE_DOCKER; then` branch (~line 274), add the `--security-opt` line:

```bash
if $ENABLE_DOCKER; then
    DOCKER_ARGS+=(
        -e ENABLE_DOCKER=true
        --pids-limit 512
        --memory 8g
        --security-opt "seccomp=${PROJECT_DIR}/config/dind-seccomp.json"
        --security-opt "apparmor=unconfined"
        --security-opt "systempaths=unconfined"
        --device /dev/fuse
        --device /dev/net/tun
        --cap-add SYS_ADMIN
    )
```

- [ ] **Step 4: Add the `sandbox::reharden_proc_paths` function**

In `lib/sandbox-init.sh`, add this function (place it just before `sandbox::setup_rootless_podman`):

```bash
# ── sandbox::reharden_proc_paths ──────────────────────────────────────────────
# In DinD mode bin/code-sandbox launches with `--security-opt systempaths=unconfined`
# so rootless netavark can write the net.* sysctls a bridge needs. That flag also
# strips every other /proc protection Docker applies by default, so we re-apply
# runc's default maskedPaths + readonlyPaths here and then re-open ONLY
# /proc/sys/net. End state: /proc/sys/net is writable; /proc/sys/kernel,
# /proc/sys/vm, /proc/kcore, /proc/sysrq-trigger, etc. are not.
# Must run as root, before sandbox::setup_rootless_podman.
# NOTE: these lists mirror runc's defaults — re-check on base-image bumps.
sandbox::reharden_proc_paths() {
    local masked=(
        /proc/asound /proc/acpi /proc/kcore /proc/keys
        /proc/latency_stats /proc/timer_list /proc/timer_stats
        /proc/sched_debug /proc/scsi
        /sys/firmware /sys/devices/virtual/powercap
    )
    local readonly_paths=(
        /proc/bus /proc/fs /proc/irq /proc/sysrq-trigger
    )

    local p
    for p in "${masked[@]}"; do
        [ -e "$p" ] || continue
        if [ -d "$p" ]; then
            mount -t tmpfs -o ro,nosuid,nodev,noexec tmpfs "$p" 2>/dev/null || true
        else
            mount --bind /dev/null "$p" 2>/dev/null || true
        fi
    done

    for p in "${readonly_paths[@]}"; do
        [ -e "$p" ] || continue
        mount --bind "$p" "$p" 2>/dev/null || true
        mount -o remount,bind,ro "$p" 2>/dev/null || true
    done

    # Re-protect all of /proc/sys, then punch /proc/sys/net back to read-write —
    # the sole surface netavark writes (net.ipv4.ip_forward, per-iface rp_filter…).
    mount --bind /proc/sys /proc/sys
    mount -o remount,bind,ro /proc/sys
    mount --bind /proc/sys/net /proc/sys/net
    mount -o remount,bind,rw /proc/sys/net
}
```

- [ ] **Step 5: Call the function from `entrypoint.sh` and mirror it in the test harness**

In `entrypoint.sh`, in the DinD block, make it the first step (before `sandbox::setup_rootless_podman`):

```bash
if [ "${ENABLE_DOCKER:-}" = "true" ]; then
    echo "[entrypoint] Initializing Docker-in-Docker (rootless Podman)..."
    sandbox::reharden_proc_paths
    sandbox::setup_rootless_podman
    sandbox::append_dind_environment
```

In `test-sandbox.sh`, the DinD test block bypasses `entrypoint.sh` (it runs `--entrypoint bash`), so mirror the call. Insert `sandbox::reharden_proc_paths` **immediately before** the three assertions added in Step 1 (i.e. right after `sandbox::write_proxy_environment`):

```bash
sandbox::write_proxy_environment

# Mirror entrypoint's DinD init: re-harden /proc before podman setup.
sandbox::reharden_proc_paths

# ── M1: /proc/sys/net writable, rest of /proc/sys and masked paths not ────
```

- [ ] **Step 6: Run tests to verify all three pass**

Run: `bash test-sandbox.sh --enable-docker 2>&1 | grep -E 'proc sys net writable|proc sys kernel ro|proc kcore masked'`
Expected: all three `PASS` (`proc sys net writable`, `proc sys kernel ro`, `proc kcore masked`).

If `proc sys net writable` still FAILs after this step, the `mount --bind /proc/sys/net` + `remount,bind,rw` technique did not take — debug the mount chain (`findmnt /proc/sys/net`) before proceeding; nothing downstream works without it.

- [ ] **Step 7: Commit**

```bash
git add bin/code-sandbox lib/sandbox-init.sh entrypoint.sh test-sandbox.sh
git commit -m "feat: make /proc/sys/net writable in DinD mode for bridge networking

Adds --security-opt systempaths=unconfined (DinD only) plus a startup
re-hardening step that restores runc's default proc masks and leaves only
/proc/sys/net writable, so rootless netavark can configure bridge networks."
```

---

### Task 2: netavark + aardvark-dns backend

Ensure the bridge/DNS backend is present and selected. `--no-install-recommends` in the Dockerfile means netavark/aardvark-dns are not guaranteed, so install them explicitly and pin `network_backend = "netavark"` in the generated `containers.conf`.

**Files:**
- Modify: `Dockerfile:25` (apt install list)
- Modify: `lib/sandbox-init.sh` (`setup_rootless_podman` containers.conf heredoc)
- Test: `test-sandbox.sh` (DinD test block, after the `TEST_DIND_PROXY_ALLOWS` block ~line 626)

**Interfaces:**
- Consumes: `sandbox::reharden_proc_paths` from Task 1 (network creation writes `net.*` sysctls, which requires writable `/proc/sys/net`).
- Produces: a working `podman network create`; `podman info` reports `NetworkBackend=netavark`.

- [ ] **Step 1: Write the failing tests**

In `test-sandbox.sh`, in the DinD block, **after** the `TEST_DIND_PROXY_ALLOWS` block (~line 626), insert:

```bash
# ── Network backend is netavark ───────────────────────────────────────────
BACKEND=$(gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman info --format '{{.Host.NetworkBackend}}'" 2>/dev/null || echo unknown)
if [ "$BACKEND" = "netavark" ]; then
    echo "TEST_DIND_NETWORK_BACKEND=PASS"
else
    echo "TEST_DIND_NETWORK_BACKEND=FAIL (NetworkBackend=$BACKEND, expected netavark)"
fi

# ── aardvark-dns binary present (name resolution depends on it) ────────────
if ls /usr/lib/podman/aardvark-dns /usr/libexec/podman/aardvark-dns /usr/bin/aardvark-dns 2>/dev/null | grep -q .; then
    echo "TEST_DIND_AARDVARK_PRESENT=PASS"
else
    echo "TEST_DIND_AARDVARK_PRESENT=FAIL (aardvark-dns binary not found)"
fi

# ── podman network create succeeds (netavark writes net.* sysctls) ─────────
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman network create sbtest-net0" >/dev/null 2>&1; then
    echo "TEST_DIND_NETWORK_CREATE=PASS"
    gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman network rm sbtest-net0" >/dev/null 2>&1 || true
else
    echo "TEST_DIND_NETWORK_CREATE=FAIL (podman network create failed — check netavark + /proc/sys/net writable)"
fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test-sandbox.sh --enable-docker 2>&1 | grep -E 'dind network backend|dind aardvark present|dind network create'`
Expected: `FAIL` on `dind aardvark present` (and likely `dind network backend` / `dind network create`) because aardvark-dns is not installed and the backend is not pinned.

- [ ] **Step 3: Install netavark + aardvark-dns in the image**

In `Dockerfile`, edit the podman line in the apt install (line 25) to add `netavark aardvark-dns`:

```dockerfile
    podman podman-docker fuse-overlayfs slirp4netns uidmap crun passt netavark aardvark-dns \
```

- [ ] **Step 4: Pin the network backend in containers.conf**

In `lib/sandbox-init.sh`, in `setup_rootless_podman`, add a `[network]` section to the `containers.conf` heredoc. Change the tail of that heredoc from:

```bash
[engine]
runtime = "crun"
CONF
```

to:

```bash
[engine]
runtime = "crun"

[network]
network_backend = "netavark"
CONF
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash test-sandbox.sh --enable-docker 2>&1 | grep -E 'dind network backend|dind aardvark present|dind network create'`
Expected: all three `PASS`.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile lib/sandbox-init.sh test-sandbox.sh
git commit -m "feat: install and select netavark/aardvark-dns backend for DinD"
```

---

### Task 3: Validation gate — inter-container name resolution + egress isolation

The go/no-go for the whole design: prove that two containers on an explicit network resolve and reach each other **by name** (which also proves `--network` overrides the `netns=host` default and that aardvark-dns works), and that such a container **cannot** reach the external internet.

**Files:**
- Test: `test-sandbox.sh` (DinD test block, after the Task 2 network tests)

**Interfaces:**
- Consumes: writable `/proc/sys/net` (Task 1) and the netavark/aardvark-dns backend (Task 2).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the functional tests**

In `test-sandbox.sh`, in the DinD block, **after** the Task 2 network tests, insert:

```bash
# ── Inter-container name resolution + reachability on an explicit network ──
# This is the design's load-bearing check: it proves --network overrides the
# netns=host default AND aardvark-dns resolves container names.
gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman network create sbtest-dns" >/dev/null 2>&1 || true
gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run -d --name sbtest-svcb --network sbtest-dns alpine sleep 60" >/dev/null 2>&1 || true
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm --network sbtest-dns alpine ping -c1 -W3 sbtest-svcb" 2>&1 | grep -q "1 packets received"; then
    echo "TEST_DIND_INTER_CONTAINER_DNS=PASS"
else
    echo "TEST_DIND_INTER_CONTAINER_DNS=FAIL (could not resolve/reach sbtest-svcb by name — bridge or aardvark-dns not working)"
fi

# ── Bridged container has NO external egress (masqueraded → devuser → REJECT) ──
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm --network sbtest-dns alpine wget -q --tries=1 --timeout=5 -O- http://pastebin.com" 2>&1 | grep -qi "html\|doctype"; then
    echo "TEST_DIND_BRIDGE_EGRESS_BLOCKED=FAIL (bridged container reached pastebin.com!)"
else
    echo "TEST_DIND_BRIDGE_EGRESS_BLOCKED=PASS"
fi

# Cleanup
gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman rm -f sbtest-svcb" >/dev/null 2>&1 || true
gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman network rm sbtest-dns" >/dev/null 2>&1 || true
```

- [ ] **Step 2: Run the tests**

Run: `bash test-sandbox.sh --enable-docker 2>&1 | grep -E 'dind inter container dns|dind bridge egress blocked'`
Expected: both `PASS`.

**GO/NO-GO:** If `dind inter container dns` FAILs, the design's load-bearing assumption is false — an explicit `--network` did **not** give the container its own bridged netns (it stayed on host netns, so aardvark never registered the name). **Stop and report** rather than working around it; a fix would mean re-plumbing the proxy for every container (out of scope). If only `dind bridge egress blocked` FAILs, the container reached the internet — a security regression that must be resolved before merge (check that bridged traffic still exits as `devuser` and hits the iptables REJECT).

- [ ] **Step 3: Commit**

```bash
git add test-sandbox.sh
git commit -m "test: verify inter-container DNS and bridge egress isolation in DinD"
```

---

### Task 4: Documentation

Document the hybrid model and the security trade-off in the two places that describe DinD.

**Files:**
- Modify: `CLAUDE.md` (Docker-in-Docker Mode section, and the `lib/sandbox-init.sh`/entrypoint prose)

**Interfaces:** none.

- [ ] **Step 1: Update the DinD section of `CLAUDE.md`**

In `CLAUDE.md`, in the "Docker-in-Docker Mode (`--enable-docker`)" section, under "**What it does:**", add a bullet:

```markdown
- Enables **bridge networking** for inner containers: `docker compose` stacks get
  their own netavark network with aardvark-dns, so services resolve each other by
  name. Standalone containers still default to host netns (keeping the
  `localhost:3128` proxy path).
```

Under "**Security model unchanged:**", replace the seccomp bullet with an expanded version that records the new trade-off:

```markdown
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
```

- [ ] **Step 2: Update the Key Files / lock-settings notes for the new function**

In `CLAUDE.md`, in the `lib/sandbox-init.sh`-related prose (the DinD/entrypoint description), add a sentence noting `sandbox::reharden_proc_paths` runs first in the DinD branch of `entrypoint.sh`, before `setup_rootless_podman`. Keep it to one line consistent with the surrounding style.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document DinD bridge networking and /proc re-hardening"
```

---

## Verification (whole plan)

- `bash test-sandbox.sh --enable-docker` passes, including the new checks:
  `dind proc sys net writable`, `dind proc sys kernel ro`, `dind proc kcore masked`,
  `dind network backend`, `dind aardvark present`, `dind network create`,
  `dind inter container dns`, `dind bridge egress blocked`.
- `bash test-sandbox.sh` (no Docker) still passes unchanged.
- Manual: `bin/code-sandbox --enable-docker -- bash`, bring up a real app + Postgres
  compose stack; the app connects to `postgres` by name; the same app cannot reach
  an external host.
