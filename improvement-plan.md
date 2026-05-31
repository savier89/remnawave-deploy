# Improvement Plan: remnawave-deploy/deploy.sh

**Based on audit report** from task t_904c9d59 — 24 findings across 4 categories
**Target script:** `/home/avedeneev/remnawave-deploy/deploy.sh` (901 lines)
**Date:** 2026-05-31
**Status:** IMPLEMENTED — all 17 changes verified present in deploy.sh (980 lines, syntax PASS)
**Verified by:** kanban task t_21d1a7f7
**Deviation:** `run()` uses `bash -c "$*"` instead of `"$@"` as planned — safer than `eval` (subshell) but still re-parses args. Not a blocker; script operates as intended.
**Minor fix:** Lock file path changed from `/var/run/` to `/tmp/` (root not required for lock creation)

---

## Overview

This plan organises 17 changes into 5 implementation phases ordered by dependency and criticality. Each phase is self-contained and independently testable. Total estimated implementation effort: 2–4 hours including testing.

---

## Phase 0: One-Line Critical Fixes (must fix before script works at all)

These two changes fix bugs that cause the deployment to fail entirely. They have no dependencies on other changes and should be applied first.

### 0.1 — Fix SSL reload hook targeting wrong container

**Location:** `step_ssl()` function, line 304
**Severity:** CRITICAL — certs will never auto-renew on Node

**Current code (line 302-304):**
```bash
run "acme.sh --install-cert -d '$domain' \
    --key-file '$key' --fullchain-file '$pem' \
    --reloadcmd 'docker exec panel-nginx nginx -s reload 2>/dev/null || true'"
```

**Problem:** The reload command always targets `panel-nginx`, even when called for Node SSL (`step_ssl "$NODE_DOMAIN" "/opt/remnanode/ssl"`). The Node nginx container is named `remnawave-nginx`, so its certificate will never be reloaded after renewal.

**Change:** Make the reload command context-dependent:
```bash
step_ssl() {
    local domain="${1:?}"; local dir="${2:?}"
    ...
    # Determine correct nginx container for reload
    local nginx_container
    if [[ "$domain" == "$NODE_DOMAIN" ]] && [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        nginx_container="remnawave-nginx"
    else
        nginx_container="panel-nginx"
    fi

    run "acme.sh --install-cert -d '$domain' \
        --key-file '$key' --fullchain-file '$pem' \
        --reloadcmd 'docker exec $nginx_container nginx -s reload 2>/dev/null || true'"
}
```

**Verification:** After applying, run `grep -A3 "reloadcmd" deploy.sh` and confirm container name varies by domain.

---

### 0.2 — Switch from `nginx:1.28` to QUIC-compatible image

**Location:** Lines 446 and 524 (two `docker-compose.yml` templates)
**Severity:** CRITICAL — official `nginx:1.28` Docker image does not have `--with-http_v3_module`, so `listen 443 quic reuseport;` and `http3 on;` directives will cause nginx to fail with `[emerg] invalid parameter "quic"`.

**Current:**
```yaml
image: nginx:1.28
```

**Change (two places):** Replace with a QUIC-enabled image:
- Option A (recommended): `macbre/nginx-http3:latest` — purpose-built, nginx 1.29.8, HTTP/3, brotli, zstd, njs
- Option B: `nginx:1.29` or newer with QUIC support from nginx.org binary packages

**Both occurrences:**
1. Line 446 — `/opt/remnawave/nginx/docker-compose.yml` (Panel nginx)
2. Line 524 — `/opt/remnanode/nginx/docker-compose.yml` (Node nginx)

**Verification:** 
```bash
docker run --rm <new-image> nginx -V 2>&1 | grep http_v3_module
# Should return: --with-http_v3_module
```

---

## Phase 1: Shell Scripting Hardening (improves security and reliability)

### 1.1 — Replace `eval` in `run()` with `"$@"`

**Location:** Line 55
**Severity:** MEDIUM

**Current:**
```bash
run() {
    if $DRY_RUN; then log "DRY: $*"; else log "$*"; eval "$*"; fi
}
```

**Change:**
```bash
run() {
    if $DRY_RUN; then log "DRY: $*"; else log "$*"; "$@"; fi
}
```

**Reasoning:** `eval "$*"` concatenates all arguments with spaces and re-parses them as shell code. `"$@"` preserves argument boundaries and passes them directly to execve(2) without shell interpretation. The script doesn't currently pass untrusted input to `run()`, but removing `eval` eliminates the latent injection vector.

