#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Cleanup on exit
CLEANUP_FILES=()
cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "Script exited with code $rc"
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
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${B}[deploy]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N} $*"; exit 1; }

# Defaults
DRY_RUN=false; FORCE=false; STAGING=false
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
EOF
    exit 1
}

# Parse args
ROLE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        panel|node|panel+node) [[ -z "$ROLE" ]] && ROLE="$1" || err "dup role"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --staging) STAGING=true; shift ;;
        --*) err "Unknown: $1" ;;
        *) err "Unexpected: $1" ;;
    esac
done
[[ -z "$ROLE" ]] && usage

run() {
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
    echo ""
    confirm "Apply this configuration?"
}

# ============================================================
# STEP -1: Full cleanup of all Remnawave remnants
# ============================================================
step_check_previous() {
    log "=== Full cleanup ==="

    local found=false
    local panel_dir="/opt/remnawave"
    local node_dir="/opt/remnanode"

    # Check directories
    if [[ -d "$panel_dir" ]]; then warn "Found $panel_dir"; found=true; fi
    if [[ -d "$node_dir" ]]; then warn "Found $node_dir"; found=true; fi

    # Check ALL containers (running + stopped)
    local containers
    containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "remnawave|remnanode|panel-nginx" || true)
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

    echo ""
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
    run "docker system prune -f"

    ok "Full cleanup complete"
}

# ============================================================
# STEP 1: Prerequisites
# ============================================================
step_prerequisites() {
    log "=== Prerequisites ==="

    if ! command -v docker &>/dev/null; then
        run "curl -fsSL https://get.docker.com | sh"
        ok "Docker installed"
    else
        ok "Docker already installed"
    fi

    # Verify Docker daemon is actually running
    docker info &>/dev/null || err "Docker daemon is not running or not accessible"

    docker compose version &>/dev/null || err "Docker Compose not found"

    for cmd in curl openssl; do
        command -v "$cmd" &>/dev/null || DEBIAN_FRONTEND=noninteractive run "apt-get update -qq && apt-get install -y -qq $cmd"
    done

    # Install acme.sh per official docs
    if ! command -v acme.sh &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive run "apt-get install -y -qq cron socat"
        run "curl https://get.acme.sh | sh -s email=$EMAIL"
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
    run "acme.sh --issue --standalone -d '$domain' \
        --key-file '$key' --fullchain-file '$pem' \
        --alpn --tlsport 8443 --force \
        --server '$acme_server'"

    # Determine correct nginx container for reload
    # Panel nginx is 'remnawave-panel-nginx', Node nginx is 'remnawave-node-nginx'
    local nginx_container
    if [[ "$domain" == "${NODE_DOMAIN:-}" ]]; then
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
    if ! $DRY_RUN; then
        sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" "$pd/.env"
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
        sed -i '/^  remnawave:/,/^[^ ]/{/volumes:/a\      - /opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl:ro
}' "$pd/docker-compose.yml"
    fi

    ok "Panel configured in $pd (per official docs)"
    log "  FRONT_END_DOMAIN:  $PANEL_DOMAIN"
    log "  SUB_PUBLIC_DOMAIN: $SUB_PUBLIC_DOMAIN"
}

# ============================================================
# STEP 4: Panel Nginx (official docs template)
# ============================================================
step_panel_nginx() {
    local pd="/opt/remnawave/nginx"
    log "=== Panel Nginx (official template) ==="

    run "mkdir -p $pd"

    # Determine port binding based on role
    # panel+node: panel nginx binds 127.0.0.1 (node nginx takes 0.0.0.0)
    # panel only: bind 0.0.0.0 (official default)
    local nginx_bind="0.0.0.0"
    if [[ "$ROLE" == "panel+node" ]]; then
        nginx_bind="127.0.0.1"
    fi

    # nginx.conf - EXACT template from official docs + enhancements
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
}

# ============================================================
# STEP 5: Node Nginx (VLESS + XHTTP3 reverse proxy)
# ============================================================
step_node_nginx() {
    local nginx_dir="/opt/remnanode/nginx"
    log "=== Node Nginx (VLESS + XHTTP3) ==="

    run "mkdir -p $nginx_dir"

    # Generate QUIC host key
    if [[ ! -f "/opt/remnanode/ssl/quic_host.key" ]]; then
        run "mkdir -p /opt/remnanode/ssl && openssl rand -out /opt/remnanode/ssl/quic_host.key 32"
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

    # docker-compose.yml for Node nginx
    # panel+node role: use bridge mode on port 4433 to avoid conflict with panel nginx
    # node only role: use host mode (direct port 443)
    if [[ "$ROLE" == "panel+node" ]]; then
        cat > "$nginx_dir/docker-compose.yml" <<EOF
services:
  remnawave-node-nginx:
      image: macbre/nginx-http3:latest
      container_name: remnawave-node-nginx
      volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./stub.html:/var/www/html/index.html:ro
      - /opt/remnanode/ssl:/etc/nginx/ssl:ro
      - ./dhparam.pem:/etc/nginx/ssl/dhparam.pem:ro
      - /dev/shm:/dev/shm:ro
    ports:
      - "4433:443/tcp"
      - "4433:443/udp"
    restart: always
EOF
        warn "Node Nginx binds to port 4433 (panel+node mode)"
        warn "Configure firewall: redirect external 443 -> 4433, or use SNAT"
    else
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
      - ./dhparam.pem:/etc/nginx/ssl/dhparam.pem:ro
      - /dev/shm:/dev/shm:ro
    restart: always
EOF
    fi

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

    # For panel+node role, we need to guide the user to copy docker-compose from Panel
    if [[ "$ROLE" == "panel+node" ]]; then
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

    # Create Docker network (needed by official docker-compose)
    if ! docker network inspect remnawave-network &>/dev/null; then
        run "docker network create remnawave-network"
        ok "Created remnawave-network"
    else
        ok "remnawave-network already exists"
    fi

    # Panel (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnawave/docker-compose.yml" ]]; then
            if docker ps --format "{{.Names}}" | grep -q remnawave; then
                warn "Panel already running, skipping"
            else
                run "cd /opt/remnawave && docker compose up -d"
                ok "Panel started"
            fi
        fi
    fi

    # Panel nginx (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnawave/nginx/docker-compose.yml" ]]; then
            if docker ps --format "{{.Names}}" | grep -q remnawave-panel-nginx; then
                warn "remnawave-panel-nginx already running, skipping"
            else
                run "cd /opt/remnawave/nginx && docker compose up -d"
                ok "Panel Nginx started"
            fi
        fi
    fi

    # Node nginx (node and panel+node roles)
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnanode/nginx/docker-compose.yml" ]]; then
            if docker ps --format "{{.Names}}" | grep -q remnawave-node-nginx; then
                warn "remnawave-node-nginx already running, skipping"
            else
                run "cd /opt/remnanode/nginx && docker compose up -d"
                ok "Node Nginx started"
            fi
        fi
    fi

    # Node (node and panel+node roles)
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if [[ -f "/opt/remnanode/docker-compose.yml" ]]; then
            if docker ps --format "{{.Names}}" | grep -q remnanode; then
                warn "remnanode already running, skipping"
            else
                run "cd /opt/remnanode && docker compose up -d"
                ok "Node started"
            fi
        fi
    fi
}

