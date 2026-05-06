#!/bin/bash
###############################################################################
# test-sandbox.sh — Smoke-test the sandbox security controls
#
# Builds the image and runs security checks inside the container to verify:
#   1. Init scripts succeed
#   2. Settings are locked (root-owned, read-only, tamper-proof)
#   3. Firewall default-deny policy is active
#   4. Blocked destinations are unreachable
#   5. Allowed destinations (Anthropic API) are reachable
#   6. Agent cannot escalate privileges
#   7. Sensitive host paths are not exposed
#
# Usage:
#   bash test-sandbox.sh               # standard tests
#   bash test-sandbox.sh --enable-docker  # also run Docker-in-Docker tests
#
# No API key or subscription needed — tests run as plain bash.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="$SCRIPT_DIR/bin/code-sandbox"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0
SKIP=0
TESTS=()

# Parse flags
TEST_DIND=false
for arg in "$@"; do
    case "$arg" in
        --enable-docker) TEST_DIND=true ;;
    esac
done

pass() {
    PASS=$((PASS + 1))
    TESTS+=("  PASS: $1")
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TESTS+=("  FAIL: $1")
    echo "  FAIL: $1"
}

skip() {
    SKIP=$((SKIP + 1))
    TESTS+=("  SKIP: $1")
    echo "  SKIP: $1"
}

echo ""
echo "================================================================"
echo "  Sandbox Security Smoke Tests"
echo "================================================================"
echo ""

# ── Step 1: Build the image ──────────────────────────────────────────────────
echo "[test] Building sandbox image (first build may take a few minutes)..."
echo ""
if "$SANDBOX" --entrypoint true -- true; then
    echo ""
    pass "Image builds successfully"
else
    echo ""
    fail "Image build failed"
    exit 1
fi

# ── Step 2: Run security checks inside the container ─────────────────────────
echo ""
echo "[test] Running security checks inside container..."
echo ""

TEST_OUTPUT=$("$SANDBOX" --no-build --entrypoint bash -- -c '
set -euo pipefail

echo "=== BEGIN TESTS ==="

# ── Root phase: remap devuser to host UID/GID ────────────────────────────
# Mirrors entrypoint.sh (including UID collision handling) so tests match runtime.
if echo "${HOST_UID:-}" | grep -qE "^[0-9]+$" && echo "${HOST_GID:-}" | grep -qE "^[0-9]+$"; then
    CURRENT_UID=$(id -u devuser)
    CURRENT_GID=$(id -g devuser)
    if [ "$HOST_GID" != "$CURRENT_GID" ]; then
        EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1 || true)
        if [ -n "$EXISTING_GROUP" ]; then
            usermod -g "$HOST_GID" devuser
        else
            groupmod -g "$HOST_GID" devuser
        fi
    fi
    if [ "$HOST_UID" != "$CURRENT_UID" ]; then
        uid_owner=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
        if [ -n "$uid_owner" ] && [ "$uid_owner" != "devuser" ]; then
            echo "[test-remap] UID $HOST_UID is in use by $uid_owner; relocating to a spare UID"
            temp_uid=99990
            while getent passwd "$temp_uid" >/dev/null; do
                temp_uid=$((temp_uid + 1))
            done
            other_home=$(getent passwd "$uid_owner" | cut -d: -f6)
            usermod -u "$temp_uid" "$uid_owner"
            if [ -n "$other_home" ] && [ -d "$other_home" ]; then
                chown -R "$uid_owner:" "$other_home" 2>/dev/null || true
            fi
        fi
        usermod -u "$HOST_UID" devuser
    fi
    chown -R devuser /home/devuser 2>/dev/null || true
fi