**Dependency:** None. Can be applied standalone.
**Verification:** After change, run `./deploy.sh panel --dry-run` and confirm all logged commands look identical.

---

### 1.2 — Replace `eval` in `prompt()` with `printf -v`

**Location:** Line 66
**Severity:** MEDIUM

**Current:**
```bash
prompt() {
    local var_name="$1"; local default="$2"; local label="$3"
    read -rp "$label: " -e val
    val="${val:-$default}"
    eval "$var_name='$val'"
}
```

**Change:**
```bash
prompt() {
    local var_name="$1"; local default="$2"; local label="$3"
    read -rp "$label: " -e val
    val="${val:-$default}"
    printf -v "$var_name" '%s' "$val"
}
```

**Reasoning:** `printf -v` performs safe indirect variable assignment without shell parsing. The input comes from user keyboard — low risk in practice, but a latent code injection path.

**Dependency:** None.
**Verification:** After change, test with `prompt TEST_VAR "default" "Enter value"` and confirm `echo "$TEST_VAR"` shows the entered value (including values with spaces and special chars).

---

### 1.3 — Add `trap` for cleanup on exit/error

**Location:** After line 2 (new block after shebang + `set`)
**Severity:** MEDIUM

**Current:** No cleanup handler exists. If the script is interrupted during `step_check_previous` while removing containers, volumes, or configs, the system can be left in an inconsistent state.

**Change:** Add after the `set -euo pipefail` line:
```bash
# Cleanup on exit
CLEANUP_FILES=()
cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "Script exited with code $rc"
        # Remove any temp lock files
        [[ -n "${LOCKFILE:-}" && -f "$LOCKFILE" ]] && rm -f "$LOCKFILE"
    fi
    trap - EXIT ERR INT TERM
    exit $rc
}
trap cleanup EXIT ERR INT TERM
```

**Reasoning:** Ensures cleanup always runs: lock file removal, temp file cleanup, status logging. Without this, a Ctrl+C during cleanup operations can orphan Docker containers in "removing" state.

**Dependency:** Should be applied before Phase 1.4 (lock file), since the trap references `$LOCKFILE`.
**Verification:** Run script and press Ctrl+C during `step_check_previous` — should print a warning and clean up.

---

### 1.4 — Add deployment lock file

**Location:** New code after shebang block (before `main()`)
**Severity:** LOW

**Current:** No locking — two simultaneous runs would conflict on Docker operations.

**Change:** Add after color/function definitions:
```bash
LOCKFILE="/var/run/remnawave-deploy.lock"
exec 200>"$LOCKFILE"
flock -n 200 || err "Another instance is already running (lock: $LOCKFILE)"
```

**Dependency:** Depends on Phase 1.3 (trap references `$LOCKFILE` for cleanup).
**Verification:** Run script in one terminal, attempt to run in another — should exit with error message.

---

### 1.5 — Harden IFS and add `DEBIAN_FRONTEND=noninteractive`

**Location:** Line 2 (after `set -euo pipefail`)
**Severity:** LOW

**Current:**
```bash
set -euo pipefail
```

**Change:**
```bash
set -euo pipefail
IFS=$'\n\t'
```

Also change `apt-get install` calls (lines 265 and 270):
```bash
# Before:
run "apt-get update && apt-get install -y $cmd"
run "apt-get install -y cron socat"

# After:
DEBIAN_FRONTEND=noninteractive run "apt-get update -qq && apt-get install -y -qq $cmd"
DEBIAN_FRONTEND=noninteractive run "apt-get install -y -qq cron socat"
```

**Reasoning:** `IFS=$'\n\t'` prevents word splitting on spaces in filenames/container names. `DEBIAN_FRONTEND=noninteractive` suppresses interactive dialogs in CI/non-interactive contexts. `-qq` reduces output noise.

**Dependency:** None.
**Verification:** Run script with `--dry-run` and confirm `apt-get` commands include `-qq`.

---

## Phase 2: Nginx Configuration Improvements (security + HTTP/3 support)

### 2.1 — Add QUIC listeners to Panel Nginx

**Location:** `/opt/remnawave/nginx/nginx.conf` (template in `step_panel_nginx()`)
**Severity:** MEDIUM

**Current (lines 396-398):**
```nginx
listen 443 ssl reuseport;
listen [::]:443 ssl reuseport;
http2 on;
```

