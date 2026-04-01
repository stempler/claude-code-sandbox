# Squid Proxy Firewall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iptables IP-resolution-based firewall with a Squid forward proxy + iptables backstop, eliminating IP rotation issues and broadening the default domain allowlist.

**Architecture:** Squid listens on localhost:3128 and enforces a domain ACL for all outbound HTTP/HTTPS. iptables default-deny blocks all outbound TCP except from the `proxy` UID (Squid workers) and `root` (init scripts), plus the stable Anthropic CIDR. devuser's `http_proxy`/`https_proxy` env vars (exported by entrypoint.sh) route all agent traffic through Squid automatically.

**Tech Stack:** bash, iptables (xt_owner module), Squid 5.x (Ubuntu package), Docker

**Spec:** `docs/superpowers/specs/2026-04-01-squid-proxy-firewall-design.md`

---

## File Map

| File | Change |
|---|---|
| `Dockerfile` | Add `squid` to apt-get install |
| `init-firewall.sh` | Full rewrite — generate squid.conf, start Squid, new iptables rules |
| `entrypoint.sh` | Export `http_proxy`/`https_proxy` after firewall init |
| `test-sandbox.sh` | Update firewall tests: proxy-based assertions replace IP-resolution tests |

---

## Task 1: Add squid to Dockerfile

**Files:**
- Modify: `Dockerfile:18-23`

- [ ] **Step 1: Add squid to the apt-get install line**

In `Dockerfile`, find the `apt-get install` block and add `squid`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates gnupg gosu \
    iptables iproute2 dnsutils \
    squid \
    python3 python3-pip python3-venv \
    build-essential \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Verify the image builds with squid available**

```bash
docker build -t claude-code-sandbox . 2>&1 | tail -5
docker run --rm claude-code-sandbox squid -v
```

Expected: build succeeds; `squid -v` prints a version line containing `Squid Cache`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "build: add squid to sandbox image"
```

---

## Task 2: Update test-sandbox.sh with new firewall tests

Write the updated tests first (TDD). They will fail until Tasks 3 and 4 are complete.

**Files:**
- Modify: `test-sandbox.sh:193-264`

- [ ] **Step 1: Replace the firewall test block in test-sandbox.sh**

Find the block between `# ── Firewall: read self-verification results` (line 193) and `# ── Privilege escalation: devuser cannot run sudo` (line 246) and replace it with:

```bash
# ── Firewall: read self-verification results ─────────────────────────────
FW_VERIFY="/run/firewall-verify"

if [ -f "$FW_VERIFY" ]; then
    FW_POLICY=$(grep "^OUTPUT_POLICY=" "$FW_VERIFY" | cut -d= -f2)
    if [ "$FW_POLICY" = "DROP" ]; then
        echo "TEST_FW_DEFAULT_DROP=PASS"
    else
        echo "TEST_FW_DEFAULT_DROP=FAIL (policy=$FW_POLICY)"
    fi
else
    echo "TEST_FW_DEFAULT_DROP=FAIL (no verification file)"
fi

if [ -f "$FW_VERIFY" ]; then
    FW_UDP=$(grep "^UDP_DROP=" "$FW_VERIFY" | cut -d= -f2)
    if [ "$FW_UDP" = "yes" ]; then
        echo "TEST_FW_UDP_DROP=PASS"
    else
        echo "TEST_FW_UDP_DROP=FAIL (no UDP DROP rule found)"
    fi
else
    echo "TEST_FW_UDP_DROP=FAIL (no verification file)"
fi

# ── Firewall: Squid proxy is running ─────────────────────────────────────
if [ -f "$FW_VERIFY" ]; then
    SQUID_RUNNING=$(grep "^SQUID_RUNNING=" "$FW_VERIFY" | cut -d= -f2)
    if [ "$SQUID_RUNNING" = "yes" ]; then
        echo "TEST_FW_SQUID_RUNNING=PASS"
    else
        echo "TEST_FW_SQUID_RUNNING=FAIL (Squid not running after firewall init)"
    fi
else
    echo "TEST_FW_SQUID_RUNNING=FAIL (no verification file)"
fi

# ── Firewall: devuser cannot bypass proxy with direct TCP ─────────────────
if timeout 3 gosu devuser bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
    echo "TEST_FW_BLOCK_DIRECT_BYPASS=FAIL (devuser connected to 1.1.1.1:443 directly!)"
else
    echo "TEST_FW_BLOCK_DIRECT_BYPASS=PASS"
fi

# ── Firewall: devuser cannot reach external DNS directly ──────────────────
if timeout 3 gosu devuser bash -c "echo > /dev/tcp/8.8.8.8/53" 2>/dev/null; then
    echo "TEST_FW_BLOCK_DNS_BYPASS=FAIL (devuser connected to 8.8.8.8:53!)"
else
    echo "TEST_FW_BLOCK_DNS_BYPASS=PASS"
fi

# ── Firewall: proxy allows an allowlisted domain ──────────────────────────
HTTP_CODE=$(curl --proxy http://localhost:3128 -s -o /dev/null -w "%{http_code}" \
    --max-time 10 https://pypi.org 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ] && [ "$HTTP_CODE" != "503" ]; then
    echo "TEST_FW_PROXY_ALLOW=PASS"
else
    echo "TEST_FW_PROXY_ALLOW=FAIL (HTTP $HTTP_CODE reaching pypi.org via proxy)"
fi

# ── Firewall: proxy blocks a non-allowlisted domain ──────────────────────
HTTP_CODE=$(curl --proxy http://localhost:3128 -s -o /dev/null -w "%{http_code}" \
    --max-time 5 https://pastebin.com 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "403" ]; then
    echo "TEST_FW_PROXY_DENY=PASS"
else
    echo "TEST_FW_PROXY_DENY=FAIL (HTTP $HTTP_CODE for pastebin.com, expected 403)"
fi

# ── Firewall: Anthropic API reachable via proxy ───────────────────────────
HTTP_CODE=$(curl --proxy http://localhost:3128 -s -o /dev/null -w "%{http_code}" \
    --max-time 10 https://api.anthropic.com 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ]; then
    echo "TEST_FW_ALLOW_ANTHROPIC=PASS"
else
    echo "TEST_FW_ALLOW_ANTHROPIC=FAIL (could not reach api.anthropic.com via proxy)"
fi
```

- [ ] **Step 2: Remove the now-replaced TEST_CURL_BLOCKED test**

Find and remove the `# ── Network tools: curl blocked` block (around line 259-264):

```bash
# ── Network tools: curl blocked ──────────────────────────────────────────
if curl --max-time 3 https://example.com 2>/dev/null; then
    echo "TEST_CURL_BLOCKED=FAIL (curl succeeded!)"
else
    echo "TEST_CURL_BLOCKED=PASS"
fi
```

This test is removed because root outbound is now intentionally allowed (root handles init). The proxy deny test above covers the equivalent security property for devuser.

- [ ] **Step 3: Commit**

```bash
git add test-sandbox.sh
git commit -m "test: update firewall tests for Squid proxy model"
```

---

## Task 3: Rewrite init-firewall.sh

**Files:**
- Modify: `init-firewall.sh` (full rewrite)

- [ ] **Step 1: Replace init-firewall.sh with the new implementation**

Replace the entire file with:

```bash
#!/bin/bash
###############################################################################
# init-firewall.sh — Squid proxy + iptables backstop egress firewall
#
# Architecture:
#   devuser → http_proxy=localhost:3128 → Squid (domain ACL) → internet
#   iptables: default-deny; only proxy UID and root exit directly
#
# Environment variables:
#   ALLOWED_DOMAINS       — space-separated list; replaces the default allowlist
#   EXTRA_ALLOWED_DOMAINS — space-separated list; appended to the default allowlist
#   ALLOW_ALL_HTTPS       — set to "true" to disable domain filtering entirely
###############################################################################

set -euo pipefail

echo "[firewall] Initializing egress firewall..."

# Verify iptables is functional before proceeding
if ! iptables -L OUTPUT -n > /dev/null 2>&1; then
    echo "[firewall] ERROR: iptables is not functional."
    echo "[firewall] This usually means the iptable_filter kernel module is not loaded,"
    echo "[firewall] or the container lacks NET_ADMIN capability."
    echo "[firewall] The container will NOT have network restrictions!"
    exit 1
fi

###############################################################################
# Default domain allowlist
###############################################################################

DEFAULT_DOMAINS=(
    # Anthropic / Claude
    .anthropic.com
    .claude.ai
    # GitHub
    .github.com
    .githubusercontent.com
    .githubassets.com
    # PyPI
    .pypi.org
    .pythonhosted.org
    # npm
    .npmjs.org
    .npmjs.com
    # Rust / Cargo
    .crates.io
    .rust-lang.org
    # Go modules
    proxy.golang.org
    sum.golang.org
    pkg.go.dev
    # Search & web browsing
    .google.com
    .bing.com
    .duckduckgo.com
    .wikipedia.org
    # Dev docs
    .stackoverflow.com
    .readthedocs.io
    .docs.rs
    .developer.mozilla.org
    # Common CDNs
    .cloudflare.com
    .fastly.net
)

###############################################################################
# Generate squid.conf
###############################################################################

SQUID_CONF=/etc/squid/squid.conf

# Build the domain list from env vars or defaults
if [ -n "${ALLOWED_DOMAINS:-}" ]; then
    # shellcheck disable=SC2206
    DOMAIN_LIST=($ALLOWED_DOMAINS)
else
    DOMAIN_LIST=("${DEFAULT_DOMAINS[@]}")
    if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
        # shellcheck disable=SC2206
        DOMAIN_LIST+=($EXTRA_ALLOWED_DOMAINS)
    fi
fi

{
    echo "http_port 3128"
    echo ""
    echo "# Disable disk cache — this is a security proxy, not a caching proxy"
    echo "cache_dir null /tmp"
    echo "cache deny all"
    echo ""
    echo "# Log all requests for auditability"
    echo "access_log /var/log/squid/access.log squid"
    echo ""

    if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
        echo "# ALLOW_ALL_HTTPS=true: domain filtering disabled, proxy acts as audit logger"
        echo "http_access allow all"
    else
        echo "# Domain allowlist — .domain matches the domain itself and all subdomains"
        for domain in "${DOMAIN_LIST[@]}"; do
            echo "acl allowed_domains dstdomain $domain"
        done
        echo ""
        echo "acl CONNECT method CONNECT"
        echo "http_access allow CONNECT allowed_domains"
        echo "http_access allow allowed_domains"
        echo "http_access deny all"
    fi
} > "$SQUID_CONF"

echo "[firewall] Generated $SQUID_CONF"
if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
    echo "[firewall]   Mode: ALLOW ALL HTTPS (audit logging only)"
else
    echo "[firewall]   Mode: domain allowlist (${#DOMAIN_LIST[@]} entries)"
fi

###############################################################################
# Start Squid
###############################################################################

echo "[firewall] Starting Squid..."
squid -f "$SQUID_CONF"

# Wait for Squid to accept connections (poll /dev/tcp, up to 10 seconds)
READY=false
for i in $(seq 1 20); do
    if (echo > /dev/tcp/localhost/3128) 2>/dev/null; then
        READY=true
        break
    fi
    sleep 0.5
done

if [ "$READY" != "true" ]; then
    echo "[firewall] ERROR: Squid did not start within 10 seconds."
    exit 1
fi
echo "[firewall] Squid ready on :3128"

###############################################################################
# iptables rules
###############################################################################

iptables -F OUTPUT
iptables -F INPUT
iptables -F FORWARD

# Default policies
iptables -P INPUT ACCEPT
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Loopback (also carries devuser → Squid connections via localhost:3128)
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

# Established connections (return traffic for Squid's outbound connections)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS: allow resolv.conf nameservers only (covers Docker embedded DNS and host DNS)
DNS_SERVERS=$(grep -oP '^\s*nameserver\s+\K\S+' /etc/resolv.conf || true)
for dns in $DNS_SERVERS; do
    iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
    echo "[firewall]   Allowed DNS: $dns"
done

# Drop all other UDP — prevents DNS tunneling to external resolvers
iptables -A OUTPUT -p udp -j DROP

# Anthropic API CIDR — direct access (stable published range, no proxy overhead)
# This also serves as a reliability fallback if Squid is unavailable.
iptables -A OUTPUT -d 160.79.104.0/23 -p tcp --dport 443 -j ACCEPT
echo "[firewall]   Allowed direct: Anthropic API CIDR 160.79.104.0/23:443"

# Root — allow direct outbound (needed for entrypoint health checks and init)
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT

# Squid (proxy user, UID 13 on Ubuntu) — allow outbound to forward requests
iptables -A OUTPUT -m owner --uid-owner proxy -j ACCEPT
echo "[firewall]   Allowed direct: root and proxy UIDs (Squid workers)"

# Reject everything else with an immediate ICMP error (no hanging timeouts)
iptables -A OUTPUT -m limit --limit 5/min -j LOG \
    --log-prefix "[FIREWALL-BLOCKED] " --log-level 4
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

###############################################################################
# Self-verify and write results for test-sandbox.sh consumption
###############################################################################

VERIFY_FILE="/run/firewall-verify"
VERIFY_OK=true

OUTPUT_POLICY=$(iptables -L OUTPUT -n | head -1 | grep -o "DROP" || echo "NOT_DROP")
if [ "$OUTPUT_POLICY" != "DROP" ]; then
    echo "[firewall] VERIFY FAILED: OUTPUT policy is $OUTPUT_POLICY, expected DROP"
    VERIFY_OK=false
fi

if ! iptables -L OUTPUT -n | grep -qE "DROP[[:space:]]+17|DROP.*udp"; then
    echo "[firewall] VERIFY FAILED: no UDP DROP rule found"
    VERIFY_OK=false
fi

PROXY_UID=$(id -u proxy 2>/dev/null || echo "13")
if ! iptables -L OUTPUT -n -v | grep -q "owner UID match $PROXY_UID"; then
    echo "[firewall] VERIFY FAILED: no proxy UID allow rule found"
    VERIFY_OK=false
fi

{
    echo "OUTPUT_POLICY=$OUTPUT_POLICY"
    if iptables -L OUTPUT -n | grep -qE "DROP[[:space:]]+17|DROP.*udp"; then
        echo "UDP_DROP=yes"
    else
        echo "UDP_DROP=no"
    fi
    if iptables -L OUTPUT -n -v | grep -q "owner UID match $PROXY_UID"; then
        echo "PROXY_UID_RULE=yes"
    else
        echo "PROXY_UID_RULE=no"
    fi
    if (echo > /dev/tcp/localhost/3128) 2>/dev/null; then
        echo "SQUID_RUNNING=yes"
    else
        echo "SQUID_RUNNING=no"
    fi
} > "$VERIFY_FILE"
chmod 0444 "$VERIFY_FILE"

if [ "$VERIFY_OK" = true ]; then
    echo "[firewall] Active. DEFAULT DENY + Squid proxy on :3128"
    if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
        echo "[firewall]   Domain filtering: DISABLED (ALLOW_ALL_HTTPS=true)"
    else
        echo "[firewall]   Domain filtering: ${#DOMAIN_LIST[@]} entries"
    fi
else
    echo "[firewall] WARNING: Rules were applied but verification found issues."
fi
echo ""
```

