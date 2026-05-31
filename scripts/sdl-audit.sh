#!/bin/bash
set -uo pipefail

# SDL Security Audit Script for remnawave-deploy
# Checks for:
# - Hardcoded secrets, passwords, tokens, keys
# - Real domain names (not placeholders)
# - API endpoints that could leak data
# - Insecure configurations

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOY_SH="$REPO_DIR/deploy.sh"

PASS=0
FAIL=0
WARN=0

pass() { echo "[PASS] $*"; ((PASS++)); }
fail() { echo "[FAIL] $*"; ((FAIL++)); }
warn() { echo "[WARN] $*"; ((WARN++)); }

echo "=== SDL Security Audit ==="
echo "Target: $DEPLOY_SH"
echo ""

# 1. Check for hardcoded passwords
if grep -nE '(password|passwd|pwd)\s*=\s*["\x27][^"$]*["\x27]' "$DEPLOY_SH" | grep -qv 'POSTGRES_PASSWORD=.*\$\|change_me\|your-password'; then
    fail "Hardcoded password found"
else
    pass "No hardcoded passwords"
fi

# 2. Check for hardcoded secrets/tokens
if grep -nE '(secret|token|api_key|apikey)\s*=\s*["\x27][A-Za-z0-9]{16,}' "$DEPLOY_SH" | grep -qv 'change_me\|your-\|YOUR_\|JWT_\|WEBHOOK_\|METRICS_'; then
    fail "Hardcoded secret/token found"
else
    pass "No hardcoded secrets/tokens"
fi

# 3. Check for real domain names (not placeholders)
if grep -nE '\.(ru|com|net|org|io|dev|app|cloud|co)\b' "$DEPLOY_SH" | grep -vE 'example\.(com|net|org)|domain\.(com|net|org)|your-|docs\.(rw|net)|get\.acme\.sh|get\.docker\.com|raw\.githubusercontent\.com|acme-v02\.api\.letsencrypt\.org|acme-staging'; then
    fail "Real domain name found (potential data leak)"
else
    pass "No real domain names"
fi

# 4. Check for hardcoded IP addresses (not localhost/127.0.0.1)
if grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$DEPLOY_SH" | grep -vE '127\.0\.0\.1|0\.0\.0\.0|1\.1\.1\.1|1\.0\.0\.1|8\.8\.[0-9]+\.[0-9]+|208\.67\.[0-9]+\.[0-9]+'; then
    fail "Hardcoded IP address found"
else
    pass "No hardcoded IP addresses"
fi

# 5. Check for private key files in repo
if find "$REPO_DIR" -name "*.pem" -o -name "*.key" -o -name "*.p12" 2>/dev/null | grep -qv '.git'; then
    fail "Private key files found in repository"
else
    pass "No private key files in repository"
fi

# 6. Check for .env files in repo
if find "$REPO_DIR" -name ".env*" -not -path "*/.git/*" 2>/dev/null | head -1 | grep -q .; then
    fail ".env file found in repository"
else
    pass "No .env files in repository"
fi

# 7. Check for eval usage
if grep -n 'eval ' "$DEPLOY_SH" | grep -v '^#\|echo\|log'; then
    fail "eval usage found (code injection risk)"
else
    pass "No eval usage"
fi

# 8. Check for curl | sh patterns (should be reviewed)
if grep -n 'curl.*|.*sh' "$DEPLOY_SH"; then
    warn "curl | sh pattern found (review if trusted)"
else
    pass "No curl | sh patterns"
fi

# 9. Check for ssh private keys
if grep -nE '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----' "$DEPLOY_SH" 2>/dev/null; then
    fail "SSH private key found"
else
    pass "No SSH private keys"
fi

# 10. Check for AWS/GCP/Azure credentials
if grep -nE '(AKIA[0-9A-Z]{16}|GOOGLE.*SECRET|AZURE.*KEY)' "$DEPLOY_SH"; then
    fail "Cloud provider credentials found"
else
    pass "No cloud provider credentials"
fi

# 11. Check bash syntax
if bash -n "$DEPLOY_SH" 2>/dev/null; then
    pass "Bash syntax valid"
else
    fail "Bash syntax error"
fi

# 12. Check for set -euo pipefail
if grep -q 'set -euo pipefail' "$DEPLOY_SH"; then
    pass "Strict mode enabled (set -euo pipefail)"
else
    warn "Strict mode not enabled"
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "WARN: $WARN"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "AUDIT FAILED"
    exit 1
else
    echo "AUDIT PASSED"
    exit 0
fi
