# Squid Proxy Firewall Design

**Date:** 2026-04-01  
**Status:** Approved  
**Topic:** Replace iptables-only egress firewall with Squid proxy + iptables backstop

## Problem

The current `init-firewall.sh` resolves domain IPs with `dig` at container startup and bakes them into iptables rules. This causes two problems:

1. **IP rotation** — CDN-backed services (PyPI, npm, GitHub) rotate IPs. Connections break mid-session when an IP that was resolved at startup is no longer valid.
2. **Narrow default allowlist** — Most useful destinations (PyPI, npm, search engines) are commented out. Users must edit the script and rebuild the image to add them.

## Solution

Run a Squid forward proxy inside the container. iptables forces all outbound TCP through Squid (by blocking direct outbound from non-proxy UIDs). Squid filters by hostname — no IP resolution needed, no rotation issues.

## Architecture

```
devuser (Claude Code)
    │  http_proxy=http://localhost:3128
    ▼
Squid (:3128)  ←── domain ACL (generated from env vars at startup)
    │  allowed? → forward
    │  denied?  → 403
    ▼
iptables OUTPUT (default REJECT)
    ├── proxy UID  → ACCEPT  (only squid can exit the container)
    ├── lo         → ACCEPT
    ├── DNS        → ACCEPT (UDP/TCP :53 to resolv.conf nameservers)
    ├── Anthropic CIDR 160.79.104.0/23 :443 → ACCEPT (direct, stable range)
    └── * UDP      → DROP   (prevents DNS tunneling)
```

**Key properties:**
- devuser cannot make direct TCP connections — iptables blocks any packet not from the `proxy` UID
- Squid filters HTTPS by SNI hostname from the `CONNECT` request — no MITM cert, traffic is never decrypted
- All outbound connections are logged by Squid's access log
- The Anthropic API CIDR bypasses Squid directly (stable published range, no proxy overhead needed)

## Domain Policy

Domain filtering is controlled by two environment variables evaluated at startup when `squid.conf` is generated:

| Variable | Behavior |
|---|---|
| `EXTRA_ALLOWED_DOMAINS` | Appended to the default allowlist (common case) |
| `ALLOWED_DOMAINS` | Replaces the default allowlist entirely |
| `ALLOW_ALL_HTTPS=true` | Disables domain filtering; Squid becomes a pure logging proxy |

`ALLOW_ALL_HTTPS=true` is appropriate when Claude needs unrestricted `WebFetch`. The iptables backstop still blocks raw TCP/UDP exfiltration even in this mode.

### Default Allowlist

| Category | Domains |
|---|---|
| Anthropic / Claude | `.anthropic.com`, `.claude.ai` |
| GitHub | `.github.com`, `.githubusercontent.com`, `.githubassets.com` |
| PyPI | `.pypi.org`, `.pythonhosted.org` |
| npm | `.npmjs.org`, `.npmjs.com` |
| Rust / Cargo | `.crates.io`, `.rust-lang.org` |
| Go modules | `proxy.golang.org`, `sum.golang.org`, `pkg.go.dev` |
| Search & web | `.google.com`, `.bing.com`, `.duckduckgo.com`, `.wikipedia.org` |
| Dev docs | `.stackoverflow.com`, `.readthedocs.io`, `.docs.rs`, `.developer.mozilla.org` |
| Common CDNs | `.cloudflare.com`, `.fastly.net` |

## Implementation Changes

### `Dockerfile`
- Add `squid` to the `apt-get install` line.

### `init-firewall.sh` (rewritten)
1. Generate `/etc/squid/squid.conf` from the domain list (default + `EXTRA_ALLOWED_DOMAINS` / `ALLOWED_DOMAINS` / `ALLOW_ALL_HTTPS`)
2. Start Squid and wait for it to be ready
3. Set iptables rules:
   - Allow loopback
   - Allow established/related
   - Allow DNS (from resolv.conf nameservers)
   - Allow Anthropic CIDR `160.79.104.0/23` on TCP 443 (direct)
   - Allow outbound from `proxy` UID (Squid's worker UID)
   - Drop all UDP
   - Reject everything else
4. Exit cleanly so `entrypoint.sh` can export proxy env vars before the gosu exec

### `entrypoint.sh`
- After calling `init-firewall.sh`, export `http_proxy=http://localhost:3128` and `https_proxy=http://localhost:3128` into the current environment. gosu inherits the calling process's environment, so these propagate to devuser automatically. `/etc/environment` is not used — gosu does not source it.

#### Squid readiness check
After starting Squid, `init-firewall.sh` must wait until the proxy port is accepting connections before setting iptables rules. Use a polling loop:
```bash
for i in $(seq 1 20); do
    nc -z localhost 3128 2>/dev/null && break
    sleep 0.5
done
```
If Squid is not ready after 10 seconds, log an error and exit non-zero (entrypoint treats non-zero from init scripts as fatal).

### `test-sandbox.sh`
- Remove IP-rotation-sensitive `dig`-based firewall checks
- Add proxy-connectivity checks:
  - `curl --proxy localhost:3128 https://pypi.org` → succeeds
  - `curl --proxy localhost:3128 https://blocked-domain.example` → returns 403
  - Direct connection attempt (bypassing proxy) → blocked by iptables

## Files Changed

| File | Change |
|---|---|
| `Dockerfile` | Add `squid` to apt install |
| `init-firewall.sh` | Rewrite: generate squid.conf, start Squid, new iptables rules |
| `test-sandbox.sh` | Update firewall tests for proxy-based assertions |

## What Is Not Changing

- `entrypoint.sh` — startup order and privilege drop are unchanged
- `lock-settings.sh` — settings locking is unchanged
- `settings-profiles/` — permission profiles are unchanged
- The four-layer security model (permissions, firewall, non-root, container isolation) — this design strengthens layer 2, the others are untouched

## Security Properties Preserved

- No raw TCP/UDP exfiltration possible — iptables blocks non-proxy-UID outbound
- No DNS tunneling — UDP is dropped except to resolv.conf nameservers
- No IP rotation fragility — Squid resolves hostnames at connection time
- Audit trail — Squid access log records every outbound request
- Defense in depth — proxy policy + iptables backstop are independent controls