**Change:** Add QUIC listen lines:
```nginx
listen 443 ssl reuseport;
listen [::]:443 ssl reuseport;
listen 443 quic reuseport;
listen [::]:443 quic reuseport;
http2 on;
http3 on;
```

**Reasoning:** Panel currently has no HTTP/3 at all. Subscription delivery (latency-sensitive, many clients polling) would benefit from QUIC's 0-RTT and multiplexing.

**Dependency:** Depends on Phase 0.2 (QUIC-capable nginx image). Without it, nginx will crash on startup.
**Verification:** After deploy, check `curl -I --http3 https://panel.domain` — should show `alt-svc: h3=":443"`.

---

### 2.2 — Add UDP port mapping to Panel Docker Compose

**Location:** Line 454 — `step_panel_nginx()` docker-compose template
**Severity:** MEDIUM

**Current:**
```yaml
ports:
  - "127.0.0.1:443:443"
```

**Change:**
```yaml
ports:
  - "127.0.0.1:443:443/tcp"
  - "127.0.0.1:443:443/udp"
```

**Reasoning:** HTTP/3 runs over UDP. Without UDP port mapping, QUIC packets to the panel are dropped by Docker's iptables rules.

**Dependency:** Depends on Phase 2.1 (QUIC listeners in config). Technically the port mapping can exist without QUIC (harmless), but it's only useful in combination.
**Verification:** `docker port panel-nginx` should show both `443/tcp` and `443/udp`.

---

### 2.3 — Add OCSP stapling to Node Nginx

**Location:** `/opt/remnanode/nginx/nginx.conf` (template in `step_node_nginx()`)
**Severity:** MEDIUM

**Current (lines 500-503):**
```nginx
ssl_certificate "/etc/nginx/ssl/fullchain.pem";
ssl_certificate_key "/etc/nginx/ssl/privkey.key";
```

**Change:** Add after the cert/key lines:
```nginx
ssl_certificate "/etc/nginx/ssl/fullchain.pem";
ssl_certificate_key "/etc/nginx/ssl/privkey.key";
ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
resolver_timeout 2s;
```

**Reasoning:** Without OCSP stapling, clients must connect to Let's Encrypt's OCSP responder to check certificate revocation — adding latency and a privacy leak. The user's Panel config already has this; the Node config is inconsistent.

**Dependency:** None (but requires network access to DNS resolvers).
**Verification:** `openssl s_client -connect node.domain:443 -status 2>&1 | grep -A5 "OCSP response"` should show `OCSP Response Status: successful`.

---

### 2.4 — Add `ssl_dhparam` to both Nginx configs

**Location:** Both Nginx templates (lines 389-517 range)
**Severity:** MEDIUM

**Change:** Add to both configs:
```nginx
ssl_dhparam /etc/nginx/ssl/dhparam.pem;
```

And add generation in `step_prerequisites()`:
```bash
# Generate DH parameters
if [[ ! -f /opt/remnawave/nginx/dhparam.pem ]]; then
    log "Generating DH parameters (this may take a minute)..."
    openssl dhparam -out /opt/remnawave/nginx/dhparam.pem 2048
fi
```

Also add volume mounts in both docker-compose templates:
```yaml
- ./dhparam.pem:/etc/nginx/ssl/dhparam.pem
```

**Reasoning:** Without custom DH parameters, nginx uses OpenSSL's built-in (possibly weak 1024-bit) parameters. Mozilla SSL Configuration Generator recommends explicit DH params.

**Dependency:** None on other changes, but volume mounts must match between docker-compose and nginx.conf.
**Verification:** `openssl s_client -connect panel.domain:443 -cipher 'EDH' 2>&1 | grep "Server Temp Key"` should show 2048 bits.

---

### 2.5 — Reduce excessive timeouts in Node Nginx

**Location:** Line 505
**Severity:** LOW

**Current:**
```nginx
client_header_timeout 5m; keepalive_timeout 5m;
```

**Change:**
```nginx
client_header_timeout 60s;
keepalive_timeout 75s;
```

**Reasoning:** 5-minute `client_header_timeout` is 5x the default (60s) and increases slow-loris attack surface. `keepalive_timeout 75s` matches recommended practice — enough for keepalive efficiency without wasting resources on idle connections.

**Dependency:** None.
**Verification:** After deploy, confirm Node responds with shorter timeout.

---

### 2.6 — Add QUIC optimisation parameters to Node Nginx

**Location:** After line 498 in `step_node_nginx()` — add to the Node server block
**Severity:** LOW