- [ ] **Step 2: Verify the script is syntactically valid**

```bash
bash -n init-firewall.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add init-firewall.sh
git commit -m "fix: replace IP-resolution firewall with Squid proxy + iptables backstop"
```

---

## Task 4: Export proxy env vars in entrypoint.sh

**Files:**
- Modify: `entrypoint.sh:90-93`

- [ ] **Step 1: Add proxy env var exports after the firewall init call**

In `entrypoint.sh`, find this block:

```bash
# ── Initialize egress firewall ─────────────────────────────────────────
echo "[entrypoint] Setting up egress firewall..."
/usr/local/bin/init-firewall.sh
```

Replace it with:

```bash
# ── Initialize egress firewall ─────────────────────────────────────────
echo "[entrypoint] Setting up egress firewall..."
/usr/local/bin/init-firewall.sh

# Export proxy env vars so gosu-launched devuser inherits them.
# Both lower and upper case are needed — different tools check different cases.
# no_proxy excludes localhost to prevent a proxy loop (devuser → :3128 → :3128).
export http_proxy=http://localhost:3128
export https_proxy=http://localhost:3128
export HTTP_PROXY=http://localhost:3128
export HTTPS_PROXY=http://localhost:3128
export no_proxy=localhost,127.0.0.1
export NO_PROXY=localhost,127.0.0.1
```

