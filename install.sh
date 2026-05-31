#!/bin/bash
# Remnawave Deploy - Installation Script
# Usage: bash <(curl -Ls https://raw.githubusercontent.com/savier89/remnawave-deploy/refs/heads/main/install.sh)

set -euo pipefail

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${B}[install]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N} $*"; exit 1; }

# Configuration
REPO="savier89/remnawave-deploy"
BRANCH="main"
INSTALL_DIR="/opt/remnawave-deploy"
BINARY_PATH="/usr/local/bin/remnawave_manager"

log "Installing Remnawave Deploy..."
warn "This script is NOT production-ready! Use at your own risk."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
fi

# Check if already installed
if [[ -f "$BINARY_PATH" ]]; then
    warn "remnawave_manager is already installed at $BINARY_PATH"
    echo -en "${Y}Overwrite? [y/N]${N} "
    read -r a
    [[ "$a" =~ ^[Yy]$ ]] || err "Aborted"
fi

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Download deploy.sh
log "Downloading deploy.sh..."
curl -fsSL "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/deploy.sh" \
    -o "$INSTALL_DIR/deploy.sh" || err "Failed to download deploy.sh"

chmod +x "$INSTALL_DIR/deploy.sh"

# Create remnawave_manager binary
log "Creating remnawave_manager..."
cat > "$BINARY_PATH" <<'MANAGER_EOF'
#!/bin/bash
# Remnawave Manager
# Usage: remnawave_manager <command> [options]

set -euo pipefail

INSTALL_DIR="/opt/remnawave-deploy"
DEPLOY_SCRIPT="$INSTALL_DIR/deploy.sh"
REPO="savier89/remnawave-deploy"
BRANCH="main"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${B}[manager]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR]${N} $*"; exit 1; }

usage() {
    cat <<EOF
Remnawave Deploy Manager

Usage: $0 <command> [options]

Commands:
  install <ROLE> [OPTIONS]  Install Remnawave (panel|node|panel+node)
  update                    Update to the latest version
  uninstall                 Completely remove Remnawave installation
  status                    Show installation status

Roles:
  panel       Panel + Nginx reverse proxy only
  node        Node + Nginx reverse proxy only
  panel+node  Panel + Node + unified Nginx

Options:
  --dry-run           Show commands only
  --force             Skip confirmation
  --staging           Use Let's Encrypt staging CA
  --debug             Enable debug mode
  --debug-file FILE   Write debug log to FILE

Examples:
  $0 install panel
  $0 install node --dry-run
  $0 install panel+node --debug
  $0 update
  $0 uninstall
  $0 status
EOF
    exit ${1:-0}
}

# Check if deploy.sh exists
check_deploy() {
    if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
        err "deploy.sh not found at $DEPLOY_SCRIPT. Run install first."
    fi
}

case "${1:-}" in
    install)
        shift
        check_deploy
        exec bash "$DEPLOY_SCRIPT" "$@"
        ;;
    update)
        log "Updating Remnawave Deploy..."
        if [[ ! -d "$INSTALL_DIR" ]]; then
            mkdir -p "$INSTALL_DIR"
        fi
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/deploy.sh" \
            -o "$INSTALL_DIR/deploy.sh.new" || err "Failed to download deploy.sh"
        mv "$INSTALL_DIR/deploy.sh.new" "$INSTALL_DIR/deploy.sh"
        chmod +x "$INSTALL_DIR/deploy.sh"
        ok "Updated successfully"
        ;;
    uninstall)
        log "Uninstalling Remnawave..."
        warn "This will remove ALL Remnawave data!"
        echo -en "${Y}Proceed? [y/N]${N} "
        read -r a
        [[ "$a" =~ ^[Yy]$ ]] || err "Aborted"
        
        # Stop and remove containers
        log "Stopping and removing containers..."
        docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "remnawave|remnanode|unified-nginx" | while read -r container; do
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        done
        
        # Remove volumes
        log "Removing volumes..."
        docker volume ls --format "{{.Name}}" 2>/dev/null | grep -E "remnawave|remnanode" | while read -r volume; do
            docker volume rm "$volume" 2>/dev/null || true
        done
        
        # Remove networks
        log "Removing networks..."
        docker network ls --format "{{.Name}}" 2>/dev/null | grep -E "remnawave" | while read -r network; do
            docker network rm "$network" 2>/dev/null || true
        done
        
        # Remove directories
        log "Removing directories..."
        rm -rf /opt/remnawave
        rm -rf /opt/remnanode
        
        # Remove nginx configs
        log "Removing nginx configs..."
        rm -f /etc/nginx/conf.d/*remnawave*
        rm -f /etc/nginx/conf.d/*remnanode*
        
        # Remove logrotate config
        rm -f /etc/logrotate.d/remnanode
        
        # Remove this script
        rm -f "$BINARY_PATH"
        
        ok "Uninstallation complete"
        ;;
    status)
        log "Remnawave Status:"
        echo ""
        
        # Check containers
        echo "Containers:"
        docker ps -a --format "  {{.Names}}: {{.Status}} ({{.Image}})" 2>/dev/null | grep -E "remnawave|remnanode|unified-nginx" || echo "  None found"
        echo ""
        
        # Check directories
        echo "Directories:"
        [[ -d "/opt/remnawave" ]] && echo "  /opt/remnawave: EXISTS" || echo "  /opt/remnawave: NOT FOUND"
        [[ -d "/opt/remnanode" ]] && echo "  /opt/remnanode: EXISTS" || echo "  /opt/remnanode: NOT FOUND"
        echo ""
        
        # Check SSL certificates
        echo "SSL Certificates:"
        if [[ -d "/opt/remnawave/nginx" ]]; then
            ls -la /opt/remnawave/nginx/*.pem 2>/dev/null | while read -r line; do
                echo "  $line"
            done || echo "  None found"
        else
            echo "  /opt/remnawave/nginx not found"
        fi
        echo ""
        
        # Check firewall rules
        echo "Firewall Rules:"
        ufw status verbose 2>/dev/null | grep -E "22|80|443|2222" || echo "  No rules found"
        echo ""
        
        # Check deployment script version
        echo "Deployment Script:"
        if [[ -f "$DEPLOY_SCRIPT" ]]; then
            echo "  Location: $DEPLOY_SCRIPT"
            echo "  Size: $(wc -c < "$DEPLOY_SCRIPT") bytes"
            echo "  Last modified: $(stat -c %y "$DEPLOY_SCRIPT" 2>/dev/null || stat -f %Sm "$DEPLOY_SCRIPT" 2>/dev/null)"
        else
            echo "  Not installed"
        fi
        ;;
    --help|-h)
        usage 0
        ;;
    "")
        usage 1
        ;;
    *)
        err "Unknown command: $1. Use '$0 --help' for usage."
        ;;
esac
MANAGER_EOF

chmod +x "$BINARY_PATH"

ok "Installation complete!"
echo ""
log "Usage:"
echo "  remnawave_manager install <ROLE> [OPTIONS]"
echo "  remnawave_manager update"
echo "  remnawave_manager uninstall"
echo "  remnawave_manager status"
echo ""
log "Examples:"
echo "  remnawave_manager install panel"
echo "  remnawave_manager install node"
echo "  remnawave_manager install panel+node"