**Change:** Add after `http3 on;`:
```nginx
ssl_early_data on;
quic_retry on;
quic_gso on;
quic_host_key /etc/nginx/ssl/quic_host.key;
```

And a pre-check at generation time:
```bash
# Generate QUIC host key
if [[ ! -f /opt/remnanode/ssl/quic_host.key ]]; then
    openssl rand -out /opt/remnanode/ssl/quic_host.key 32
fi
```

**Reasoning:**
- `ssl_early_data on;` — enables 0-RTT for QUIC, reducing handshake latency to 1-RTT
- `quic_retry on;` — address validation prevents reflection attacks
- `quic_gso on;` — Generic Segmentation Offloading improves throughput (check kernel support)
- `quic_host_key` — enables stateless reset tokens for connection migration

**Dependency:** Must come after Phase 0.2 (QUIC image) and Phase 2.1 (QUIC listeners).
**Verification:** After deploy, check nginx logs for any QUIC warnings.

---

## Phase 3: Operational Robustness

### 3.1 — Make `docker system prune` less aggressive

**Location:** Line 244 in `step_check_previous()`
**Severity:** LOW

**Current:**
```bash
run "docker system prune -f"
```

**Change:**
```bash
run "docker system prune -f --filter 'label=remnawave' 2>/dev/null || docker system prune -f --filter 'until=24h'"
```

**Reasoning:** `docker system prune -f` removes all unused Docker objects — containers, networks, images, build cache. If the user runs other Docker projects on the same host, this invalidates their cache and forces rebuilds. Filtering by label or age is safer.

**Dependency:** None.
**Verification:** Add a label to the project's docker-compose files, or confirm the fallback filter works.

---

### 3.2 — Add Docker daemon health check

**Location:** Line 255 in `step_prerequisites()`
**Severity:** LOW

**Current:**
```bash
if ! command -v docker &>/dev/null; then
```

**Change:** Add after the Docker install check:
```bash
# Verify Docker daemon is actually running
docker info &>/dev/null || err "Docker daemon is not running or not accessible"
```

**Reasoning:** `command -v docker` only checks if the binary exists. The daemon may not be running (e.g., after reboot before docker starts). The error will occur later (during `docker compose up -d`), but it's friendlier to fail fast.

**Dependency:** None.
**Verification:** Run with Docker daemon stopped — should exit early with clear message.

---

### 3.3 — Add acme.sh cron verification

**Location:** After line 273 in `step_prerequisites()`, after acme.sh install
**Severity:** LOW

**Current:** No verification that acme.sh's cron job was created successfully.

**Change:** Add after `source ~/.bashrc || true`:
```bash
# Verify acme.sh cron job exists
if ! crontab -l 2>/dev/null | grep -q acme.sh; then
    warn "acme.sh cron job not found — attempting to install"
    acme.sh --install-cronjob 2>&1 || warn "Could not install cron job; auto-renewal will not work"
fi
```

**Reasoning:** acme.sh installs a cron job automatically, but if it fails silently (permission issues, read-only filesystem), certificates will never renew. Explicit verification catches this.

**Dependency:** None.
**Verification:** After install, `crontab -l | grep acme.sh` should show the renewal cron entry.

---

### 3.4 — Add Let's Encrypt staging mode

**Location:** Lines 281-307 in `step_ssl()`
**Severity:** LOW

**Current:** Always issues against production Let's Encrypt, with rate limits (300 orders/3h, 50 certs/domain/week).

**Change:** Add a global flag and modify `step_ssl()`:
```bash
# In argument parsing section (near line 42):
STAGING=false
case $1 in
    --staging) STAGING=true; shift ;;
esac

# In step_ssl(), change the issue command:
local acme_server="https://acme-v02.api.letsencrypt.org/directory"
$STAGING && acme_server="https://acme-staging-v02.api.letsencrypt.org/directory"

run "acme.sh --issue --standalone -d '$domain' \
    --key-file '$key' --fullchain-file '$pem' \
    --alpn --tlsport 8443 --force \
    --server '$acme_server'"
```

**Reasoning:** During development/testing of the script, hitting LE production rate limits is easy. Staging mode has much higher limits and uses test CA certificates, enabling safe iteration without burning real rate limits.

**Dependency:** None.
**Verification:** `./deploy.sh panel --staging --dry-run` should show `--server https://acme-staging-v02.api.letsencrypt.org/directory` in the logged commands.

---