- [ ] **Step 2: Verify the script is syntactically valid**

```bash
bash -n entrypoint.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add entrypoint.sh
git commit -m "fix: export http_proxy env vars for devuser after firewall init"
```

---

## Task 5: Run tests and verify everything passes

- [ ] **Step 1: Run the full test suite**

```bash
bash test-sandbox.sh
```

Expected output summary: all tests pass, including:
- `fw squid running` — PASS
- `fw block direct bypass` — PASS
- `fw block dns bypass` — PASS
- `fw proxy allow` — PASS
- `fw proxy deny` — PASS
- `fw allow anthropic` — PASS
- `fw default drop` — PASS
- `fw udp drop` — PASS

- [ ] **Step 2: If TEST_FW_PROXY_ALLOW fails**

Squid may not be proxying HTTPS CONNECT correctly. Check the Squid access log inside the container:

```bash
bin/claude-sandbox --no-build --entrypoint bash -- -c '
/usr/local/bin/init-firewall.sh > /dev/null 2>&1
curl --proxy http://localhost:3128 -v https://pypi.org 2>&1 | head -30
cat /var/log/squid/access.log
'
```

The curl `-v` output should show `CONNECT pypi.org:443` being sent to the proxy. If it shows `Connection refused`, Squid didn't start.

- [ ] **Step 3: If TEST_FW_PROXY_DENY fails (returns 200 instead of 403)**

The domain ACL is not blocking. Inspect the generated squid.conf:

```bash
bin/claude-sandbox --no-build --entrypoint bash -- -c '
/usr/local/bin/init-firewall.sh > /dev/null 2>&1
cat /etc/squid/squid.conf
curl --proxy http://localhost:3128 -v https://pastebin.com 2>&1 | head -20
'
```

Verify `pastebin.com` is NOT listed in the generated squid.conf and that `http_access deny all` appears at the end.

- [ ] **Step 4: If TEST_FW_BLOCK_DIRECT_BYPASS fails (devuser can reach 1.1.1.1:443 directly)**

The `--uid-owner proxy` iptables rule may not be working (xt_owner module missing). Check:

```bash
bin/claude-sandbox --no-build --entrypoint bash -- -c '
/usr/local/bin/init-firewall.sh > /dev/null 2>&1
iptables -L OUTPUT -n -v
lsmod | grep xt_owner
'
```

If `xt_owner` module is missing, the container may need `--cap-add NET_ADMIN` (already present in `bin/claude-sandbox`) plus the module loaded on the host. This is a host kernel issue.

- [ ] **Step 5: Verify proxy env vars reach devuser**

```bash
bin/claude-sandbox --no-build -- bash -c 'echo "http_proxy=$http_proxy"'
```

Expected: `http_proxy=http://localhost:3128`

- [ ] **Step 6: Commit if any fixup changes were needed**

```bash
git add -p  # stage only intentional changes
git commit -m "fix: <describe the specific fix>"
```
