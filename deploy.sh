#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Cleanup on exit
CLEANUP_FILES=()
cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "Script exited with code $rc"
        if $DEBUG; then
            dbg "=== Error state dump ==="
            dbg "ROLE=$ROLE, DRY_RUN=$DRY_RUN, FORCE=$FORCE, STAGING=$STAGING"
            dbg "NODE_DOMAIN=${NODE_DOMAIN:-<unset>}, PANEL_DOMAIN=${PANEL_DOMAIN:-<unset>}, NODE_PORT=${NODE_PORT:-<unset>}"
            dbg "SUB_DOMAIN=${SUB_DOMAIN:-<unset>}, SUB_PUBLIC_DOMAIN=${SUB_PUBLIC_DOMAIN:-<unset>}, PANEL_HOST=${PANEL_HOST:-<unset>}"
            dbg "EMAIL=${EMAIL:-<unset>}"
            dbg "Docker containers:"
            docker ps -a --format "{{.Names}} {{.Status}} {{.Image}}" 2>/dev/null | while read -r line; do dbg "  $line"; done
            dbg "Docker network:"
            docker network ls 2>/dev/null | while read -r line; do dbg "  $line"; done
        fi
    fi
    [[ -n "${LOCKFILE:-}" && -f "$LOCKFILE" ]] && rm -f "$LOCKFILE"
    trap - EXIT ERR INT TERM
    exit $rc
}
trap cleanup EXIT ERR INT TERM

# Remnawave Universal Deployment Script
# Based on official docs: https://docs.rw/docs/install/
#
# Usage: ./deploy.sh <ROLE>
#
# Roles:
#   panel       - Panel + Nginx reverse proxy only
#   node        - Node + Nginx reverse proxy only
#   panel+node  - Panel + Node + both Nginx

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'; M='\033[0;35m'
log()  { echo -e "${B}[deploy]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N} $*"; exit 1; }

# Debug logging — prints to stderr + optional file
dbg() {
    if $DEBUG; then
        local msg
        msg="${M}[DEBUG]${N} $(date '+%H:%M:%S') $*"
        echo -e "$msg" >&2
        if [[ -n "$DEBUG_FILE" ]]; then
            echo "[DEBUG] $(date '+%H:%M:%S') $*" >> "$DEBUG_FILE"
        fi
    fi
}

# Dump variable values for debugging
debug_vars() {
    if $DEBUG; then
        local label="$1"; shift
        dbg "--- $label ---"
        for var in "$@"; do
            local val="${!var:-<unset>}"
            dbg "  $var = $val"
        done
    fi
}

# Defaults
DRY_RUN=false; FORCE=false; STAGING=false
DEBUG=false; DEBUG_FILE=""
NODE_PORT=2222

usage() {
    cat <<EOF
Usage: $0 <panel|node|panel+node> [OPTIONS]

Roles:
  panel       Panel + Nginx reverse proxy only
  node        Node + Nginx reverse proxy only
  panel+node  Panel + Node + both Nginx

Options:
  --dry-run           Show commands only
  --force             Skip confirmation
  --staging           Use Let's Encrypt staging CA (higher rate limits)
  --debug             Enable debug mode (verbose output, set -x)
  --debug-file FILE   Write debug log to FILE (implies --debug)
EOF
    exit ${1:-0}
}

# Parse args
ROLE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        panel|node|panel+node) [[ -z "$ROLE" ]] && ROLE="$1" || err "dup role"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --staging) STAGING=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --debug-file) DEBUG=true; DEBUG_FILE="$2"; shift 2 ;;
        --help|-h) usage 0 ;;
        --*) err "Unknown: $1" ;;
        *) err "Unexpected: $1" ;;
    esac
done
[[ -z "$ROLE" ]] && usage 1

run() {
    dbg "EXEC: $*"
    if $DRY_RUN; then log "DRY: $*"; else log "$*"; "$@"; fi
}
confirm() {
    $FORCE && return 0
    echo -en "${Y}Proceed? [y/N]${N} "; read -r a
    [[ "$a" =~ ^[Yy]$ ]] || err "Aborted"
}
prompt() {
    local var_name="$1"; local default="$2"; local label="$3"
    read -rp "$label: " -e val
    val="${val:-$default}"
    printf -v "$var_name" '%s' "$val"
}

# ============================================================
# Detection: Check for existing Remnawave components
# ============================================================
# Returns via global variables:
#   HAS_PANEL_NGINX, HAS_NODE_NGINX, HAS_PANEL_DIR, HAS_NODE_DIR
detect_existing_setup() {
    HAS_PANEL_NGINX=false
    HAS_NODE_NGINX=false
    HAS_PANEL_DIR=false
    HAS_NODE_DIR=false

    # Check nginx containers
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "remnawave-panel-nginx"; then
        HAS_PANEL_NGINX=true
    fi
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "remnawave-node-nginx"; then
        HAS_NODE_NGINX=true
    fi
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "remnawave-unified-nginx"; then
        # Unified nginx means both Panel and Node nginx are present
        HAS_PANEL_NGINX=true
        HAS_NODE_NGINX=true
    fi

    # Check directories
    [[ -d "/opt/remnawave" ]] && HAS_PANEL_DIR=true
    [[ -d "/opt/remnanode" ]] && HAS_NODE_DIR=true

    debug_vars "Existing setup" HAS_PANEL_NGINX HAS_NODE_NGINX HAS_PANEL_DIR HAS_NODE_DIR
}

