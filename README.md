# Remnawave Deploy

Universal deployment script for Remnawave Panel and Node based on official documentation.

## Usage

```bash
./deploy.sh <ROLE> [OPTIONS]
```

### Roles

- `panel` - Panel + Nginx reverse proxy only
- `node` - Node + Nginx reverse proxy only
- `panel+node` - Panel + Node + both Nginx

### Options

- `--dry-run` - Show commands only
- `--force` - Skip confirmation
- `--staging` - Use Let's Encrypt staging CA
- `--debug` - Enable debug mode (verbose output, set -x)
- `--debug-file FILE` - Write debug log to FILE (implies --debug)

## Requirements

- Debian/Ubuntu
- Docker + Docker Compose
- Root or sudo access

## Architecture

- Panel: `remnawave/panel` on port 3000 (behind Nginx)
- Node: `remnawave/node` on port 2222 (default)
- SSL: acme.sh with Let's Encrypt
- Firewall: UFW only

## Official Docs

https://docs.rw/docs/install/