# ── UID/GID remap verification ───────────────────────────────────────────
DEVUSER_UID=$(id -u devuser)
DEVUSER_GID=$(id -g devuser)
if [[ "${HOST_UID:-}" =~ ^[0-9]+$ ]] && [[ "${HOST_GID:-}" =~ ^[0-9]+$ ]]; then
    if [ "$DEVUSER_UID" = "$HOST_UID" ] && [ "$DEVUSER_GID" = "$HOST_GID" ]; then
        echo "TEST_UID_GID_REMAP=PASS"
    else
        echo "TEST_UID_GID_REMAP=FAIL (devuser=$DEVUSER_UID:$DEVUSER_GID, expected HOST=$HOST_UID:$HOST_GID)"
    fi
else
    echo "TEST_UID_GID_REMAP=SKIP (HOST_UID/HOST_GID not passed or non-numeric)"
fi

# ── Initialize security controls ─────────────────────────────────────────
# Entrypoint runs as root and calls these directly; test mirrors that.
LOCK_OUTPUT=$(/usr/local/bin/lock-settings.sh 2>&1) ; LOCK_RC=$?
if [ $LOCK_RC -eq 0 ]; then
    echo "TEST_INIT_LOCK_SETTINGS=PASS"
else
    echo "TEST_INIT_LOCK_SETTINGS=FAIL (exit code $LOCK_RC: $LOCK_OUTPUT)"
fi

FW_OUTPUT=$(/usr/local/bin/init-firewall.sh 2>&1) ; FW_RC=$?
if [ $FW_RC -eq 0 ]; then
    echo "TEST_INIT_FIREWALL=PASS"
else
    echo "TEST_INIT_FIREWALL=FAIL (exit code $FW_RC: $FW_OUTPUT)"
fi

# ── Settings: root-owned ─────────────────────────────────────────────────
OWNER=$(stat -c "%U" /home/devuser/.claude/settings.json 2>/dev/null || echo "MISSING")
if [ "$OWNER" = "root" ]; then
    echo "TEST_SETTINGS_OWNER=PASS"
else
    echo "TEST_SETTINGS_OWNER=FAIL (owner=$OWNER)"
fi

# ── Settings: read-only (0444) ───────────────────────────────────────────
PERMS=$(stat -c "%a" /home/devuser/.claude/settings.json 2>/dev/null || echo "000")
if [ "$PERMS" = "444" ]; then
    echo "TEST_SETTINGS_PERMS=PASS"
else
    echo "TEST_SETTINGS_PERMS=FAIL (perms=$PERMS)"
fi

# ── Settings: devuser cannot append ──────────────────────────────────────
if gosu devuser bash -c "echo tampered >> /home/devuser/.claude/settings.json" 2>/dev/null; then
    echo "TEST_SETTINGS_WRITE=FAIL (write succeeded!)"
else
    echo "TEST_SETTINGS_WRITE=PASS"
fi

# ── Settings: devuser cannot overwrite via cp ────────────────────────────
if gosu devuser bash -c "cp /dev/null /home/devuser/.claude/settings.json" 2>/dev/null; then
    echo "TEST_SETTINGS_CP=FAIL (cp succeeded!)"
else
    echo "TEST_SETTINGS_CP=PASS"
fi

# ── Settings: content matches canonical ──────────────────────────────────
if diff -q /usr/local/share/sandbox-config/.claude/settings.json /home/devuser/.claude/settings.json > /dev/null 2>&1; then
    echo "TEST_SETTINGS_CONTENT=PASS"
else
    echo "TEST_SETTINGS_CONTENT=FAIL (content differs from canonical)"
fi

# ── Settings: local override is pre-claimed and locked ───────────────────
LOCAL_OWNER=$(stat -c "%U" /home/devuser/.claude/settings.local.json 2>/dev/null || echo "MISSING")
LOCAL_PERMS=$(stat -c "%a" /home/devuser/.claude/settings.local.json 2>/dev/null || echo "000")
if [ "$LOCAL_OWNER" = "root" ] && [ "$LOCAL_PERMS" = "444" ]; then
    echo "TEST_SETTINGS_LOCAL_LOCKED=PASS"
elif [ "$LOCAL_OWNER" = "MISSING" ]; then
    echo "TEST_SETTINGS_LOCAL_LOCKED=FAIL (file not created by lock-settings.sh)"
