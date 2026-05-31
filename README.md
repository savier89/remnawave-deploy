# Remnawave Deploy

Universal deployment script for Remnawave Panel and Node based on [official documentation](https://docs.rw/docs/install/).

## Quick Start

```bash
./deploy.sh <ROLE> [OPTIONS]
```

### Roles

| Role | Description |
|---|---|
| `panel` | Panel + Nginx reverse proxy only |
| `node` | Node + Nginx reverse proxy only |
| `panel+node` | Panel + Node + both Nginx containers |

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
│  Panel Domain ──→ 443/tcp ──→ remnawave-panel-nginx │
│  Node Domain  ──→ 443/tcp ──→ remnawave-node-nginx  │
│                        (port 4433 in panel+node)     │
└─────────────────────────────────────────────────────┘

Panel+Node mode:
  Panel nginx: 127.0.0.1:443 (internal only)
  Node nginx:  0.0.0.0:4433 (external traffic)
```

### Container Naming

| Container | Official Name | Our Name | Reason |
|---|---|---|---|
| Panel Nginx | `remnawave-nginx` | `remnawave-panel-nginx` | Avoid conflict in `panel+node` mode |
| Node Nginx | — | `remnawave-node-nginx` | Separate container for Node QUIC proxy |

**Why different names?** The official docs assume a single-role deployment (panel OR node). Our script supports `panel+node` mode where both nginx containers run on the same host, requiring unique names to avoid Docker conflicts.

### Nginx Image Choice

| Image | Features | Used For |
|---|---|---|
| `nginx:1.28` (official) | HTTP/2 only | Panel reverse proxy |
| `macbre/nginx-http3:latest` (ours) | HTTP/2 + HTTP/3 (QUIC) | Node reverse proxy |

**Why `macbre/nginx-http3`?** The Node component uses VLESS + XHTTP3 protocol which requires QUIC/HTTP3 support. The official `nginx:1.28` image does not include QUIC modules. The `macbre/nginx-http3` image is built with `ngx_http_quic_module` enabled, providing native HTTP/3 support required for optimal Node performance.

### Ports

| Service | Port | Protocol | Mode |
|---|---|---|---|
| Panel Nginx | 443 | TCP/UDP | `127.0.0.1` in panel+node, `0.0.0.0` otherwise |
| Node Nginx | 443 | TCP/UDP | `host` mode (node-only) or `4433` (panel+node) |
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

### Node Nginx port conflict (panel+node mode)

In `panel+node` mode, Node Nginx binds to port **4433** to avoid conflict with Panel Nginx on port 443. Configure firewall to route external traffic:

```bash
# Edit /etc/ufw/before.rules
# Add to *nat section, before COMMIT:
-A prerouting_rule -p tcp --dport 443 -j REDIRECT --to-port 4433
-A prerouting_rule -p udp --dport 443 -j REDIRECT --to-port 4433

# Reload UFW
ufw reload
```

### Debug mode

```bash
# Enable verbose output
./deploy.sh panel+node --debug

# Save debug log to file
./deploy.sh panel+node --debug-file /home/user/deploy-debug.log
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