# Upgrade to unified nginx when both Panel and Node nginx exist
upgrade_to_unified_nginx() {
    log "=== Upgrading to Unified Nginx ==="
    warn "Detected both Panel and Node nginx — upgrading to unified container"

    local pd="/opt/remnawave/nginx"

    # Stop old containers
    if $HAS_PANEL_NGINX; then
        dbg "Stopping remnawave-panel-nginx..."
        run "docker stop remnawave-panel-nginx 2>/dev/null || true"
        run "docker rm remnawave-panel-nginx 2>/dev/null || true"
    fi
    if $HAS_NODE_NGINX; then
        dbg "Stopping remnawave-node-nginx..."
        run "docker stop remnawave-node-nginx 2>/dev/null || true"
        run "docker rm remnawave-node-nginx 2>/dev/null || true"
    fi

    # Ensure Node SSL directory exists
    run "mkdir -p /opt/remnanode/ssl"

    # Generate QUIC host key if needed
    if [[ ! -f "/opt/remnanode/ssl/quic_host.key" ]]; then
        dbg "Generating QUIC host key..."
        run "openssl rand -out /opt/remnanode/ssl/quic_host.key 32"
    fi

    # Create stub.html
    cat > "$pd/stub.html" <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet,noimageindex">
<title>Coming Soon</title>
<style>body{font-family:system-ui,sans-serif;text-align:center;padding:60px 20px;background:#f5f5f5}
h1{color:#333;font-size:24px}p{color:#666}</style></head>
<body><h1>Coming Soon</h1><p>This page will be available soon.</p></body></html>
EOF

    # Generate unified nginx config
    cat > "$pd/nginx.conf" <<EOF
# Panel upstream
upstream remnawave {
    server remnawave:3000;
}

# Panel server block
server {
    server_name ${PANEL_DOMAIN};
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http2 on;
    http3 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types application/atom+xml application/geo+json application/javascript application/x-javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/xhtml+xml application/xml font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;
}

# Node server block - VLESS + XHTTP3 proxy
server {
    listen 80; listen [::]:80;
    server_name $NODE_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl; listen [::]:443 ssl;
    listen 443 quic reuseport; listen [::]:443 quic reuseport;
    server_name $NODE_DOMAIN;
    root /var/www/html; index index.html;
    http2 on; http3 on;
    ssl_early_data on;
    quic_retry on;
    quic_gso on;
    quic_host_key /etc/nginx/ssl/quic_host.key;

    ssl_certificate "/etc/nginx/ssl/node/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/node/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/node/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    client_header_timeout 60s; keepalive_timeout 75s;

    location /api/v1 {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m; grpc_read_timeout 315; grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }
    location / {
        add_header X-Robots-Tag "noindex,nofollow,noarchive,nosnippet,noimageindex" always;
        add_header Alt-Svc 'h3=":443"; ma=86400' always;
    }
}
EOF

    # Add Sub server block if needed
    if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
        cat >> "$pd/nginx.conf" <<EOF

# Sub server block
server {
    server_name ${SUB_DOMAIN};
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/sub/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
}
EOF
    fi

    # Default reject server block
    cat >> "$pd/nginx.conf" <<EOF

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF

    # Unified docker-compose.yml
    cat > "$pd/docker-compose.yml" <<EOF
services:
  remnawave-unified-nginx:
    image: macbre/nginx-http3:latest
    container_name: remnawave-unified-nginx
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
      - ./dhparam.pem:/etc/nginx/ssl/dhparam.pem:ro
      - /opt/remnanode/ssl:/etc/nginx/ssl/node:ro
      - /dev/shm:/dev/shm:ro
      - ./stub.html:/var/www/html/index.html:ro
    restart: always
EOF

    # Add sub cert volume if needed
    if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
        sed -i '/- \/opt\/remnanode\/ssl/a\      - ./sub:/etc/nginx/ssl/sub:ro' "$pd/docker-compose.yml"
    fi

    # Start unified nginx
    run "cd $pd && docker compose up -d"
    ok "Unified Nginx started (Panel + Node merged)"
}

# ============================================================
# STEP 0: Interactive Configuration
# ============================================================
step_config() {
    log "=== Configuration ==="

    # Common
    prompt EMAIL "" "Let's Encrypt email"
    [[ -z "$EMAIL" ]] && err "Email is required"

    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        prompt NODE_DOMAIN "" "Node domain (e.g., node.example.com)"
        [[ -z "$NODE_DOMAIN" ]] && err "Node domain is required"
        prompt NODE_PORT "2222" "Node API port (only for Panel → Node communication)"
    fi

    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        prompt PANEL_DOMAIN "" "Panel domain (e.g., panel.example.com)"
        [[ -z "$PANEL_DOMAIN" ]] && err "Panel domain is required"

        # SUB_PUBLIC_DOMAIN: always ends with /api/sub
        # Default = panel domain, user can override with separate subdomain
        prompt SUB_DOMAIN "$PANEL_DOMAIN" "Subscription domain (default: panel domain)"
        SUB_PUBLIC_DOMAIN="${SUB_DOMAIN}/api/sub"
        log "SUB_PUBLIC_DOMAIN will be: $SUB_PUBLIC_DOMAIN"
    fi

    # PANEL_HOST only needed for node-only role (not panel+node where it's local)
    if [[ "$ROLE" == "node" ]]; then
        prompt PANEL_HOST "" "Panel server IP address"
        [[ -z "$PANEL_HOST" ]] && err "Panel host is required"
    fi

    echo ""
    log "Configuration summary:"
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        log "  Panel:            https://$PANEL_DOMAIN"
        log "  SUB_PUBLIC_DOMAIN: $SUB_PUBLIC_DOMAIN"
    fi
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        log "  Node:             $NODE_DOMAIN"
        log "  Node API port:    $NODE_PORT"
    fi
    [[ "$ROLE" == "node" ]] && log "  Panel IP:         $PANEL_HOST"
    log "  Email:            $EMAIL"
    debug_vars "Config" ROLE EMAIL NODE_DOMAIN NODE_PORT PANEL_DOMAIN SUB_DOMAIN SUB_PUBLIC_DOMAIN PANEL_HOST
    echo ""
    confirm "Apply this configuration?"
}

# ============================================================
# STEP -1: Full cleanup of all Remnawave remnants
# ============================================================
step_check_previous() {
    log "=== Check previous installation ==="

    local found=false
    local panel_dir="/opt/remnawave"
    local node_dir="/opt/remnanode"

    # Check directories
    if [[ -d "$panel_dir" ]]; then warn "Found $panel_dir"; found=true; fi
    if [[ -d "$node_dir" ]]; then warn "Found $node_dir"; found=true; fi

    # Check ALL containers (running + stopped)
    local containers
    containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "remnawave|remnanode|panel-nginx|unified-nginx" || true)
    if [[ -n "$containers" ]]; then warn "Found containers: $containers"; found=true; fi

    # Check volumes
    local volumes
    volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep -E "remnawave|remnanode" || true)
    [[ -n "$volumes" ]] && { warn "Found volumes: $volumes"; found=true; }

    # Check networks
    local networks
    networks=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -E "remnawave" || true)
    [[ -n "$networks" ]] && { warn "Found networks: $networks"; found=true; }

    # Check images
    local images
    images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "remnawave|remnanode" || true)
    [[ -n "$images" ]] && { warn "Found images: $images"; found=true; }

    # Check nginx configs
    local nginx_conf="/etc/nginx/conf.d"
    local nginx_remnants=""
    if [[ -d "$nginx_conf" ]]; then
        nginx_remnants=$(grep -rl "remnawave\|remnanode\|xrxh" "$nginx_conf" 2>/dev/null || true)
    fi
    [[ -n "$nginx_remnants" ]] && { warn "Found nginx configs: $nginx_remnants"; found=true; }

    # Check systemd services
    local services
    services=$(systemctl list-units --all --plain --no-legend 2>/dev/null | grep -E "remnawave|remnanode" | awk '{print $1}' || true)
    [[ -n "$services" ]] && { warn "Found systemd services: $services"; found=true; }

    # Check socket files
    local sockets=""
    [[ -e "/dev/shm/xrxh.socket" ]] && { sockets+=" /dev/shm/xrxh.socket"; found=true; }
    [[ -n "$sockets" ]] && warn "Found sockets:$sockets"

    if ! $found; then
        ok "No previous installation found"
        return 0
    fi

    dbg "Previous install found: dirs=$found, containers=$containers, volumes=$volumes, networks=$networks, images=$images"
    echo ""
    
    # Check if this is an incremental installation (Panel + Node on same server)
    local has_panel=false
    local has_node=false
    
    # Check for existing Panel installation
    if [[ -d "$panel_dir" ]] || docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "remnawave"; then
        has_panel=true
    fi
    
    # Check for existing Node installation
    if [[ -d "$node_dir" ]] || docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "remnanode"; then
        has_node=true
    fi
    
    # If installing Panel and Node already exists, or vice versa, offer upgrade
    if [[ "$ROLE" == "panel" && "$has_node" == "true" ]]; then
        warn "Node installation detected on this server"
        confirm "Upgrade to unified nginx (merges Panel + Node)?" || err "Aborted"
        # Don't cleanup - we'll upgrade in step_panel_nginx
        return 0
    fi
    
    if [[ "$ROLE" == "node" && "$has_panel" == "true" ]]; then
        warn "Panel installation detected on this server"
        confirm "Upgrade to unified nginx (merges Panel + Node)?" || err "Aborted"
        # Don't cleanup - we'll upgrade in step_node_nginx
        return 0
    fi
    
    # If installing panel+node and both exist, offer upgrade
    if [[ "$ROLE" == "panel+node" && "$has_panel" == "true" && "$has_node" == "true" ]]; then
        warn "Both Panel and Node installations detected"
        confirm "Upgrade to unified nginx?" || err "Aborted"
        # Don't cleanup - we'll upgrade in step_panel_nginx
        return 0
    fi
    
    # Full cleanup for fresh installation
    warn "Previous installation detected — full cleanup"
    confirm "Remove ALL Remnawave/Remnanode data?" || err "Aborted"

    # 1. Stop all containers
    if [[ -n "$containers" ]]; then
        log "Stopping and removing containers..."
        for c in $containers; do
            run "docker stop $c 2>/dev/null || true"
            run "docker rm $c 2>/dev/null || true"
        done
    fi

    # 2. Remove volumes
    if [[ -n "$volumes" ]]; then
        log "Removing volumes..."
        for v in $volumes; do
            run "docker volume rm $v 2>/dev/null || true"
        done
    fi

    # 3. Remove networks
    if [[ -n "$networks" ]]; then
        log "Removing networks..."
        for n in $networks; do
            run "docker network rm $n 2>/dev/null || true"
        done
    fi

    # 4. Remove images
    if [[ -n "$images" ]]; then
        log "Removing images..."
        for img in $images; do
            run "docker rmi $img 2>/dev/null || true"
        done
    fi

    # 5. Remove directories
    if [[ -d "$panel_dir" ]]; then
        run "rm -rf $panel_dir"
        ok "Removed $panel_dir"
    fi
    if [[ -d "$node_dir" ]]; then
        run "rm -rf $node_dir"
        ok "Removed $node_dir"
    fi

    # 6. Remove nginx configs
    if [[ -n "$nginx_remnants" ]]; then
        log "Removing nginx configs..."
        for f in $nginx_remnants; do
            run "rm -f $f"
        done
    fi

    # 7. Remove systemd services
    if [[ -n "$services" ]]; then
        log "Removing systemd services..."
        for s in $services; do
            run "systemctl stop $s 2>/dev/null || true"
            run "systemctl disable $s 2>/dev/null || true"
            run "systemctl reset $s 2>/dev/null || true"
        done
    fi

    # 8. Remove sockets
    [[ -e "/dev/shm/xrxh.socket" ]] && { run "rm -f /dev/shm/xrxh.socket"; ok "Removed socket"; }

    # 9. Docker system prune (dangling)
    log "Pruning dangling Docker data..."
    # Only prune dangling objects older than 24h to avoid affecting other projects
    run "docker system prune -f --filter 'until=24h' 2>/dev/null || docker system prune -f"

    ok "Full cleanup complete"
}