# ============================================================
# STEP 8: Verify
# ============================================================
step_verify() {
    log "=== Verification ==="
    docker ps --format "table {{.Names}}\t{{.Status}}"

    # Check Panel nginx
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnawave-panel-nginx; then
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" "https://$PANEL_DOMAIN" --resolve "$PANEL_DOMAIN:443:127.0.0.1" --insecure 2>/dev/null || echo "000")
            [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]] && ok "Panel Nginx OK ($code)" || warn "Panel Nginx ($code)"
        fi
    fi

    # Check Panel
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnawave; then
            ok "Panel running"
        else
            warn "Panel not running - check: docker logs remnawave"
        fi
    fi

    # Check Node nginx
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnawave-node-nginx; then
            local code
            if [[ "$ROLE" == "panel+node" ]]; then
                code=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN" --resolve "$NODE_DOMAIN:4433:127.0.0.1" --insecure 2>/dev/null || echo "000")
            else
                code=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN" --insecure 2>/dev/null || echo "000")
            fi
            [[ "$code" == "200" || "$code" == "301" ]] && ok "Node Nginx OK ($code)" || warn "Node Nginx ($code)"
        fi
    fi

    # Check Node
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        if docker ps --format "{{.Names}}" | grep -q remnanode; then
            ok "Node running"
            docker logs remnanode 2>&1 | tail -5
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

    # Wait for Panel to be ready
    local retries=12
    local delay=5
    local ready=false

    for i in $(seq 1 $retries); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "https://$PANEL_DOMAIN" --resolve "$PANEL_DOMAIN:443:127.0.0.1" --insecure 2>/dev/null || echo "000")
        if [[ "$code" != "000" ]]; then
            ready=true
            break
        fi
        warn "Waiting for Panel... ($i/$retries)"
        sleep $delay
    done

    if ! $ready; then
        err "Panel did not start in time. Check: docker logs remnawave"
    fi

    echo ""
    ok "Panel is ready!"
    echo ""
    echo "=========================================="
    echo "  Create Admin User"
    echo "=========================================="
    echo ""
    echo " 1. Open: https://$PANEL_DOMAIN"
    echo " 2. Create admin account (first user = superadmin)"
    echo " 3. Press Enter when done"
    echo ""
    read -r -p "Press Enter after creating admin... "
    ok "Admin created"
}

# ============================================================
# STEP 10: Logrotate for Node (per official docs)
# ============================================================
step_logrotate() {
    log "=== Logrotate for Node ==="

    if ! command -v logrotate &>/dev/null; then
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

    log "Deploy: $ROLE"
    $DRY_RUN && warn "DRY RUN"
    $STAGING && warn "STAGING MODE — using Let's Encrypt staging CA"

    step_config
    step_check_previous
    step_prerequisites

    # SSL certificates
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        # Panel SSL (per docs: cert in /opt/remnawave/nginx)
        step_ssl "$PANEL_DOMAIN" "/opt/remnawave/nginx"
    fi

    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        # Node SSL
        step_ssl "$NODE_DOMAIN" "/opt/remnanode/ssl"
    fi

    # Separate subdomain SSL (when subscription domain differs from panel domain)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        if [[ "${SUB_DOMAIN:-}" != "$PANEL_DOMAIN" ]]; then
            step_ssl "$SUB_DOMAIN" "/opt/remnawave/nginx/sub"
        fi
    fi

    # Panel components (panel and panel+node roles)
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        step_panel
        step_panel_nginx
    fi

    # Node components (node and panel+node roles)
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
        step_node_nginx
        step_node
    fi

    # Start everything
    step_start
    step_verify

    # Create admin for panel role
    if [[ "$ROLE" == "panel" || "$ROLE" == "panel+node" ]]; then
        step_create_admin
    fi

    # Logrotate for node
    if [[ "$ROLE" == "node" || "$ROLE" == "panel+node" ]]; then
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
        log ""
        log "IMPORTANT: Node Nginx is on port 4433 (panel+node mode)"
        log "Configure firewall to route external 443 traffic to Node:"
        log "  iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 4433"
        log "  iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port 4433"
    fi
}

main
