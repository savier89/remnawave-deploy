# Remnawave Deploy

> **⚠️ WARNING: This script is NOT production-ready!**  
> This is an early development version. Use at your own risk.  
> Features may change, bugs may exist, and data loss is possible.

Universal deployment script for Remnawave Panel and Node based on [official documentation](https://docs.rw/docs/install/).

## Quick Start

```bash
# Install remnawave_manager
bash <(curl -Ls https://raw.githubusercontent.com/savier89/remnawave-deploy/refs/heads/main/install.sh)

# Deploy
remnawave_manager install <ROLE> [OPTIONS]
```

### Roles

| Role | Description |
|---|---|
| `panel` | Panel + Nginx reverse proxy only |
| `node` | Node + Nginx reverse proxy only |
| `panel+node` | Panel + Node + unified Nginx |

### Options

| Option | Description |
|---|---|
| `--dry-run` | Show commands only |
| `--force` | Skip confirmation prompts |
| `--staging` | Use Let's Encrypt staging CA (higher rate limits) |
| `--debug` | Enable debug mode (verbose output, `set -x`) |
| `--debug-file FILE` | Write debug log to FILE (implies `--debug`) |

## Architecture

### Network Model

```
┌─────────────────────────────────────────────────────┐
│                    External                          │
│                                                      │
│  Panel Domain ──→ 443/tcp ──→ remnawave-unified-nginx │
│  Node Domain  ──→ 443/tcp ──→ remnawave-unified-nginx │
│  Sub Domain   ──→ 443/tcp ──→ remnawave-unified-nginx │
└─────────────────────────────────────────────────────┘

Panel+Node mode:
  Unified nginx: 0.0.0.0:443 (single container, multiple server blocks)
  - Panel domain → port 3000 (web interface)
  - Node domain → /dev/shm/xrxh.socket (Xray for user traffic)
  - Sub domain → port 3000 (if different from Panel domain)
```

### Container Naming

| Container | Official Name | Our Name | Reason |
|---|---|---|---|
| Unified Nginx | — | `remnawave-unified-nginx` | Single container with multiple server blocks |

**Why unified nginx?** In `panel+node` mode, both Panel and Node need port 443. Instead of using port 4433, we use a single nginx container with multiple server blocks that dynamically route traffic based on the domain.

### Nginx Image Choice

| Image | Features | Used For |
|---|---|---|
| `macbre/nginx-http3:latest` | HTTP/2 + HTTP/3 (QUIC) | Unified reverse proxy |

**Why `macbre/nginx-http3`?** The Node component uses VLESS + XHTTP3 protocol which requires QUIC/HTTP3 support. The official `nginx:1.28` image does not include QUIC modules. The `macbre/nginx-http3` image is built with `ngx_http_quic_module` enabled, providing native HTTP/3 support required for optimal Node performance.

### Ports

| Service | Port | Protocol | Mode |
|---|---|---|---|
| Unified Nginx | 443 | TCP/UDP | `host` mode |
| Panel API | 3000 | TCP | Internal (behind nginx) |
| Node API | 2222 | TCP | Panel → Node communication |

## Deployment Flow

1. **Configuration** — Interactive prompts for domains, ports, email
2. **Cleanup** — Remove previous Remnawave installation (if exists)
3. **Prerequisites** — Docker, acme.sh, UFW, DH parameters
4. **Firewall** — UFW rules (SSH, HTTP, HTTPS, Node ports)
5. **SSL** — acme.sh certificates via Let's Encrypt
6. **Panel** — Download docker-compose + .env from official repo
7. **Panel Nginx** — Generate config with SSL + gzip
8. **Node Nginx** — QUIC/XHTTP3 reverse proxy config
9. **Node** — docker-compose (paste from Panel UI or use default)
10. **Start** — Docker compose up for all services
11. **Verify** — Health checks via curl
12. **Admin** — Create admin user via API (POST /api/auth/register)
13. **Logrotate** — Configure log rotation for Node

## Incremental Installation

You can install Panel and Node separately on the same server:

```bash
# First: Install Panel only
remnawave_manager install panel

# Later: Install Node on the same server
remnawave_manager install node
# Script will detect Panel nginx and offer to upgrade to unified nginx
```

The script automatically detects existing components and offers to merge them into a unified nginx container.

## Troubleshooting

### Panel does not start

```bash
# Check container status
docker ps -a --filter "name=remnawave"

# View logs
docker logs remnawave

# Common causes:
# - Database migration failed
# - JWT secrets not generated
# - Port 3000 already in use
```

### SSL certificate issues

```bash
# Check acme.sh installation
~/.acme.sh/acme.sh --list

# Manual renewal
~/.acme.sh/acme.sh --renew -d 'your-domain.com' --force

# Check certificate files
ls -la /opt/remnawave/nginx/fullchain.pem
ls -la /opt/remnawave/nginx/privkey.key
```

### Debug mode

```bash
# Enable verbose output
remnawave_manager install panel+node --debug

# Save debug log to file
remnawave_manager install panel+node --debug-file /home/user/deploy-debug.log
```

## Requirements

- Debian/Ubuntu
- Docker + Docker Compose
- Root or sudo access
- Open ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)

## Official Documentation

- [Installation Guide](https://docs.rw/docs/install/)
- [OpenAPI Specification](https://cdn.docs.rw/docs/openapi.json)
- [GitHub Repository](https://github.com/remnawave/backend)