else
    echo "TEST_SETTINGS_LOCAL_LOCKED=FAIL (owner=$LOCAL_OWNER, perms=$LOCAL_PERMS)"
fi

# ── Settings: devuser cannot overwrite local override ────────────────────
if gosu devuser bash -c "echo {} > /home/devuser/.claude/settings.local.json" 2>/dev/null; then
    echo "TEST_SETTINGS_LOCAL_WRITE=FAIL (overwrote settings.local.json!)"
else
    echo "TEST_SETTINGS_LOCAL_WRITE=PASS"
fi

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
# Proxy allow test: any HTTP response from pypi.org proves the CONNECT tunnel was established.
# 000 = TCP connection to proxy failed; 503 = proxy could not reach upstream.
# Any other code (200, 301, 400, etc.) means Squid forwarded the request successfully.
HTTP_CODE=$(curl --proxy http://localhost:3128 -s -o /dev/null -w "%{http_code}" \
    --max-time 10 https://pypi.org 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ] && [ "$HTTP_CODE" != "503" ]; then
    echo "TEST_FW_PROXY_ALLOW=PASS"
else
    echo "TEST_FW_PROXY_ALLOW=FAIL (HTTP $HTTP_CODE reaching pypi.org via proxy)"
fi

# ── Firewall: proxy blocks a non-allowlisted domain ──────────────────────
# Use http:// (not https://) so Squid processes the full request and returns 403 directly.
# With https://, Squid blocks the CONNECT tunnel before any HTTP exchange, so %{http_code}
# reports 000 even on a successful block.
HTTP_CODE=$(gosu devuser bash -c "curl --proxy http://localhost:3128 -s -o /dev/null -w \"%{http_code}\" \
    --max-time 5 http://pastebin.com 2>/dev/null || echo 000")
if [ "$HTTP_CODE" = "403" ]; then
    echo "TEST_FW_PROXY_DENY=PASS"
else
    echo "TEST_FW_PROXY_DENY=FAIL (HTTP $HTTP_CODE for pastebin.com, expected 403)"
fi

# ── Firewall: Anthropic API reachable via proxy ───────────────────────────
# Test as devuser: verifies the proxy ACL allows api.anthropic.com, not just the root iptables bypass
HTTP_CODE=$(gosu devuser bash -c "curl --proxy http://localhost:3128 -s -o /dev/null -w \"%{http_code}\" --max-time 10 https://api.anthropic.com 2>/dev/null || echo 000")
if [ "$HTTP_CODE" != "000" ]; then
    echo "TEST_FW_ALLOW_ANTHROPIC=PASS"
else
    echo "TEST_FW_ALLOW_ANTHROPIC=FAIL (could not reach api.anthropic.com via proxy as devuser)"
fi

# ── Privilege escalation: devuser cannot run sudo ────────────────────────
if gosu devuser bash -c "sudo ls /root" 2>/dev/null; then
    echo "TEST_SUDO_RESTRICTED=FAIL (sudo ls /root succeeded!)"
else
    echo "TEST_SUDO_RESTRICTED=PASS"
fi

# ── Privilege escalation: devuser cannot sudo chmod settings ─────────────
if gosu devuser bash -c "sudo chmod 0666 /home/devuser/.claude/settings.json" 2>/dev/null; then
    echo "TEST_SUDO_CHMOD=FAIL (sudo chmod succeeded!)"
else
    echo "TEST_SUDO_CHMOD=PASS"
fi

# ── Docker socket not mounted ────────────────────────────────────────────
if [ -e /var/run/docker.sock ]; then
    echo "TEST_NO_DOCKER_SOCKET=FAIL (docker.sock is accessible!)"
else
    echo "TEST_NO_DOCKER_SOCKET=PASS"
fi

# ── No SSH keys ──────────────────────────────────────────────────────────
SSH_KEYS_FOUND=false
for f in /root/.ssh/id_* /home/devuser/.ssh/id_*; do
    if [ -e "$f" ]; then SSH_KEYS_FOUND=true; break; fi
done
if [ "$SSH_KEYS_FOUND" = true ]; then
    echo "TEST_NO_SSH_KEYS=FAIL (SSH key files found!)"
else
    echo "TEST_NO_SSH_KEYS=PASS"
fi

# ── /etc/shadow protected from devuser ───────────────────────────────────
if gosu devuser bash -c "cat /etc/shadow" 2>/dev/null | head -1 | grep -q ":"; then
    echo "TEST_SHADOW_PROTECTED=FAIL (devuser could read /etc/shadow!)"
else
    echo "TEST_SHADOW_PROTECTED=PASS"
fi

# ── /proc/1/environ not leaking secrets to devuser ───────────────────────
if gosu devuser bash -c "cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep -qi 'password\|secret\|key'"; then
    echo "TEST_PROC_ENV_PROTECTED=FAIL (found secrets in /proc/1/environ!)"
else
    echo "TEST_PROC_ENV_PROTECTED=PASS"
fi

# ── Python cannot bypass privilege restrictions ──────────────────────────
if gosu devuser python3 -c "import subprocess; subprocess.run([\"sudo\", \"ls\", \"/root\"], check=True)" 2>/dev/null; then
    echo "TEST_PYTHON_SUDO_BYPASS=FAIL (python sudo bypass succeeded!)"
else
    echo "TEST_PYTHON_SUDO_BYPASS=PASS"
fi

# ── Canonical settings is read-only for devuser ──────────────────────────
if gosu devuser bash -c "echo tampered >> /usr/local/share/sandbox-config/.claude/settings.json" 2>/dev/null; then
    echo "TEST_CANONICAL_SETTINGS_RO=FAIL (wrote to canonical settings!)"
else
    echo "TEST_CANONICAL_SETTINGS_RO=PASS"
fi

# ── System files protected from devuser ──────────────────────────────────
if gosu devuser bash -c "touch /etc/evil-file" 2>/dev/null; then
    echo "TEST_SYSTEM_FILES_PROTECTED=FAIL (devuser could write to /etc!)"
else
    echo "TEST_SYSTEM_FILES_PROTECTED=PASS"
fi

# ── Cannot overwrite init scripts ────────────────────────────────────────
if gosu devuser bash -c "cp /dev/null /usr/local/bin/lock-settings.sh" 2>/dev/null; then
    echo "TEST_INIT_SCRIPTS_RO=FAIL (overwrote lock-settings.sh!)"
else
    echo "TEST_INIT_SCRIPTS_RO=PASS"
fi

# ── Credential injection: render-credentials.sh ──────────────────────────────
mkdir -p /run/sandbox-secrets

# C1: Valid payload renders to correct content (with aliasing)
cat > /run/sandbox-secrets/payload.json <<PAYLOAD
{"secrets":{"GRAD_USER":"alice","GRAD_PASS":"s3cr3t"},"targets":[{"template":"gradle-properties","dest":"/tmp/test-creds.properties","secrets":[{"name":"GRAD_USER","as":"nexusUser"},{"name":"GRAD_PASS","as":"nexusPassword"}]}]}
PAYLOAD

RENDER_RC=0
/usr/local/bin/render-credentials.sh > /dev/null 2>&1 || RENDER_RC=$?
if [ $RENDER_RC -eq 0 ] && \
   grep -q "nexusUser=alice" /tmp/test-creds.properties 2>/dev/null && \
   grep -q "nexusPassword=s3cr3t" /tmp/test-creds.properties 2>/dev/null; then
    echo "TEST_CRED_RENDER_CONTENT=PASS"
else
    echo "TEST_CRED_RENDER_CONTENT=FAIL (rc=$RENDER_RC content=$(cat /tmp/test-creds.properties 2>/dev/null || echo missing))"
fi

# C2: Rendered file has correct permissions (root:devuser 0444)
PERMS=$(stat -c "%a" /tmp/test-creds.properties 2>/dev/null || echo "MISSING")
OWNER=$(stat -c "%U:%G" /tmp/test-creds.properties 2>/dev/null || echo "MISSING")
if [ "$PERMS" = "444" ] && [ "$OWNER" = "root:devuser" ]; then
    echo "TEST_CRED_FILE_PERMS=PASS"
else
    echo "TEST_CRED_FILE_PERMS=FAIL (perms=$PERMS owner=$OWNER)"
fi

# C3: Payload wiped after successful render
if [ ! -f /run/sandbox-secrets/payload.json ]; then
    echo "TEST_CRED_PAYLOAD_WIPED=PASS"
else
    echo "TEST_CRED_PAYLOAD_WIPED=FAIL (payload.json still present after render)"
fi

# C4: Rendered file is immutable (devuser cannot write to it)
if ! gosu devuser bash -c "echo hack >> /tmp/test-creds.properties" 2>/dev/null; then
    echo "TEST_CRED_FILE_IMMUTABLE=PASS"
else
    echo "TEST_CRED_FILE_IMMUTABLE=FAIL (devuser could write to credential file)"
fi

# C5: Deny rules are merged into settings.json by lock-settings.sh
cat > /run/sandbox-secrets/deny-rules.json <<DENY
["Read(/tmp/test-deny-sentinel)", "Bash(cat /tmp/test-deny-sentinel*)"]
DENY
/usr/local/bin/lock-settings.sh > /dev/null 2>&1
if jq -e ".permissions.deny | contains([\"Read(/tmp/test-deny-sentinel)\"])" \
        /home/devuser/.claude/settings.json > /dev/null 2>&1; then
    echo "TEST_CRED_DENY_RULES_MERGED=PASS"
else
    echo "TEST_CRED_DENY_RULES_MERGED=FAIL"
fi
rm -f /run/sandbox-secrets/deny-rules.json

# C6: Missing template causes non-zero exit
cat > /run/sandbox-secrets/payload.json <<PAYLOAD
{"secrets":{"K":"v"},"targets":[{"template":"no-such-template","dest":"/tmp/x.txt"}]}
PAYLOAD
if ! /usr/local/bin/render-credentials.sh > /dev/null 2>&1; then
    echo "TEST_CRED_MISSING_TEMPLATE=PASS"
else
    echo "TEST_CRED_MISSING_TEMPLATE=FAIL (should have failed)"
fi
rm -f /run/sandbox-secrets/payload.json /run/sandbox-secrets/ctx-*.json

# C7: Referencing undefined secret key causes non-zero exit
cat > /run/sandbox-secrets/payload.json <<PAYLOAD
{"secrets":{"EXISTS":"val"},"targets":[{"template":"dotenv","dest":"/tmp/y.env","secrets":["NO_SUCH_KEY"]}]}
PAYLOAD
if ! /usr/local/bin/render-credentials.sh > /dev/null 2>&1; then
    echo "TEST_CRED_MISSING_SECRET_REF=PASS"
else
    echo "TEST_CRED_MISSING_SECRET_REF=FAIL (should have failed)"
fi
rm -f /run/sandbox-secrets/payload.json /run/sandbox-secrets/ctx-*.json

echo "=== END TESTS ==="
' 2>&1)

# ── Parse results ────────────────────────────────────────────────────────────
echo ""
echo "Results:"
echo "--------"

while IFS= read -r line; do
    if [[ "$line" == TEST_*=PASS* ]]; then
        TEST_NAME="${line%%=*}"
        READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
        pass "$READABLE"
    elif [[ "$line" == TEST_*=FAIL* ]]; then
        TEST_NAME="${line%%=*}"
        DETAIL="${line#*=FAIL}"
        READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
        fail "$READABLE $DETAIL"
    elif [[ "$line" == TEST_*=SKIP* ]]; then
        TEST_NAME="${line%%=*}"
        DETAIL="${line#*=SKIP}"
        READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
        skip "$READABLE $DETAIL"
    fi
done <<< "$TEST_OUTPUT"

# ── Exec-attach regression: proxy env reaches reused-container sessions ──────
# Starts the sandbox normally (docker run, full entrypoint), then re-invokes
# the launcher to trigger the container-reuse path (docker exec + sandbox-exec).
# Verifies that HTTPS_PROXY and outbound curl both work in the attached session.
echo ""
echo "[test] Verifying exec-attach session inherits proxy env..."
echo ""

CONTAINER_NAME="claude-sandbox-$(echo "$SCRIPT_DIR" | md5sum | cut -c1-12)"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Start the sandbox in the background. stdin/stdout are not TTYs here so
# neither the run-branch nor the exec-branch adds -it.
"$SANDBOX" --no-build -- bash -c 'sleep 60' >/dev/null 2>&1 &
BG_PID=$!

# Poll for firewall-verify (written by init-firewall.sh when setup is complete).
ATTACH_READY=false
for i in $(seq 1 60); do
    if docker exec "$CONTAINER_NAME" test -f /run/firewall-verify 2>/dev/null; then
        ATTACH_READY=true; break
    fi
    sleep 1
done

if ! $ATTACH_READY; then
    fail "exec-attach session inherits proxy env (container did not reach ready state)"
else
    ATTACH_OUT=$("$SANDBOX" --no-build -- bash -c '
        echo "PROXY=${HTTPS_PROXY:-UNSET}"
        echo "HTTP_CODE=$(curl -s -o /dev/null --max-time 10 -w "%{http_code}" https://api.anthropic.com)"
    ' 2>&1 || true)

    if echo "$ATTACH_OUT" | grep -q "PROXY=http://localhost:3128" && \
       echo "$ATTACH_OUT" | grep -qE "HTTP_CODE=[1-9][0-9][0-9]"; then
        pass "exec-attach session inherits proxy env"
    else
        fail "exec-attach session inherits proxy env (got: $ATTACH_OUT)"
    fi
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
wait "$BG_PID" 2>/dev/null || true

# ── Docker-in-Docker tests (opt-in via --enable-docker) ─────────────────────
if $TEST_DIND; then
    echo ""
    echo "[test] Running Docker-in-Docker (Podman) security tests..."
    echo ""

    DIND_OUTPUT=$("$SANDBOX" --no-build --enable-docker --entrypoint bash -- -c '
set -euo pipefail

echo "=== BEGIN DIND TESTS ==="

# ── Mirror entrypoint: remap devuser UID/GID to match host ──────────────
if echo "${HOST_UID:-}" | grep -qE "^[0-9]+$" && echo "${HOST_GID:-}" | grep -qE "^[0-9]+$"; then
    CURRENT_UID=$(id -u devuser)
    CURRENT_GID=$(id -g devuser)
    if [ "$HOST_GID" != "$CURRENT_GID" ]; then
        EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1 || true)
        if [ -n "$EXISTING_GROUP" ]; then
            usermod -g "$HOST_GID" devuser
        else
            groupmod -g "$HOST_GID" devuser
        fi
    fi
    if [ "$HOST_UID" != "$CURRENT_UID" ]; then
        uid_owner=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
        if [ -n "$uid_owner" ] && [ "$uid_owner" != "devuser" ]; then
            temp_uid=99990
            while getent passwd "$temp_uid" >/dev/null; do temp_uid=$((temp_uid + 1)); done
            other_home=$(getent passwd "$uid_owner" | cut -d: -f6)
            usermod -u "$temp_uid" "$uid_owner"
            if [ -n "$other_home" ] && [ -d "$other_home" ]; then
                chown -R "$uid_owner:" "$other_home" 2>/dev/null || true
            fi
        fi
        usermod -u "$HOST_UID" devuser
    fi
    chown -R devuser /home/devuser 2>/dev/null || true
fi

# ── Lock settings (ENABLE_DOCKER=true selects dind profile) ─────────────
/usr/local/bin/lock-settings.sh > /dev/null 2>&1

# ── Initialize firewall (Squid + iptables) ───────────────────────────────
/usr/local/bin/init-firewall.sh > /dev/null 2>&1

# ── Make root mount shared (required for rootless Podman bind mounts) ────
mount --make-rshared / > /dev/null 2>&1 || true

# ── Set up rootless Podman ────────────────────────────────────────────────
DEVUSER_UID=$(id -u devuser)
RUNTIME_DIR="/run/user/$DEVUSER_UID"
mkdir -p "$RUNTIME_DIR"
chown devuser:devuser "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

CONTAINERS_DIR="/home/devuser/.config/containers"
mkdir -p "$CONTAINERS_DIR"
cat > "$CONTAINERS_DIR/storage.conf" <<STOR
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,noatime"
STOR
cat > "$CONTAINERS_DIR/containers.conf" <<CONF
[containers]
http_proxy = true
env = ["http_proxy=http://localhost:3128", "https_proxy=http://localhost:3128", "no_proxy=localhost,127.0.0.1"]
default_sysctls = []
pidns = "host"
utsns = "host"
netns = "host"

[engine]
runtime = "crun"
CONF
chown -R devuser:devuser /home/devuser/.config

# Start Podman API socket (Docker-compatible) as devuser.
# Start early so it has time to appear while the other tests run.
# Pre-create the socket directory (podman system service does not create it).
SOCKET="$RUNTIME_DIR/podman/podman.sock"
mkdir -p "$RUNTIME_DIR/podman"
chown devuser:devuser "$RUNTIME_DIR/podman"
gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman system service --time=0 unix://$SOCKET" > /dev/null 2>&1 &

# ── DinD settings profile ─────────────────────────────────────────────────
if grep -q "dind-permissive" /home/devuser/.claude/settings.json 2>/dev/null; then
    echo "TEST_DIND_SETTINGS_PROFILE=PASS"
else
    echo "TEST_DIND_SETTINGS_PROFILE=FAIL (dind-permissive profile not loaded in settings.json)"
fi

# ── Basic container execution ─────────────────────────────────────────────
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm alpine echo hello" 2>/dev/null | grep -q "hello"; then
    echo "TEST_DIND_RUNS=PASS"
else
    echo "TEST_DIND_RUNS=FAIL (podman run --rm alpine echo hello failed)"
fi

# ── Host filesystem isolation ─────────────────────────────────────────────
# Mounting / into an inner container should see the sandbox root, not the real host.
SANDBOX_HOSTNAME=$(hostname)
INNER_HOSTNAME=$(gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm -v /:/host:ro alpine cat /host/etc/hostname 2>/dev/null" 2>/dev/null || echo "ERROR")
if [ "$INNER_HOSTNAME" = "$SANDBOX_HOSTNAME" ]; then
    echo "TEST_DIND_HOST_FS_ISOLATED=PASS"
else
    echo "TEST_DIND_HOST_FS_ISOLATED=FAIL (inner saw hostname=$INNER_HOSTNAME, expected sandbox=$SANDBOX_HOSTNAME)"
fi

# ── Workspace mount ────────────────────────────────────────────────────────
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm -v /workspace:/workspace:ro alpine test -d /workspace" 2>/dev/null; then
    echo "TEST_DIND_WORKSPACE_MOUNT=PASS"
else
    echo "TEST_DIND_WORKSPACE_MOUNT=FAIL (could not mount /workspace into inner container)"
fi

# ── Firewall blocks inner containers without proxy ────────────────────────
# Inner container traffic exits as devuser UID → iptables rejects direct TCP.
# Without proxy env vars, outbound HTTP should fail.
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR podman run --rm alpine wget -q --tries=1 --timeout=5 -O- http://pastebin.com 2>/dev/null" 2>/dev/null | head -1 | grep -qi "doctype\|html"; then
    echo "TEST_DIND_FIREWALL_BLOCKS=FAIL (inner container reached pastebin.com without proxy!)"
else
    echo "TEST_DIND_FIREWALL_BLOCKS=PASS"
fi

# ── Proxy allows allowlisted domains from inner containers ────────────────
# Proxy env vars are set via containers.conf; inner container uses them.
# Use http:// so BusyBox wget (alpine) can proxy via Squid without CONNECT.
# Any HTTP response (200, 301, etc.) proves the proxy forwarded the request.
HTTP_CODE=$(gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR \
    podman run --rm \
        alpine wget -q --tries=1 --timeout=10 -S -O /dev/null http://pypi.org 2>&1 || true" 2>/dev/null \
    | grep "^  HTTP/" | tail -1 | awk '"'"'{print $2}'"'"' || echo "000")
if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ] && [ "$HTTP_CODE" != "503" ]; then
    echo "TEST_DIND_PROXY_ALLOWS=PASS"
else
    echo "TEST_DIND_PROXY_ALLOWS=FAIL (HTTP $HTTP_CODE reaching pypi.org from inner container)"
fi

# ── Podman API socket ready ────────────────────────────────────────────────
# The socket was started early (before other tests) to allow startup time.
# By now, the other 5 tests above have run (~30s total), giving the service
# enough time to initialize and create the socket file.
SOCKET_READY=false
for i in $(seq 1 20); do
    if [ -S "$SOCKET" ]; then SOCKET_READY=true; break; fi
    sleep 0.5
done
if [ "$SOCKET_READY" = "true" ]; then
    echo "TEST_DIND_SOCKET_READY=PASS"
else
    echo "TEST_DIND_SOCKET_READY=FAIL (socket did not appear at $SOCKET)"
fi

# ── Docker CLI compatibility (podman-docker shim) ─────────────────────────
if gosu devuser bash -c "XDG_RUNTIME_DIR=$RUNTIME_DIR DOCKER_HOST=unix://$SOCKET docker run --rm alpine echo docker-compat" 2>/dev/null | grep -q "docker-compat"; then
    echo "TEST_DIND_DOCKER_CLI_COMPAT=PASS"
else
    echo "TEST_DIND_DOCKER_CLI_COMPAT=FAIL (docker CLI shim failed)"
fi

echo "=== END DIND TESTS ==="
' 2>&1)

    while IFS= read -r line; do
        if [[ "$line" == TEST_*=PASS* ]]; then
            TEST_NAME="${line%%=*}"
            READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
            pass "$READABLE"
        elif [[ "$line" == TEST_*=FAIL* ]]; then
            TEST_NAME="${line%%=*}"
            DETAIL="${line#*=FAIL}"
            READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
            fail "$READABLE $DETAIL"
        elif [[ "$line" == TEST_*=SKIP* ]]; then
            TEST_NAME="${line%%=*}"
            DETAIL="${line#*=SKIP}"
            READABLE=$(echo "$TEST_NAME" | sed 's/^TEST_//; s/_/ /g' | tr '[:upper:]' '[:lower:]')
            skip "$READABLE $DETAIL"
        fi
    done <<< "$DIND_OUTPUT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "================================================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Some security checks failed. Review the output above."
    echo ""
    echo "  Debugging tips:"
    echo "    - Init script failures often indicate missing kernel modules"
    echo "      (iptables needs iptable_filter) or Docker capability issues."
    echo "    - On Docker Desktop (Windows/macOS), try:"
    echo "        bin/code-sandbox --entrypoint bash"
    echo "    - To see raw container output, run with VERBOSE=1:"
    echo "        VERBOSE=1 bash test-sandbox.sh"
    if [ -n "${VERBOSE:-}" ]; then
        echo ""
        echo "  Raw container output:"
        echo "  ─────────────────────"
        echo "$TEST_OUTPUT"
    fi
    exit 1
else
    echo ""
    echo "  All security controls verified."
    exit 0
fi
