# Changelog

## 1.1.3 - 2026-10-03

- Added browser-side protection against accidental `debug=tests` and `debug=assets,tests` sessions.
- Preserve normal Developer Mode while automatically removing only the `tests` debug token.
- Continue clearing stale `web_tour` localStorage state on backend load.
- Document safe Odoo URLs and test-mode URLs to avoid in production.

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
