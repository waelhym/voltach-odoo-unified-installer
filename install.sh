#!/usr/bin/env bash
# ==============================================================================
# Voltach Unified Server + Multi-Instance Odoo Installer
# Merged design based on:
#   - last-odoo (multi-instance Odoo + PostgreSQL 17/pgvector)
#   - voltach-server-installer (Docker/Webmin/NPM/Portainer/bootstrap/safety)
#
# Supports: Ubuntu/Debian, Odoo 16/17/18/19/20 (or custom image)
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
LOG_FILE="/var/log/voltach-unified-installer.log"
BASE_DIR="/opt/voltach-odoo"
INSTANCES_DIR="${BASE_DIR}/instances"
GLOBAL_BIN="/usr/local/bin"
CLI_NAME="voltach-odoo"
PG_IMAGE="pgvector/pgvector:pg17"
PROXY_NETWORK="voltach_proxy"

INSTALL_WEBMIN=1
INSTALL_NPM=1
INSTALL_PORTAINER=1
INSTALL_ODOO=1
UPGRADE_SYSTEM=0

# Runtime instance values
INSTANCE_NAME=""
TARGET_DIR=""
ODOO_VERSION="18"
ODOO_VER_DOT="18.0"
ODOO_IMAGE="odoo:18"
HTTP_PORT=""
CHAT_PORT=""
DB_PORT=""
POSTGRES_USER="odoo"
POSTGRES_PASSWORD=""
POSTGRES_DB="postgres"
ODOO_MASTER_PASSWORD=""
ODOO_MASTER_HASH=""
WORKERS_COUNT=2
SHARED_BUFFERS="256MB"
EFFECTIVE_CACHE_SIZE="768MB"
WORK_MEM="32MB"
MAINTENANCE_WORK_MEM="128MB"

# ---------- UI ----------
if [[ -t 1 ]]; then
  NC='\033[0m'; BOLD='\033[1m'; RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; BLUE='\033[34m'
else
  NC=''; BOLD=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''
fi

log()     { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
die()     { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

on_error() {
  local code=$?
  warn "Installation stopped on line ${BASH_LINENO[0]} (exit ${code})."
  warn "Review ${LOG_FILE}."
  exit "$code"
}
trap on_error ERR

banner() {
  echo
  echo -e "${CYAN}${BOLD}==============================================================${NC}"
  echo -e "${CYAN}${BOLD} Voltach Unified Server + Odoo Installer v${VERSION}${NC}"
  echo -e " Docker | Webmin | NPM | Portainer | Odoo 16-20 | PG17 Vector"
  echo -e "${CYAN}${BOLD}==============================================================${NC}"
  echo
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash voltach-odoo-unified-installer.sh [options]

Options:
  --no-webmin       Skip Webmin
  --no-npm          Skip NGINX Proxy Manager
  --no-portainer    Skip Portainer CE
  --no-odoo         Skip Odoo instance creation
  --upgrade-system  Run apt-get upgrade before installation
  -h, --help        Show help

The script can be run again to add another isolated Odoo instance.
USAGE
}

while (($#)); do
  case "$1" in
    --no-webmin) INSTALL_WEBMIN=0 ;;
    --no-npm) INSTALL_NPM=0 ;;
    --no-portainer) INSTALL_PORTAINER=0 ;;
    --no-odoo) INSTALL_ODOO=0 ;;
    --upgrade-system) UPGRADE_SYSTEM=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

read_tty() {
  local prompt="$1" varname="$2" default="${3:-}" val=""
  if [[ -t 0 ]]; then
    read -rp "$prompt" val || val=""
  elif [[ -e /dev/tty ]]; then
    read -rp "$prompt" val </dev/tty || val=""
  fi
  printf -v "$varname" '%s' "${val:-$default}"
}