# ============================================================
# STEP 1: Prerequisites
# ============================================================
step_prerequisites() {
    log "=== Prerequisites ==="

    if ! command -v docker &>/dev/null; then
        dbg "Docker not found, installing..."
        run "curl -fsSL https://get.docker.com | sh"
        ok "Docker installed"
    else
        ok "Docker already installed"
        dbg "Docker version: $(docker --version 2>/dev/null || echo 'unknown')"
    fi

    # Verify Docker daemon is actually running
    docker info &>/dev/null || err "Docker daemon is not running or not accessible"
    dbg "Docker daemon OK"

    docker compose version &>/dev/null || err "Docker Compose not found"
    dbg "Docker Compose version: $(docker compose version 2>/dev/null || echo 'unknown')"

    for cmd in curl openssl; do
        command -v "$cmd" &>/dev/null || DEBIAN_FRONTEND=noninteractive run "apt-get update -qq && apt-get install -y -qq $cmd"
    done

    # UFW firewall
    if ! command -v ufw &>/dev/null; then
        dbg "UFW not found, installing..."
        DEBIAN_FRONTEND=noninteractive run "apt-get update -qq && apt-get install -y -qq ufw"
        ok "UFW installed"
    else
        ok "UFW already installed"
        dbg "UFW status: $(ufw status verbose 2>/dev/null | head -1 || echo 'unknown')"
    fi

    # Install acme.sh per official docs
    if ! command -v acme.sh &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive run "apt-get install -y -qq cron socat"
        run "curl https://get.acme.sh | sh -s email='$EMAIL'"
        source ~/.bashrc 2>/dev/null || true

        # Verify acme.sh cron job exists
        if ! crontab -l 2>/dev/null | grep -q acme.sh; then
            warn "acme.sh cron job not found — attempting to install"
            acme.sh --install-cronjob 2>&1 || warn "Could not install cron job; auto-renewal will not work"
        fi
    fi

    # Create directories BEFORE generating DH params
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        run "mkdir -p /opt/remnawave/nginx"
    fi
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        run "mkdir -p /opt/remnanode/nginx"
        run "mkdir -p /opt/remnanode/ssl"
    fi

    # Generate DH parameters for Nginx
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ ! -f /opt/remnawave/nginx/dhparam.pem ]]; then
            log "Generating DH parameters for Panel (this may take a minute)..."
            run "openssl dhparam -out /opt/remnawave/nginx/dhparam.pem 2048"
        fi
    fi
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if [[ ! -f /opt/remnanode/nginx/dhparam.pem ]]; then
            log "Generating DH parameters for Node (this may take a minute)..."
            run "openssl dhparam -out /opt/remnanode/nginx/dhparam.pem 2048"
        fi
    fi

    ok "Dependencies OK"
}

# ============================================================
# STEP 1.5: UFW Firewall Configuration
# ============================================================
step_ufw() {
    log "=== UFW Firewall ==="

    dbg "Configuring UFW for role: $ROLE"

    # Default policies
    run "ufw default deny incoming"
    run "ufw default allow outgoing"

    # Allow SSH (critical — don't lock ourselves out)
    if ! ufw status | grep -q "22.*ALLOW"; then
        run "ufw allow 22/tcp"
        ok "UFW: SSH (22/tcp) allowed"
    fi

    # Allow HTTP for Let's Encrypt validation
    if ! ufw status | grep -q "80.*ALLOW"; then
        run "ufw allow 80/tcp"
        ok "UFW: HTTP (80/tcp) allowed"
    fi

    # Allow HTTPS
    if ! ufw status | grep -q "443.*ALLOW"; then
        run "ufw allow 443/tcp"
        ok "UFW: HTTPS (443/tcp) allowed"
    fi

    # Panel-specific rules
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        # Panel web UI (behind nginx, so port 3000 is internal)
        dbg "Panel role: port 3000 is internal (behind nginx)"
    fi

    # Node-specific rules
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        # Node API port (Panel → Node communication) - restrict to Panel IP only
        if [[ "$ROLE" == "node" ]]; then
            # node-only: PANEL_HOST is the Panel server IP
            if ! ufw status | grep -q "${NODE_PORT}.*ALLOW"; then
                run "ufw allow from ${PANEL_HOST} to any port ${NODE_PORT} proto tcp"
                ok "UFW: Node API (${NODE_PORT}/tcp) allowed from $PANEL_HOST only"
            fi
        fi
        # panel+node: Panel is local, port 2222 is internal (localhost)
        if [[ "$ROLE" == "panel+node" ]]; then
            dbg "Panel+node mode: Node API port 2222 is internal (localhost)"
        fi
    fi

    # Enable UFW
    if ! ufw status | grep -q "Status: active"; then
        log "Enabling UFW..."
        echo "y" | run "ufw enable"
        ok "UFW enabled"
    else
        ok "UFW already active"
    fi

    dbg "UFW rules:"
    ufw status numbered 2>/dev/null | while read -r line; do dbg "  $line"; done
}

