#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE="${1:-odoo20-1}"
BASE="/opt/voltach-odoo/instances/${INSTANCE}"
PATCH_DIR="/opt/voltach-odoo/image-patches/odoo20-clipboard"
PATCHED_IMAGE="voltach/odoo:20-clipboard-fixed"

[[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo $0 [instance]"; exit 1; }
[[ -d "$BASE" ]] || { echo "Instance not found: $BASE"; exit 1; }

mkdir -p "$PATCH_DIR"

cat > "$PATCH_DIR/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE=odoo:20
FROM ${BASE_IMAGE}
USER root
RUN python3 - <<'PY'
from pathlib import Path

p = Path("/usr/lib/python3/dist-packages/odoo/addons/web_tour/static/src/tour_helpers/tour_helpers_clipboard.js")
if not p.exists():
    raise SystemExit(f"Missing expected file: {p}")

s = p.read_text()

s = s.replace(
    "const originalClipboardWriteText = window.navigator.clipboard.writeText;",
    "const originalClipboardWriteText = window.navigator.clipboard?.writeText?.bind(window.navigator.clipboard);"
)

s = s.replace(
    "        window.navigator.clipboard.writeText = () => Promise.resolve();",
    "        if (window.navigator.clipboard) {\n            window.navigator.clipboard.writeText = () => Promise.resolve();\n        }"
)

s = s.replace(
    "        window.navigator.clipboard.writeText = originalClipboardWriteText;",
    "        if (window.navigator.clipboard && originalClipboardWriteText) {\n            window.navigator.clipboard.writeText = originalClipboardWriteText;\n        }"
)

p.write_text(s)
print("Patched:", p)
PY
USER odoo
DOCKERFILE

docker pull odoo:20
docker build --build-arg BASE_IMAGE=odoo:20 -t "$PATCHED_IMAGE" "$PATCH_DIR"

cp "$BASE/.env" "$BASE/.env.bak.$(date +%Y%m%d_%H%M%S)"
if grep -q '^ODOO_IMAGE=' "$BASE/.env"; then
  sed -i -E 's#^ODOO_IMAGE=.*$#ODOO_IMAGE=voltach/odoo:20-clipboard-fixed#' "$BASE/.env"
else
  printf '\nODOO_IMAGE=voltach/odoo:20-clipboard-fixed\n' >> "$BASE/.env"
fi

DB_NAME="$(grep -E '^INITIAL_DB_NAME=' "$BASE/.env" 2>/dev/null | cut -d= -f2- || true)"
if [[ -z "$DB_NAME" ]]; then
  DB_NAME="$(docker exec "voltach-db-${INSTANCE}" psql -U odoo -Atc "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname LIMIT 1;" postgres)"
fi

cd "$BASE"

echo "Resolved web image before recreation:"
ODOO_IMAGE="$PATCHED_IMAGE" docker compose config | awk '
  /^  web:$/ {in_web=1; next}
  in_web && /^    image:/ {print; exit}
'

RESOLVED_IMAGE="$(ODOO_IMAGE="$PATCHED_IMAGE" docker compose config | awk '
  /^  web:$/ {in_web=1; next}
  in_web && /^    image:/ {sub(/^    image:[[:space:]]*/, ""); print; exit}
')"

if [[ "$RESOLVED_IMAGE" != "$PATCHED_IMAGE" ]]; then
  echo "ERROR: docker compose resolves web image as: $RESOLVED_IMAGE" >&2
  echo "Expected: $PATCHED_IMAGE" >&2
  exit 1
fi

ODOO_IMAGE="$PATCHED_IMAGE" docker compose up -d --force-recreate web

ACTIVE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "voltach-odoo-${INSTANCE}")"
if [[ "$ACTIVE_IMAGE" != "$PATCHED_IMAGE" ]]; then
  echo "ERROR: Odoo container is still using: $ACTIVE_IMAGE" >&2
  echo "Expected: $PATCHED_IMAGE" >&2
  exit 1
fi

echo "Confirmed active image: $ACTIVE_IMAGE"

docker exec "voltach-odoo-${INSTANCE}" sh -lc \
  "grep -n 'originalClipboardWriteText' /usr/lib/python3/dist-packages/odoo/addons/web_tour/static/src/tour_helpers/tour_helpers_clipboard.js | head"

if [[ -n "$DB_NAME" ]]; then
  docker exec -i "voltach-odoo-${INSTANCE}" odoo shell -d "$DB_NAME" --no-http <<'PY'
if 'web_tour.tour' in env.registry.models:
    env['web_tour.tour'].search([]).write({'active': False})
users = env['res.users'].search([])
if 'tour_enabled' in users._fields:
    users.write({'tour_enabled': False})
env['ir.attachment'].search([('url', 'like', '/web/assets/%')]).unlink()
env.cr.commit()
PY
fi

docker restart "voltach-odoo-${INSTANCE}" >/dev/null

echo
echo "Repair complete."
echo "Instance: $INSTANCE"
echo "Image:    $PATCHED_IMAGE"
echo "Database: ${DB_NAME:-unknown}"
echo
echo "Now clear these browser localStorage keys once:"
echo "current_tour"
echo "current_tour.config"
echo "current_tour.index"
echo "current_tour.on_error"
