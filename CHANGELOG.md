# Changelog

## 1.1.0 - 2026-10-02

- Prevent stale Odoo onboarding tours from causing `TourInteractive` JavaScript errors.
- Install a small `voltach_bootstrap_fix` addon that clears stale tour state from browser localStorage.
- Disable database tours and user tour mode during first-database initialization.
- Remove generated `/web/assets/%` attachments before first production start so assets rebuild cleanly.
- Keep automatic Odoo data/session permission repair.

## 1.0.0 - 2026-10-02

- Merged the multi-instance Odoo installer and Voltach server installer.
- Added Odoo 16-20 and custom image support.
- Added PostgreSQL 17 + pgvector.
- Added optional Webmin, Nginx Proxy Manager and Portainer provisioning.
- Added isolated database networking and local-only PostgreSQL publishing.
- Added generated management CLI and backup workflow.