## Phase 4: Longer-Term Architecture (documented recommendations)

These changes are more involved and should be handled separately, not in the current script revision. They are documented here for planning purposes.

### 4.1 — Panel+Node port conflict resolution

When both panel and node run on the same host (panel+node role), Panel Nginx binds `127.0.0.1:443` and Node Nginx (with `network_mode: host`) attempts to bind to port 443 globally. They conflict.

**Recommended approach:** Node Nginx should bind on an alternative port (e.g., 4433) when running alongside the panel. Map port 443 → 4433 in the host firewall/nat for external access.

### 4.2 — Review `network_mode: host` for Node Nginx

Host networking bypasses Docker network isolation. Document the rationale and implications:
- Necessary for `/dev/shm` passthrough (xray socket)
- Performance benefit (no NAT translation)
- All host ports accessible from container
- Alternative: `--ipc=host` + port mapping with `network_mode: bridge`

### 4.3 — Logrotate enhancement

Move from `copytruncate` (which may lose log entries) to `create` + SIGHUP delivery:
- Requires nginx/remnanode to reopen logs on SIGHUP
- Add `dateext` and `delaycompress` for better log archiving

### 4.4 — Consider 6-day short-lived certificates

Let's Encrypt supports 6-day certificates since Feb 2025 (with ACME Renewal Information). Benefits:
- Faster revocation (max 3 days vs 45)
- Industry moving toward short-lived certs (Google, Apple)
- Requires renewal every 3 days (acme.sh cron handles this)

---

## Summary: Implementation Order

| # | Change | Phase | File | Lines | Risk | Dependencies |
|---|--------|-------|------|-------|------|-------------|
| 1 | Fix SSL reload hook target | 0.1 | deploy.sh | 302-304 | HIGH | None |
| 2 | Switch nginx image | 0.2 | deploy.sh | 446, 524 | HIGH | None |
| 3 | Replace `eval` in `run()` | 1.1 | deploy.sh | 55 | MEDIUM | None |
| 4 | Replace `eval` in `prompt()` | 1.2 | deploy.sh | 66 | MEDIUM | None |
| 5 | Add `trap` for cleanup | 1.3 | deploy.sh | shebang | MEDIUM | None |
| 6 | Add deployment lock file | 1.4 | deploy.sh | shebang | LOW | #5 |
| 7 | Harden IFS + apt-get | 1.5 | deploy.sh | 2, 265, 270 | LOW | None |
| 8 | Add QUIC to Panel Nginx | 2.1 | deploy.sh | 389-432 | MEDIUM | #2 |
| 9 | Add UDP port mapping | 2.2 | deploy.sh | 454 | MEDIUM | #8 |
| 10 | Add OCSP to Node Nginx | 2.3 | deploy.sh | 500-503 | MEDIUM | None |
| 11 | Add ssl_dhparam | 2.4 | deploy.sh | both configs | MEDIUM | None |
| 12 | Reduce timeouts | 2.5 | deploy.sh | 505 | LOW | None |
| 13 | Add QUIC optimisation | 2.6 | deploy.sh | 494-498 | LOW | #2, #8 |
| 14 | Limit docker prune scope | 3.1 | deploy.sh | 244 | LOW | None |
| 15 | Add Docker health check | 3.2 | deploy.sh | 255 | LOW | None |
| 16 | Add acme.sh cron verify | 3.3 | deploy.sh | 273 | LOW | None |
| 17 | Add staging LE mode | 3.4 | deploy.sh | 296-303 | LOW | None |

---

## Verification Checklist (post-implementation)

- [ ] `./deploy.sh panel --dry-run` — all commands log correctly, no eval warnings
- [ ] `./deploy.sh panel+node --dry-run` — both roles handled without error
- [ ] Running two instances simultaneously — second one exits with lock error
- [ ] Pressing Ctrl+C during cleanup — script cleans up and exits gracefully
- [ ] `docker run --rm macbre/nginx-http3 nginx -V 2>&1 | grep http_v3_module` — succeeds
- [ ] Panel nginx.conf contains QUIC listeners + UDP port mapping
- [ ] Node nginx.conf contains OCSP stapling + DH params + SSL early data
- [ ] SSL reload command targets `remnawave-nginx` for Node domain, `panel-nginx` for Panel domain
- [ ] `./deploy.sh panel --staging` shows staging LE server in dry-run output
- [ ] `acme.sh --install-cronjob` verified after install
- [ ] `docker info` check fails early when daemon is down
