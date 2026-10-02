# Voltach Odoo Unified Installer

Unified Linux server bootstrap and multi-instance Odoo installer for Ubuntu/Debian.

## Included

- Docker Engine + Docker Compose v2
- Webmin
- Nginx Proxy Manager
- Portainer CE
- Odoo 16, 17, 18, 19 and 20, plus custom images
- Multiple independent Odoo instances on one server
- PostgreSQL 17 with pgvector
- Separate custom-addons directory per instance
- Automatic port selection
- Private database network
- Odoo connection to the shared `voltach_proxy` network
- Local-only PostgreSQL host publishing (`127.0.0.1`)
- RAM-aware Odoo worker and PostgreSQL tuning
- Hashed Odoo master password in `odoo.conf`
- Root-only recovery secrets
- `voltach-odoo` management CLI for list/logs/restart/backup and related operations

## Quick install

```bash
git clone https://github.com/waelhym/voltach-odoo-unified-installer.git
cd voltach-odoo-unified-installer
chmod +x install.sh
sudo ./install.sh
```

## Security

The installer is designed to avoid exposing PostgreSQL publicly. Review firewall, DNS, TLS, reverse-proxy and backup settings before production use.

## License

MIT. See `LICENSE`.