prompt_password() {
  local label="$1" min_length="$2" output_var="$3" first="" second=""
  [[ -t 0 || -e /dev/tty ]] || die "${label} requires an interactive terminal."
  while true; do
    if [[ -t 0 ]]; then read -rsp "${label} (minimum ${min_length} characters): " first; else read -rsp "${label} (minimum ${min_length} characters): " first </dev/tty; fi
    printf '\n'
    (( ${#first} >= min_length )) || { warn "Password must be at least ${min_length} characters."; continue; }
    if [[ -t 0 ]]; then read -rsp "Confirm ${label}: " second; else read -rsp "Confirm ${label}: " second </dev/tty; fi
    printf '\n'
    [[ "$first" == "$second" ]] || { warn "Passwords do not match."; continue; }
    printf -v "$output_var" '%s' "$first"
    unset first second
    return 0
  done
}

new_secret() { openssl rand -hex 24; }

# ---------- Preflight ----------
preflight() {
  [[ ${EUID} -eq 0 ]] || die "Run as root: sudo bash $0"
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  source /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "Supported OS: Ubuntu or Debian. Detected: ${PRETTY_NAME:-unknown}" ;; esac
  mkdir -p "$(dirname "$LOG_FILE")" "$INSTANCES_DIR"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  export DEBIAN_FRONTEND=noninteractive
  APT=(apt-get -o DPkg::Lock::Timeout=180)
  log "Voltach Unified Installer v${VERSION}"
  log "Detected ${PRETTY_NAME}"
}

apt_prepare() {
  info "Refreshing package metadata..."
  "${APT[@]}" update
  "${APT[@]}" install -y ca-certificates curl gnupg openssl lsb-release iproute2
  if [[ $UPGRADE_SYSTEM -eq 1 ]]; then
    "${APT[@]}" upgrade -y
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    success "Docker Engine and Compose V2 already available."
    return
  fi

  info "Installing Docker Engine from Docker's signed repository..."
  local pkg
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' && "${APT[@]}" remove -y "$pkg" || true
  done

  install -m 0755 -d /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die "Unable to determine OS codename."
  cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  "${APT[@]}" update
  "${APT[@]}" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  success "Docker installed."
}

# ---------- Server management stack ----------
install_webmin() {
  [[ $INSTALL_WEBMIN -eq 1 ]] || return 0
  if dpkg-query -W -f='${Status}' webmin 2>/dev/null | grep -q 'ok installed'; then
    success "Webmin already installed."
    return
  fi
  info "Installing Webmin..."
  local setup="/tmp/webmin-setup-repo.sh"
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh -o "$setup"
  chmod 700 "$setup"
  "$setup" --stable --force
  "${APT[@]}" update
  "${APT[@]}" install -y --install-recommends webmin
  rm -f "$setup"
  success "Webmin installed."
}

ensure_proxy_network() {
  docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || docker network create "$PROXY_NETWORK" >/dev/null
}

install_npm() {
  [[ $INSTALL_NPM -eq 1 ]] || return 0
  ensure_proxy_network
  if docker ps -a --format '{{.Image}} {{.Names}}' | grep -q '^jc21/nginx-proxy-manager:'; then
    success "Existing NGINX Proxy Manager detected; preserving it."
    return
  fi
  local dir="/opt/nginx-proxy-manager"
  mkdir -p "$dir"
  cat > "$dir/compose.yaml" <<'NPM_COMPOSE'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: voltach-npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    environment:
      DISABLE_IPV6: "true"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - voltach_proxy
networks:
  voltach_proxy:
    external: true
NPM_COMPOSE
  docker compose -f "$dir/compose.yaml" pull
  docker compose -f "$dir/compose.yaml" up -d
  success "NGINX Proxy Manager running."
}

install_portainer() {
  [[ $INSTALL_PORTAINER -eq 1 ]] || return 0
  if docker container inspect voltach-portainer >/dev/null 2>&1; then
    docker start voltach-portainer >/dev/null 2>&1 || true
    success "Portainer already exists; preserving it."
    return
  fi
  if docker container inspect portainer >/dev/null 2>&1; then
    docker start portainer >/dev/null 2>&1 || true
    success "Existing Portainer detected; preserving it."
    return
  fi

  local dir="/opt/portainer" secret_dir="$dir/secrets" password_file="$dir/secrets/admin_password" admin_password=""
  mkdir -p "$secret_dir" && chmod 700 "$dir" "$secret_dir"
  if [[ ! -s "$password_file" ]]; then
    echo
    echo "Portainer Administrator Setup (username: admin)"
    prompt_password "Portainer admin password" 12 admin_password
    printf '%s\n' "$admin_password" > "$password_file"
    chmod 600 "$password_file"
    unset admin_password
  fi

  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  docker pull portainer/portainer-ce:latest >/dev/null
  docker run -d --name voltach-portainer --restart unless-stopped \
    -p 8000:8000 -p 9000:9000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    -v "$password_file:/run/secrets/portainer_admin_password:ro" \
    portainer/portainer-ce:latest \
    --admin-password-file=/run/secrets/portainer_admin_password >/dev/null
  success "Portainer running."
}

# ---------- Odoo instance engine ----------
port_in_use() {
  local p="$1"
  ss -tuln 2>/dev/null | grep -Eq "[:.]${p}[[:space:]]|:${p}$" && return 0
  return 1
}

allocate_ports() {
  local ver="$1"
  local http_base=$((8000 + ver)) chat_base=$((9000 + ver)) db_base=$((5400 + ver - 10)) n=0
  while (( n <= 99 )); do
    local h=$((http_base + n * 10)) c=$((chat_base + n * 10)) d=$((db_base + n))
    if ! port_in_use "$h" && ! port_in_use "$c" && ! port_in_use "$d"; then
      HTTP_PORT="$h"; CHAT_PORT="$c"; DB_PORT="$d"; return 0
    fi
    ((n+=1))
  done
  die "No free port combination found for Odoo ${ver}."
}

auto_name() {
  local ver="$1" base="odoo${ver}" n=1
  while [[ -d "${INSTANCES_DIR}/${base}-${n}" ]]; do ((n+=1)); done
  printf '%s\n' "${base}-${n}"
}

list_instances() {
  [[ -d "$INSTANCES_DIR" ]] || return 0
  local found=0
  for inst in "$INSTANCES_DIR"/*; do
    [[ -d "$inst" ]] || continue
    found=1
    local name; name="$(basename "$inst")"
    local hp="?" ver="?"
    if [[ -f "$inst/.env" ]]; then
      hp="$(grep -E '^ODOO_HTTP_PORT=' "$inst/.env" | cut -d= -f2 || true)"
      ver="$(grep -E '^ODOO_VERSION=' "$inst/.env" | cut -d= -f2 || true)"
    fi
    printf '  %-24s Odoo %-3s HTTP %s\n' "$name" "$ver" "$hp"
  done
  if [[ $found -eq 1 ]]; then
    echo
  fi
  return 0
}

tune_hardware() {
  local ram_mb; ram_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if (( ram_mb < 2048 )); then
    SHARED_BUFFERS="256MB"; EFFECTIVE_CACHE_SIZE="768MB"; WORK_MEM="32MB"; MAINTENANCE_WORK_MEM="128MB"; WORKERS_COUNT=2
  elif (( ram_mb < 4096 )); then
    SHARED_BUFFERS="512MB"; EFFECTIVE_CACHE_SIZE="1536MB"; WORK_MEM="64MB"; MAINTENANCE_WORK_MEM="256MB"; WORKERS_COUNT=3
  elif (( ram_mb < 8192 )); then
    SHARED_BUFFERS="1GB"; EFFECTIVE_CACHE_SIZE="3GB"; WORK_MEM="128MB"; MAINTENANCE_WORK_MEM="512MB"; WORKERS_COUNT=5
  else
    SHARED_BUFFERS="2GB"; EFFECTIVE_CACHE_SIZE="6GB"; WORK_MEM="256MB"; MAINTENANCE_WORK_MEM="1GB"; WORKERS_COUNT=$(( $(nproc) * 2 + 1 ))
  fi
}

resolve_image() {
  local version="$1" candidate="odoo:${version}" custom=""
  ODOO_VERSION="$version"
  ODOO_VER_DOT="${version}.0"

  info "Checking Docker image ${candidate}..."
  if docker image inspect "$candidate" >/dev/null 2>&1 || docker pull "$candidate" >/dev/null 2>&1; then
    ODOO_IMAGE="$candidate"
    success "Using ${ODOO_IMAGE}."
    return
  fi

  warn "${candidate} is not available from this Docker environment."
  read_tty "Enter custom Odoo ${version} Docker image [example myrepo/odoo:${version}]: " custom ""
  [[ -n "$custom" ]] || die "A valid image is required for Odoo ${version}."
  ODOO_IMAGE="$custom"
  docker image inspect "$ODOO_IMAGE" >/dev/null 2>&1 || docker pull "$ODOO_IMAGE"
}

select_odoo() {
  echo
  echo -e "${BOLD}Existing unified instances:${NC}"
  list_instances
  echo -e "${BOLD}Select Odoo version:${NC}"
  echo "  1) Odoo 20"
  echo "  2) Odoo 19"
  echo "  3) Odoo 18"
  echo "  4) Odoo 17"
  echo "  5) Odoo 16"
  echo "  6) Custom image/version"
  local choice="3" version="18" custom_image="" custom_version=""
  read_tty "Choice [1-6, default 3]: " choice "3"
  case "$choice" in
    1) version=20; resolve_image "$version" ;;
    2) version=19; resolve_image "$version" ;;
    3) version=18; resolve_image "$version" ;;
    4) version=17; resolve_image "$version" ;;
    5) version=16; resolve_image "$version" ;;
    6)
      read_tty "Odoo major version [16-20]: " custom_version "18"
      [[ "$custom_version" =~ ^(16|17|18|19|20)$ ]] || die "Version must be 16, 17, 18, 19 or 20."
      read_tty "Docker image tag: " custom_image "odoo:${custom_version}"
      ODOO_VERSION="$custom_version"; ODOO_VER_DOT="${custom_version}.0"; ODOO_IMAGE="$custom_image"; version="$custom_version"
      docker image inspect "$ODOO_IMAGE" >/dev/null 2>&1 || docker pull "$ODOO_IMAGE"
      ;;
    *) version=18; resolve_image "$version" ;;
  esac

  allocate_ports "$version"
  local default_name; default_name="$(auto_name "$version")"
  read_tty "Instance name [${default_name}]: " INSTANCE_NAME "$default_name"
  [[ "$INSTANCE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Invalid instance name. Use letters, numbers, dot, dash, underscore."
  TARGET_DIR="${INSTANCES_DIR}/${INSTANCE_NAME}"
  [[ ! -e "$TARGET_DIR" ]] || die "Instance path already exists: ${TARGET_DIR}"

  tune_hardware
  POSTGRES_PASSWORD="$(new_secret)"
  echo
  prompt_password "Odoo Database Manager master password" 12 ODOO_MASTER_PASSWORD
}

hash_master_password() {
  # Use the selected Odoo image itself so hashing matches its Odoo version.
  ODOO_MASTER_HASH="$(printf '%s' "$ODOO_MASTER_PASSWORD" | docker run --rm -i --entrypoint python3 "$ODOO_IMAGE" -c 'import sys; from odoo.tools.config import crypt_context; print(crypt_context.hash(sys.stdin.read()))')"
  [[ -n "$ODOO_MASTER_HASH" ]] || die "Failed to hash Odoo master password."
}

create_instance() {
  mkdir -p "$TARGET_DIR"/{etc/addons/${ODOO_VER_DOT},data,db_data,backups,init-db,secrets}
  chmod 700 "$TARGET_DIR" "$TARGET_DIR/secrets"
  chmod 755 "$TARGET_DIR/etc/addons/${ODOO_VER_DOT}"

  printf '%s\n' "$POSTGRES_PASSWORD" > "$TARGET_DIR/secrets/postgresql_password"
  printf '%s\n' "$ODOO_MASTER_PASSWORD" > "$TARGET_DIR/secrets/odoo_master_password"
  chmod 600 "$TARGET_DIR/secrets/"*
  hash_master_password

  cat > "$TARGET_DIR/init-db/01-extensions.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
\c template1
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

  cat > "$TARGET_DIR/etc/odoo.conf" <<ODOO_CONF
[options]
admin_passwd = ${ODOO_MASTER_HASH}
db_host = db
db_port = 5432
db_user = ${POSTGRES_USER}
db_password = ${POSTGRES_PASSWORD}
db_name =
db_maxconn = 64
dbfilter = .*
list_db = True
proxy_mode = True
http_interface = 0.0.0.0
http_port = 8069
gevent_port = 8072
addons_path = /mnt/extra-addons/${ODOO_VER_DOT},/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo
workers = ${WORKERS_COUNT}
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 1800
log_level = info
ODOO_CONF
  chmod 644 "$TARGET_DIR/etc/odoo.conf"

  cat > "$TARGET_DIR/.env" <<ENV
COMPOSE_PROJECT_NAME=voltach_$(echo "$INSTANCE_NAME" | tr '.-' '__')
INSTANCE_NAME=${INSTANCE_NAME}
ODOO_VERSION=${ODOO_VERSION}
ODOO_VER_DOT=${ODOO_VER_DOT}
ODOO_IMAGE=${ODOO_IMAGE}
POSTGRES_IMAGE=${PG_IMAGE}
ODOO_HTTP_PORT=${HTTP_PORT}
ODOO_CHAT_PORT=${CHAT_PORT}
POSTGRES_EXTERNAL_PORT=${DB_PORT}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
SHARED_BUFFERS=${SHARED_BUFFERS}
EFFECTIVE_CACHE_SIZE=${EFFECTIVE_CACHE_SIZE}
WORK_MEM=${WORK_MEM}
MAINTENANCE_WORK_MEM=${MAINTENANCE_WORK_MEM}
ENV
  chmod 600 "$TARGET_DIR/.env"

  ensure_proxy_network
  cat > "$TARGET_DIR/compose.yaml" <<COMPOSE
services:
  db:
    image: ${PG_IMAGE}
    container_name: voltach-db-${INSTANCE_NAME}
    restart: unless-stopped
    command: >
      postgres
        -c shared_buffers=${SHARED_BUFFERS}
        -c effective_cache_size=${EFFECTIVE_CACHE_SIZE}
        -c work_mem=${WORK_MEM}
        -c maintenance_work_mem=${MAINTENANCE_WORK_MEM}
        -c max_connections=200
        -c random_page_cost=1.1
        -c checkpoint_completion_target=0.9
        -c wal_buffers=16MB
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./db_data:/var/lib/postgresql/data
      - ./init-db:/docker-entrypoint-initdb.d:ro
    ports:
      - "127.0.0.1:${DB_PORT}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 15s
    networks:
      - internal

  web:
    image: ${ODOO_IMAGE}
    container_name: voltach-odoo-${INSTANCE_NAME}
    restart: unless-stopped
    command: ["--config", "/etc/odoo/odoo.conf"]
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: db
      PORT: "5432"
      USER: ${POSTGRES_USER}
      PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${HTTP_PORT}:8069"
      - "${CHAT_PORT}:8072"
    volumes:
      - ./etc/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./etc/addons/${ODOO_VER_DOT}:/mnt/extra-addons/${ODOO_VER_DOT}
      - ./data:/var/lib/odoo
    networks:
      - internal
      - ${PROXY_NETWORK}

networks:
  internal:
    internal: true
  ${PROXY_NETWORK}:
    external: true
COMPOSE

  (cd "$TARGET_DIR" && docker compose config >/dev/null)
  info "Starting ${INSTANCE_NAME}..."
  (cd "$TARGET_DIR" && docker compose pull && docker compose up -d)
  unset ODOO_MASTER_HASH ODOO_MASTER_PASSWORD POSTGRES_PASSWORD
  success "Odoo instance started."
}

install_cli() {
  cat > "${GLOBAL_BIN}/${CLI_NAME}" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/voltach-odoo/instances"
cmd="${1:-list}"; inst="${2:-}"
all(){ [[ -d "$BASE" ]] && find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort || true; }
req(){ [[ -n "$inst" && -d "$BASE/$inst" ]] || { echo "Instance not found: ${inst:-<none>}" >&2; echo "Available:"; all; exit 1; }; }
ev(){ grep -E "^${1}=" "$BASE/$2/.env" 2>/dev/null | cut -d= -f2- || true; }
case "$cmd" in
  list)
    printf '%-24s %-8s %-8s %-8s %s\n' INSTANCE VERSION HTTP CHAT STATUS
    while read -r x; do
      [[ -n "$x" ]] || continue
      s="stopped"; docker ps --format '{{.Names}}' | grep -qx "voltach-odoo-$x" && s="running"
      printf '%-24s %-8s %-8s %-8s %s\n' "$x" "$(ev ODOO_VERSION "$x")" "$(ev ODOO_HTTP_PORT "$x")" "$(ev ODOO_CHAT_PORT "$x")" "$s"
    done < <(all)
    ;;
  ps) docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'voltach-(odoo|db)-|NAMES' ;;
  start|stop|restart) req; (cd "$BASE/$inst" && docker compose "$cmd") ;;
  logs) req; (cd "$BASE/$inst" && docker compose logs -f --tail=200) ;;
  info)
    req
    echo "Instance: $inst"
    echo "Odoo:     $(ev ODOO_VERSION "$inst")"
    echo "HTTP:     $(ev ODOO_HTTP_PORT "$inst")"
    echo "Chat:     $(ev ODOO_CHAT_PORT "$inst")"
    echo "DB local: 127.0.0.1:$(ev POSTGRES_EXTERNAL_PORT "$inst")"
    echo "Addons:   $BASE/$inst/etc/addons/$(ev ODOO_VER_DOT "$inst")"
    echo "Config:   $BASE/$inst/etc/odoo.conf"
    echo "Secrets:  $BASE/$inst/secrets (root only)"
    ;;
  backup)
    req
    ts="$(date +%Y%m%d_%H%M%S)"; b="$BASE/$inst/backups"; mkdir -p "$b"
    u="$(ev POSTGRES_USER "$inst")"
    docker exec "voltach-db-$inst" pg_dumpall -U "$u" > "$b/db_$ts.sql"
    tar -czf "$b/backup_${inst}_${ts}.tar.gz" -C "$BASE/$inst" data etc "backups/db_$ts.sql"
    rm -f "$b/db_$ts.sql"
    echo "$b/backup_${inst}_${ts}.tar.gz"
    ;;
  *) echo "Usage: voltach-odoo {list|ps|start|stop|restart|logs|info|backup} [instance]" ;;
esac
CLI
  chmod +x "${GLOBAL_BIN}/${CLI_NAME}"
  ln -sf "${GLOBAL_BIN}/${CLI_NAME}" "${GLOBAL_BIN}/vodoo"
  success "Management CLI installed: voltach-odoo (alias: vodoo)."
}

server_ip() {
  curl -s -4 --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

summary() {
  local ip; ip="$(server_ip)"
  echo
  echo -e "${GREEN}${BOLD}Installation complete.${NC}"
  [[ $INSTALL_WEBMIN -eq 1 ]] && echo "Webmin:                https://${ip}:10000"
  [[ $INSTALL_NPM -eq 1 ]] && echo "NGINX Proxy Manager:   http://${ip}:81"
  [[ $INSTALL_PORTAINER -eq 1 ]] && echo "Portainer:             https://${ip}:9443"
  if [[ $INSTALL_ODOO -eq 1 ]]; then
    echo "Odoo ${ODOO_VERSION}:              http://${ip}:${HTTP_PORT}"
    echo "Instance:              ${INSTANCE_NAME}"
    echo "Root:                  ${TARGET_DIR}"
    echo "Custom addons:         ${TARGET_DIR}/etc/addons/${ODOO_VER_DOT}/"
    echo "PostgreSQL:            17 + pgvector (loopback ${DB_PORT})"
    echo "Manage:                voltach-odoo list"
  fi
  echo "Log:                   ${LOG_FILE}"
  echo
}

main() {
  banner
  preflight
  apt_prepare
  install_docker
  install_webmin
  install_npm
  install_portainer
  if [[ $INSTALL_ODOO -eq 1 ]]; then
    select_odoo
    create_instance
    install_cli
  fi
  summary
}

main "$@"