# ============================================================
# STEP 2: SSL Certificate (acme.sh per official docs)
# ============================================================
step_ssl() {
    local domain="${1:?}"; local dir="${2:?}"
    log "=== SSL: $domain -> $dir ==="

    run "mkdir -p $dir"
    local key="$dir/privkey.key"; local pem="$dir/fullchain.pem"

    if [[ -f "$key" && -f "$pem" ]]; then
        warn "Certs exist in $dir"
        confirm "Regenerate?" || { ok "Skipped"; return 0; }
    fi

    # Stop system nginx on port 80 (if running)
    run "nginx -s stop 2>/dev/null || true"
    sleep 1

    # Issue certificate per official docs
    local acme_server="https://acme-v02.api.letsencrypt.org/directory"
    $STAGING && acme_server="https://acme-staging-v02.api.letsencrypt.org/directory"
    dbg "acme.sh server: $acme_server"
    dbg "acme.sh command: acme.sh --issue --standalone -d '$domain' --key-file '$key' --fullchain-file '$pem' --alpn --tlsport 8443 --force --server '$acme_server'"
    run "acme.sh --issue --standalone -d '$domain' \
        --key-file '$key' --fullchain-file '$pem' \
        --alpn --tlsport 8443 --force \
        --server '$acme_server'"
    dbg "SSL key exists: $(ls -la '$key' 2>/dev/null || echo 'MISSING')"
    dbg "SSL cert exists: $(ls -la '$pem' 2>/dev/null || echo 'MISSING')"

    # Determine correct nginx container for reload
    # Panel nginx is 'remnawave-panel-nginx', Node nginx is 'remnawave-node-nginx'
    # In panel+node mode: unified nginx is 'remnawave-unified-nginx'
    local nginx_container
    if [[ "$ROLE" == "panel+node" ]]; then
        nginx_container="remnawave-unified-nginx"
    elif [[ "$domain" == "${NODE_DOMAIN:-}" ]]; then
        nginx_container="remnawave-node-nginx"
    else
        nginx_container="remnawave-panel-nginx"
    fi

    # Install cert with auto-renew hook
    run "acme.sh --install-cert -d '$domain' \
        --key-file '$key' --fullchain-file '$pem' \
        --reloadcmd 'docker exec $nginx_container nginx -s reload 2>/dev/null || true'"

    ok "SSL for $domain"
}

# ============================================================
# STEP 3: Panel (official docs: download docker-compose + .env)
# ============================================================
step_panel() {
    log "=== Panel (Step 1-2 from docs) ==="
    local pd="/opt/remnawave"

    # Step 1: Create directory and download files (exact commands from docs)
    run "mkdir -p $pd"
    run "curl -o $pd/docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
    run "curl -o $pd/.env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

    # Step 2: Generate secrets (exact commands from official docs)
    dbg "Panel .env path: $pd/.env"
    if ! $DRY_RUN; then
        dbg "Generating JWT_AUTH_SECRET (hex 64)"
        sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" "$pd/.env"
        dbg "Generating JWT_API_TOKENS_SECRET (hex 64)"
        sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" "$pd/.env"
    else
        log "DRY: sed -i s/^JWT_AUTH_SECRET=.../"
        log "DRY: sed -i s/^JWT_API_TOKENS_SECRET=.../"
    fi

    # Metrics and Webhook secrets
    local mp wh pg
    mp=$(openssl rand -hex 64)
    wh=$(openssl rand -hex 64)
    pg=$(openssl rand -hex 24)

    if ! $DRY_RUN; then
        sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$mp/" "$pd/.env"
        sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$wh/" "$pd/.env"
    else
        log "DRY: sed METRICS_PASS and WEBHOOK_SECRET_HEADER"
    fi

    # Change Postgres password (exact from docs)
      # Official: pw=$(openssl rand -hex 24) && sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env \
      #   && sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:[^@]*@\)\(@.*\)|\1$pw\2|" .env
      if ! $DRY_RUN; then
          sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pg/" "$pd/.env"
          sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:[^@]*@\)\(@.*\)|\1${pg}\2|" "$pd/.env"
      else
          log "DRY: sed POSTGRES_PASSWORD and DATABASE_URL"
      fi

    # Set domains (per official docs)
    if ! $DRY_RUN; then
        sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=${PANEL_DOMAIN}|" "$pd/.env"
        sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_PUBLIC_DOMAIN}|" "$pd/.env"

        # PANEL_DOMAIN is optional - set it if it exists in .env.sample
        if grep -q "^PANEL_DOMAIN=" "$pd/.env"; then
            sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "$pd/.env"
        fi
    else
        log "DRY: sed FRONT_END_DOMAIN, SUB_PUBLIC_DOMAIN, PANEL_DOMAIN"
    fi

    # Add SSL volume for Panel (per docs: mount /opt/remnawave/nginx as SSL source)
    # This lets Panel read certs and push them to Node during config updates
    if ! $DRY_RUN && ! grep -q "/var/lib/remnawave/configs/xray/ssl" "$pd/docker-compose.yml"; then
        dbg "Adding SSL volume mount to docker-compose.yml"
        sed -i '/^  remnawave:/,/^[^ ]/{/volumes:/a\      - /opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl:ro
}' "$pd/docker-compose.yml"
    fi

    # Debug: show final .env state (masking secrets)
    if $DEBUG; then
        dbg "--- Panel .env (secrets masked) ---"
        grep -E '^(JWT_AUTH_SECRET|JWT_API_TOKENS_SECRET|METRICS_PASS|WEBHOOK_SECRET_HEADER|POSTGRES_PASSWORD|DATABASE_URL|FRONT_END_DOMAIN|SUB_PUBLIC_DOMAIN|PANEL_DOMAIN)=' "$pd/.env" 2>/dev/null | sed 's/=.*/=****/' | while read -r line; do dbg "  $line"; done
    fi

    ok "Panel configured in $pd (per official docs)"
    log "  FRONT_END_DOMAIN:  $PANEL_DOMAIN"
    log "  SUB_PUBLIC_DOMAIN: $SUB_PUBLIC_DOMAIN"
}

# ============================================================
# STEP 4: Panel Nginx (official docs template)
# ============================================================
# In panel+node mode: creates a UNIFIED nginx with server blocks for Panel, Node, and optionally Sub
# In panel-only mode: creates nginx for Panel only
step_panel_nginx() {
    local pd="/opt/remnawave/nginx"
    log "=== Panel Nginx ==="

    run "mkdir -p $pd"

    # In panel+node mode: unified nginx (single container, multiple server blocks)
    # In panel-only mode: standard Panel nginx
    local unified=false
    [[ "$ROLE" == "panel+node" ]] && unified=true

    # Detect existing setup for panel-only mode
    if ! $unified; then
        detect_existing_setup
        # If Node nginx already exists on this server, upgrade to unified nginx
        if $HAS_NODE_NGINX; then
            warn "Node nginx detected on this server"
            confirm "Upgrade to unified nginx (merges Panel + Node)?" || err "Aborted"
            upgrade_to_unified_nginx
            return 0
        fi
    fi

    # Generate nginx config
    if $unified; then
        # UNIFIED nginx config for panel+node mode
        cat > "$pd/nginx.conf" <<EOF
# Panel upstream
upstream remnawave {
    server remnawave:3000;
}

# Panel server block
server {
    server_name ${PANEL_DOMAIN};
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http2 on;
    http3 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SSL Configuration
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types application/atom+xml application/geo+json application/javascript application/x-javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/xhtml+xml application/xml font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;
}

# Node server block - VLESS + XHTTP3 proxy
server {
    listen 80; listen [::]:80;
    server_name $NODE_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl; listen [::]:443 ssl;
    listen 443 quic reuseport; listen [::]:443 quic reuseport;
    server_name $NODE_DOMAIN;
    root /var/www/html; index index.html;
    http2 on; http3 on;
    ssl_early_data on;
    quic_retry on;
    quic_gso on;
    quic_host_key /etc/nginx/ssl/quic_host.key;

    ssl_certificate "/etc/nginx/ssl/node/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/node/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/node/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    client_header_timeout 60s; keepalive_timeout 75s;

    location /api/v1 {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m; grpc_read_timeout 315; grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }
    location / {
        add_header X-Robots-Tag "noindex,nofollow,noarchive,nosnippet,noimageindex" always;
        add_header Alt-Svc 'h3=":443"; ma=86400' always;
    }
}
EOF

        # Add Sub server block if SUB_DOMAIN differs from PANEL_DOMAIN
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            cat >> "$pd/nginx.conf" <<EOF

# Sub server block
server {
    server_name ${SUB_DOMAIN};
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/sub/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
}
EOF
        fi

        # Default reject server block
        cat >> "$pd/nginx.conf" <<EOF

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF

        # Unified docker-compose.yml
        cat > "$pd/docker-compose.yml" <<EOF
services:
  remnawave-unified-nginx:
    image: macbre/nginx-http3:latest
    container_name: remnawave-unified-nginx
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
      - ./dhparam.pem:/etc/nginx/ssl/dhparam.pem:ro
      - /opt/remnanode/ssl:/etc/nginx/ssl/node:ro
      - /dev/shm:/dev/shm:ro
      - ./stub.html:/var/www/html/index.html:ro
    restart: always
EOF

        # Add sub cert volume if needed
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            sed -i '/- \/opt\/remnanode\/ssl/a\      - ./sub:/etc/nginx/ssl/sub:ro' "$pd/docker-compose.yml"
        fi

        # Create stub.html for Node
        cat > "$pd/stub.html" <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet,noimageindex">
<title>Coming Soon</title>
<style>body{font-family:system-ui,sans-serif;text-align:center;padding:60px 20px;background:#f5f5f5}
h1{color:#333;font-size:24px}p{color:#666}</style></head>
<body><h1>Coming Soon</h1><p>This page will be available soon.</p></body></html>
EOF

        # Generate QUIC host key if needed
        if [[ ! -f "/opt/remnanode/ssl/quic_host.key" ]]; then
            dbg "Generating QUIC host key..."
            run "mkdir -p /opt/remnanode/ssl && openssl rand -out /opt/remnanode/ssl/quic_host.key 32"
        fi

        ok "Unified Nginx configured (Panel + Node + $( [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]] && echo "Sub" || echo "0" ))"
    else
        # Standard Panel-only nginx
        local nginx_bind="0.0.0.0"

        cat > "$pd/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    server_name ${PANEL_DOMAIN};
    listen ${nginx_bind}:443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    listen ${nginx_bind}:443 quic reuseport;
    listen [::]:443 quic reuseport;
    http2 on;
    http3 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SSL Configuration (Mozilla Intermediate Guidelines)
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types application/atom+xml application/geo+json application/javascript application/x-javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/xhtml+xml application/xml font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF

        # If SUB_DOMAIN differs from PANEL_DOMAIN, add separate server block
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            cat >> "$pd/nginx.conf" <<EOF

server {
    server_name ${SUB_DOMAIN};
    listen ${nginx_bind}:443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    ssl_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/sub/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/sub/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
}
EOF
        fi

        # docker-compose.yml - per official docs, adapted
        cat > "$pd/docker-compose.yml" <<EOF
services:
  remnawave-panel-nginx:
      image: macbre/nginx-http3:latest
      container_name: remnawave-panel-nginx
      hostname: remnawave-panel-nginx
      volumes:
        - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
        - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
        - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
        - ./dhparam.pem:/etc/nginx/ssl/dhparam.pem:ro
      ports:
        - "${nginx_bind}:443:443/tcp"
        - "${nginx_bind}:443:443/udp"
      restart: always
      networks:
        - remnawave-network
networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

        # If SUB_DOMAIN differs, mount sub certs too
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            # Add sub cert volume mount
            sed -i '/- .\/dhparam.pem/a\      - ./sub:/etc/nginx/ssl/sub:ro' "$pd/docker-compose.yml"
        fi

        ok "Panel Nginx configured in $pd"
    fi
}

# ============================================================
# STEP 5: Node Nginx (VLESS + XHTTP3 reverse proxy)
# ============================================================
# In panel+node mode: SKIPPED (unified nginx handles Node traffic)
# In node-only mode: creates nginx for Node only (or upgrades if Panel nginx exists)
step_node_nginx() {
    # In panel+node mode, unified nginx already handles Node traffic
    if [[ "$ROLE" == "panel+node" ]]; then
        ok "Node Nginx skipped (handled by unified nginx)"
        return 0
    fi

    # Detect existing setup
    detect_existing_setup

    # If Panel nginx already exists on this server, upgrade to unified nginx
    if $HAS_PANEL_NGINX; then
        warn "Panel nginx detected on this server"
        confirm "Upgrade to unified nginx (merges Panel + Node)?" || err "Aborted"
        upgrade_to_unified_nginx
        return 0
    fi

    local nginx_dir="/opt/remnanode/nginx"
    log "=== Node Nginx (VLESS + XHTTP3) ==="

    run "mkdir -p $nginx_dir"

    # Generate QUIC host key
    if [[ ! -f "/opt/remnanode/ssl/quic_host.key" ]]; then
        dbg "Generating QUIC host key..."
        run "mkdir -p /opt/remnanode/ssl && openssl rand -out /opt/remnanode/ssl/quic_host.key 32"
    else
        dbg "QUIC host key already exists"
    fi

    # Stub page for HTTP/1.1 requests
    cat > "$nginx_dir/stub.html" <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet,noimageindex">
<title>Coming Soon</title>
<style>body{font-family:system-ui,sans-serif;text-align:center;padding:60px 20px;background:#f5f5f5}
h1{color:#333;font-size:24px}p{color:#666}</style></head>
<body><h1>Coming Soon</h1><p>This page will be available soon.</p></body></html>
EOF

    # nginx.conf for Node - QUIC/XHTTP3 proxy
    cat > "$nginx_dir/nginx.conf" <<EOF
server {
    listen 80; listen [::]:80;
    server_name $NODE_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl; listen [::]:443 ssl;
    listen 443 quic reuseport; listen [::]:443 quic reuseport;
    server_name $NODE_DOMAIN;
    root /var/www/html; index index.html;
    http2 on; http3 on;
    ssl_early_data on;
    quic_retry on;
    quic_gso on;
    quic_host_key /etc/nginx/ssl/quic_host.key;

    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_dhparam /etc/nginx/ssl/dhparam.pem;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    client_header_timeout 60s; keepalive_timeout 75s;

    location /api/v1 {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m; grpc_read_timeout 315; grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }
    location / {
        add_header X-Robots-Tag "noindex,nofollow,noarchive,nosnippet,noimageindex" always;
        add_header Alt-Svc 'h3=":443"; ma=86400' always;
    }
}
EOF

    # docker-compose.yml for Node nginx (node-only: host mode)
    cat > "$nginx_dir/docker-compose.yml" <<EOF
services:
  remnawave-node-nginx:
      image: macbre/nginx-http3:latest
      container_name: remnawave-node-nginx
      network_mode: host
      volumes:
        - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
        - ./stub.html:/var/www/html/index.html:ro
        - /opt/remnanode/ssl:/etc/nginx/ssl:ro
        - /dev/shm:/dev/shm:ro
      restart: always
EOF

    ok "Node Nginx configured in $nginx_dir"
}

# ============================================================
# STEP 6: Node (per official docs - docker-compose from Panel UI)
# ============================================================
step_node() {
    local nd="/opt/remnanode"
    log "=== Node ==="

    run "mkdir -p $nd"
    run "mkdir -p /var/log/remnanode"

    dbg "Node directory: $nd, ROLE: $ROLE"

    # For panel+node role, we need to guide the user to copy docker-compose from Panel
    if [[ "$ROLE" == "panel+node" ]]; then
        dbg "panel+node mode: Panel is local (127.0.0.1:3000)"
        echo ""
        log "=== Node docker-compose.yml ==="
        log "Per official docs, you need to copy docker-compose.yml from Panel UI:"
        log ""
        log "  1. Open Panel: https://$PANEL_DOMAIN"
        log "  2. Go to Nodes → Management → Click + (Add Node)"
        log "  3. Fill in:"
        log "     - Node Name: (your choice)"
        log "     - Address:   $NODE_DOMAIN"
        log "     - Port:      $NODE_PORT"
        log "  4. Click 'Copy docker-compose.yml'"
        log "  5. Paste the content below:"
        echo ""

        # Read docker-compose from clipboard or file
        local dc_content
        echo -n "Paste docker-compose.yml content (end with empty line): "
        dc_content=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            dc_content+="$line"$'\n'
        done

        if [[ -z "$dc_content" ]]; then
            warn "No content pasted, generating default docker-compose.yml"
            # Generate default based on docs (panel+node: Panel is local)
            dc_content="services:
  remnanode:
    container_name: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    environment:
      - NODE_PORT=$NODE_PORT
      - PANEL_HOST=127.0.0.1
      - PANEL_PORT=3000
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - /dev/shm:/dev/shm:rw
      - /opt/remnanode/ssl:/var/lib/remnawave/configs/xray/ssl:ro
"
        fi

        echo "$dc_content" > "$nd/docker-compose.yml"
    else
        # For node-only role, PANEL_HOST was already asked in step_config
        dbg "node-only mode: PANEL_HOST=$PANEL_HOST"
        echo ""
        log "=== Node docker-compose.yml ==="
        log "Per official docs, copy docker-compose.yml from Panel UI:"
        log "  1. Open Panel → Nodes → Management → Click +"
        log "  2. Fill Address=$NODE_DOMAIN, Port=$NODE_PORT"
        log "  3. Click 'Copy docker-compose.yml'"
        log ""

        local dc_content
        echo -n "Paste docker-compose.yml content (end with empty line): "
        dc_content=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            dc_content+="$line"$'\n'
        done

        if [[ -z "$dc_content" ]]; then
            warn "No content pasted, generating default"
            dc_content="services:
  remnanode:
    container_name: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    environment:
      - NODE_PORT=$NODE_PORT
      - PANEL_HOST=$PANEL_HOST
      - PANEL_PORT=3000
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - /dev/shm:/dev/shm:rw
      - /opt/remnanode/ssl:/var/lib/remnawave/configs/xray/ssl:ro
"
        fi

        echo "$dc_content" > "$nd/docker-compose.yml"
    fi

    ok "Node configured in $nd"
}

# ============================================================
# STEP 7: Start services
# ============================================================
step_start() {
    log "=== Starting services ==="

    dbg "Starting services for role: $ROLE"

    # Create Docker network (needed by official docker-compose)
    if ! docker network inspect remnawave-network &>/dev/null; then
        dbg "Creating remnawave-network..."
        run "docker network create remnawave-network"
        ok "Created remnawave-network"
    else
        ok "remnawave-network already exists"
        dbg "remnawave-network: $(docker network inspect remnawave-network --format '{{.Driver}}' 2>/dev/null || echo 'unknown')"
    fi

    # Panel (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnawave/docker-compose.yml" ]]; then
            dbg "Panel docker-compose.yml exists, checking if running..."
            if docker ps --format "{{.Names}}" | grep -q remnawave; then
                warn "Panel already running, skipping"
            else
                dbg "Starting Panel..."
                run "cd /opt/remnawave && docker compose up -d"
                ok "Panel started"
                dbg "Panel containers: $(docker ps --format '{{.Names}} {{.Status}}' | grep remnawave || echo 'none')"
            fi
        fi
    fi

    # Panel nginx (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnawave/nginx/docker-compose.yml" ]]; then
            if [[ "$ROLE" == "panel+node" ]]; then
                # Unified nginx in panel+node mode
                local nginx_name="remnawave-unified-nginx"
                if docker ps --format "{{.Names}}" | grep -q "$nginx_name"; then
                    warn "$nginx_name already running, skipping"
                else
                    dbg "Starting unified nginx..."
                    run "cd /opt/remnawave/nginx && docker compose up -d"
                    ok "Unified Nginx started"
                    dbg "Unified nginx container: $(docker ps --format '{{.Names}} {{.Status}}' | grep remnawave-unified-nginx || echo 'none')"
                fi
            else
                # Panel-only nginx
                if docker ps --format "{{.Names}}" | grep -q remnawave-panel-nginx; then
                    warn "remnawave-panel-nginx already running, skipping"
                else
                    dbg "Starting Panel nginx..."
                    run "cd /opt/remnawave/nginx && docker compose up -d"
                    ok "Panel Nginx started"
                    dbg "Panel nginx container: $(docker ps --format '{{.Names}} {{.Status}}' | grep remnawave-panel-nginx || echo 'none')"
                fi
            fi
        fi
    fi

    # Node nginx (node-only role only — panel+node uses unified nginx)
    if [[ "$ROLE" == "node" ]]; then
        if [[ -f "/opt/remnanode/nginx/docker-compose.yml" ]]; then
            if docker ps --format "{{.Names}}" | grep -q remnawave-node-nginx; then
                warn "remnawave-node-nginx already running, skipping"
            else
                dbg "Starting Node nginx..."
                run "cd /opt/remnanode/nginx && docker compose up -d"
                ok "Node Nginx started"
                dbg "Node nginx container: $(docker ps --format '{{.Names}} {{.Status}}' | grep remnawave-node-nginx || echo 'none')"
            fi
        fi
    fi

    # Node (node and panel+node roles)
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnanode/docker-compose.yml" ]]; then
            dbg "Node docker-compose.yml exists, checking if running..."
            if docker ps --format "{{.Names}}" | grep -q remnanode; then
                warn "remnanode already running, skipping"
            else
                dbg "Starting Node..."
                run "cd /opt/remnanode && docker compose up -d"
                ok "Node started"
                dbg "Node container: $(docker ps --format '{{.Names}} {{.Status}}' | grep remnanode || echo 'none')"
            fi
        fi
    fi
}

# ============================================================
# STEP 8: Verify
# ============================================================
step_verify() {
    log "=== Verification ==="
    dbg "Verifying services for role: $ROLE"
    docker ps --format "table {{.Names}}\t{{.Status}}"

    # Check Panel nginx
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        local nginx_container
        if [[ "$ROLE" == "panel+node" ]]; then
            nginx_container="remnawave-unified-nginx"
        else
            nginx_container="remnawave-panel-nginx"
        fi

        if docker ps --format "{{.Names}}" | grep -q "$nginx_container"; then
            local code
            dbg "Checking Panel nginx: curl https://$PANEL_DOMAIN --resolve $PANEL_DOMAIN:443:127.0.0.1 --insecure"
            code=$(curl -s -o /dev/null -w "%{http_code}" "https://$PANEL_DOMAIN" --resolve "$PANEL_DOMAIN:443:127.0.0.1" --insecure 2>/dev/null || echo "000")
            dbg "Panel nginx response code: $code"
            [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]] && ok "Panel Nginx OK ($code)" || warn "Panel Nginx ($code)"
        fi
    fi

    # Check Panel
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnawave; then
            ok "Panel running"
            dbg "Panel logs (last 10):"
            docker logs remnawave 2>&1 | tail -10 | while read -r line; do dbg "  $line"; done
        else
            warn "Panel not running - check: docker logs remnawave"
        fi
    fi

    # Check Node nginx
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        local nginx_container
        if [[ "$ROLE" == "panel+node" ]]; then
            nginx_container="remnawave-unified-nginx"
        else
            nginx_container="remnawave-node-nginx"
        fi

        if docker ps --format "{{.Names}}" | grep -q "$nginx_container"; then
            local code
            dbg "Checking Node nginx: curl https://$NODE_DOMAIN --resolve $NODE_DOMAIN:443:127.0.0.1 --insecure"
            code=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN" --resolve "$NODE_DOMAIN:443:127.0.0.1" --insecure 2>/dev/null || echo "000")
            dbg "Node nginx response code: $code"
            [[ "$code" == "200" || "$code" == "301" ]] && ok "Node Nginx OK ($code)" || warn "Node Nginx ($code)"
        fi
    fi

    # Check Node
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnanode; then
            ok "Node running"
            dbg "Node logs (last 5):"
            docker logs remnanode 2>&1 | tail -5 | while read -r line; do dbg "  $line"; done
        else
            warn "Node not running - check: docker logs remnanode"
        fi
    fi
}

# ============================================================
# STEP 9: Create Admin
# ============================================================
step_create_admin() {
    log "=== Create Admin ==="
    dbg "Creating admin for Panel at: https://$PANEL_DOMAIN"

    # Wait for Panel to be ready
    local retries=12
    local delay=5
    local ready=false

    for i in $(seq 1 $retries); do
        local code
        dbg "Waiting for Panel... attempt $i/$retries"
        code=$(curl -s -o /dev/null -w "%{http_code}" "https://$PANEL_DOMAIN" --resolve "$PANEL_DOMAIN:443:127.0.0.1" --insecure 2>/dev/null || echo "000")
        dbg "Panel health check: HTTP $code"
        if [[ "$code" != "000" ]]; then
            ready=true
            break
        fi
        warn "Waiting for Panel... ($i/$retries)"
        sleep $delay
    done

    if ! $ready; then
        dbg "Panel health check failed after $retries attempts. Container status:"
        docker ps -a --format "{{.Names}} {{.Status}}" | grep remnawave | while read -r line; do dbg "  $line"; done
        dbg "Panel container logs (last 20):"
        docker logs remnawave 2>&1 | tail -20 | while read -r line; do dbg "  $line"; done
        err "Panel did not start in time. Check: docker logs remnawave"
    fi

    echo ""
    ok "Panel is ready!"
    echo ""

    # Prompt for admin credentials
    local admin_user admin_pass admin_pass_confirm
    prompt admin_user "admin" "Admin username"
    prompt admin_pass "" "Admin password"
    prompt admin_pass_confirm "" "Confirm admin password"

    if [[ -z "$admin_user" || -z "$admin_pass" ]]; then
        err "Admin credentials are required"
    fi

    # Validate password complexity (Remnawave requires min 24 chars)
    if [[ ${#admin_pass} -lt 24 ]]; then
        err "Password must be at least 24 characters long (Remnawave requirement)"
    fi

    if [[ "$admin_pass" != "$admin_pass_confirm" ]]; then
        err "Passwords do not match"
    fi

    # Create admin via API per OpenAPI spec:
    # POST /api/auth/register
    # Body: { "username": "string", "password": "string" }
    # Response: { "response": { "accessToken": "string" } }
    # 403: Registration is not allowed
    log "Creating admin user via API..."
    dbg "POST https://$PANEL_DOMAIN/api/auth/register"
    dbg "Body: {\"username\":\"$admin_user\",\"password\":\"****\"}"

    local response
    response=$(curl -s -w "\n%{http_code}" "https://$PANEL_DOMAIN/api/auth/register" \
        --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
        --insecure \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}" 2>/dev/null || echo -e "\n000")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)
    dbg "Admin API response: HTTP $http_code"
    dbg "Admin API body: $body"

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        # Extract accessToken from response per spec
        local access_token
        access_token=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['accessToken'])" 2>/dev/null || true)

        if [[ -n "$access_token" ]]; then
            ok "Admin user '$admin_user' created successfully"
            dbg "Access token received (length: ${#access_token})"
        else
            ok "Admin user '$admin_user' created (token parse skipped)"
        fi

        # Save credentials to a secure file
        local creds_file="/opt/remnawave/.admin-credentials"
        run "mkdir -p /opt/remnawave"
        cat > "$creds_file" <<CREDS
# Remnawave Admin Credentials
# Generated: $(date)
# This file contains your initial admin credentials.
# Keep this file secure and delete it after you've logged in.

ADMIN_USER=$admin_user
ADMIN_PASS=$admin_pass
PANEL_URL=https://$PANEL_DOMAIN
CREDS
        chmod 600 "$creds_file"

        echo ""
        echo "=========================================="
        echo "  Admin Account Created"
        echo "=========================================="
        echo ""
        echo " Panel URL:   https://$PANEL_DOMAIN"
        echo " Username:    $admin_user"
        echo " Password:    $admin_pass"
        echo ""
        echo " Credentials saved to: $creds_file"
        echo " (chmod 600 - only root can read)"
        echo ""
        echo " IMPORTANT: Delete this file after first login!"
        echo "=========================================="
    elif [[ "$http_code" == "403" ]]; then
        warn "Registration is disabled (403 Forbidden) - admin already exists"
        echo ""
        echo "=========================================="
        echo "  Admin Account Already Exists"
        echo "=========================================="
        echo ""
        echo " Options:"
        echo " 1) Create admin manually via browser"
        echo " 2) Reset superadmin via Rescue CLI (removes existing admin)"
        echo " 3) Skip admin creation"
        echo ""
        read -r -p "Choose option [1/2/3]: " admin_choice

        case "$admin_choice" in
            1)
                echo ""
                echo " 1. Open: https://$PANEL_DOMAIN"
                echo " 2. Create admin account (first user = superadmin)"
                echo " 3. Press Enter when done"
                echo ""
                read -r -p "Press Enter after creating admin... "
                ok "Admin created"
                ;;
            2)
                echo ""
                echo "=========================================="
                echo "  Reset Superadmin via Rescue CLI"
                echo "=========================================="
                echo ""
                echo " This will remove the existing superadmin account."
                echo " After reset, you can create a new one via browser."
                echo ""
                read -r -p "Are you sure? [y/N]: " confirm_reset
                if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
                    log "Resetting superadmin via Rescue CLI..."
                    if docker exec -it remnawave cli <<'EOF'
reset superadmin
exit
EOF
                    then
                        ok "Superadmin reset successful"
                        echo ""
                        echo " 1. Open: https://$PANEL_DOMAIN"
                        echo " 2. Create new admin account"
                        echo " 3. Press Enter when done"
                        echo ""
                        read -r -p "Press Enter after creating new admin... "
                        ok "New admin created"
                    else
                        warn "Rescue CLI failed - try manual reset"
                        echo ""
                        echo " Manual reset command:"
                        echo " docker exec -it remnawave cli"
                        echo " Then choose: 'Reset superadmin'"
                        echo ""
                    fi
                else
                    info "Skipping admin reset"
                fi
                ;;
            3)
                info "Skipping admin creation"
                ;;
            *)
                warn "Invalid option, skipping"
                ;;
        esac
    elif [[ "$http_code" == "400" ]]; then
        warn "Validation error (400): $body"
        echo ""
        echo "=========================================="
        echo "  Password Validation Failed"
        echo "=========================================="
        echo ""
        echo " The password does not meet server requirements."
        echo " Try again with a stronger password."
        echo ""
        echo " Minimum requirements:"
        echo " - At least 24 characters (Remnawave requirement)"
        echo ""
        err "Admin creation failed"
    else
        warn "API registration failed ($http_code): $body"
        echo ""
        echo "=========================================="
        echo "  Create Admin User Manually"
        echo "=========================================="
        echo ""
        echo " 1. Open: https://$PANEL_DOMAIN"
        echo " 2. Create admin account (first user = superadmin)"
        echo " 3. Press Enter when done"
        echo ""
        read -r -p "Press Enter after creating admin... "
        ok "Admin created"
    fi
}

# ============================================================
# STEP 10: Logrotate for Node (per official docs)
# ============================================================
step_logrotate() {
    log "=== Logrotate for Node ==="
    dbg "Configuring logrotate for /var/log/remnanode/"

    if ! command -v logrotate &>/dev/null; then
        dbg "logrotate not found, installing..."
        run "apt-get install -y logrotate"
    fi

    cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    run "logrotate -vf /etc/logrotate.d/remnanode"
    ok "Logrotate configured"
}

# ============================================================
# Main
# ============================================================
main() {
    # Deployment lock — prevent concurrent runs
    LOCKFILE="/tmp/remnawave-deploy.lock"
    exec 200>"$LOCKFILE"
    flock -n 200 || err "Another instance is already running (lock: $LOCKFILE)"

    # Debug mode setup
    if $DEBUG; then
        warn "DEBUG MODE ENABLED"
        if [[ -n "$DEBUG_FILE" ]]; then
            {
                echo "=== Deploy Debug Log ==="
                echo "Started: $(date)"
                echo "Role: $ROLE"
                echo "PID: $$"
                echo ""
            } > "$DEBUG_FILE"
        fi
        set -x
    fi

    log "Deploy: $ROLE"
    $DRY_RUN && warn "DRY RUN"
    $STAGING && warn "STAGING MODE — using Let's Encrypt staging CA"

    debug_vars "Runtime" DRY_RUN FORCE STAGING DEBUG DEBUG_FILE ROLE NODE_PORT

    dbg "=== Step 0: Configuration ==="
    step_config
    dbg "=== Step -1: Check previous ==="
    step_check_previous
    dbg "=== Step 1: Prerequisites ==="
    step_prerequisites
    dbg "=== Step 1.5: UFW ==="
    step_ufw

    # SSL certificates
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        # Panel SSL (per docs: cert in /opt/remnawave/nginx)
        dbg "=== Step 2: SSL for Panel ($PANEL_DOMAIN) ==="
        step_ssl "$PANEL_DOMAIN" "/opt/remnawave/nginx"
    fi

    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        # Node SSL
        dbg "=== Step 2: SSL for Node ($NODE_DOMAIN) ==="
        step_ssl "$NODE_DOMAIN" "/opt/remnanode/ssl"
    fi

    # Separate subdomain SSL (when subscription domain differs from panel domain)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            dbg "=== Step 2: SSL for SUB ($SUB_DOMAIN) ==="
            step_ssl "$SUB_DOMAIN" "/opt/remnawave/nginx/sub"
        fi
    fi

    # Panel components (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        dbg "=== Step 3: Panel ==="
        step_panel
        dbg "=== Step 4: Panel Nginx ==="
        step_panel_nginx
    fi

    # Node components (node and panel+node roles)
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        dbg "=== Step 5: Node Nginx ==="
        step_node_nginx
        dbg "=== Step 6: Node ==="
        step_node
    fi

    # Start everything
    dbg "=== Step 7: Start ==="
    step_start
    dbg "=== Step 8: Verify ==="
    step_verify

    # Create admin for panel role
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        dbg "=== Step 9: Create Admin ==="
        step_create_admin
    fi

    # Logrotate for node
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        dbg "=== Step 10: Logrotate ==="
        step_logrotate
    fi

    echo ""
    log "=========================================="
    log "Deploy complete!"
    log "=========================================="

    # Role-specific output
    if [[ "$ROLE" == "panel" ]]; then
        log "Panel: https://$PANEL_DOMAIN"
        log "Sub:   $SUB_PUBLIC_DOMAIN"
    elif [[ "$ROLE" == "node" ]]; then
        log "Node: $NODE_DOMAIN"
    elif [[ "$ROLE" == "panel+node" ]]; then
        log "Node:  $NODE_DOMAIN"
        log "Panel: https://$PANEL_DOMAIN"
        log "Sub:   $SUB_PUBLIC_DOMAIN"
    fi

    echo ""
    log "Next steps:"
    if [[ "$ROLE" == "panel" ]]; then
        log "1. Panel: Create Config Profile (VLESS + XHTTP3)"
        log "2. Panel: Nodes → Management → + (Add Node)"
        log "3. Panel: Click 'Copy docker-compose.yml' → paste on Node server"
        log "4. Panel: Link Config Profile to Node → Enable Node"
    elif [[ "$ROLE" == "node" ]]; then
        log "1. Panel: Nodes → Management → + (Add Node)"
        log "2. Panel: Click 'Copy docker-compose.yml'"
        log "3. Paste content into /opt/remnanode/docker-compose.yml"
        log "4. Panel: Link Config Profile to Node → Enable Node"
        log "5. Run: cd /opt/remnanode && docker compose up -d"
    elif [[ "$ROLE" == "panel+node" ]]; then
        log "1. Panel: Create Config Profile (VLESS + XHTTP3)"
        log "2. Panel: Nodes → Management → + (Add Node)"
        log "     Address: $NODE_DOMAIN, Port: $NODE_PORT"
        log "3. Panel: Click 'Copy docker-compose.yml' → update /opt/remnanode/docker-compose.yml"
        log "4. Panel: Link Config Profile to Node → Enable Node"
        log "5. Restart Node: cd /opt/remnanode && docker compose up -d"
    fi
}

main
