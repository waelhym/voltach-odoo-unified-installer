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
  local ver="$1" http_base=$((8000 + ver)) chat_base=$((9000 + ver)) db_base=$((5400 + ver - 10)) n=0
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
    [[ -f "$inst/.env" ]] && hp="$(grep -E '^ODOO_HTTP_PORT=' "$inst/.env" | cut -d= -f2 || true)" && ver="$(grep -E '^ODOO_VERSION=' "$inst/.env" | cut -d= -f2 || true)"
    printf '  %-24s Odoo %-3s HTTP %s\n' "$name" "$ver" "$hp"
  done
  [[ $found -eq 1 ]] && echo
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
    4) version=17; resolve_imae "$version" ;;
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
CREATE EXTENSION IF NOT EXISTS unaccentçC°¤5$TDRUDTå4ôâbäõBU5E2'WVBÖ÷77#°¤5$TDRUDTå4ôâbäõBU5E2u÷G&vÓ°¥5À ¢6Bâ"ED$tUEôD"öWF2ööFöòæ6öæb"ÃÄôDôõô4ôä`¥¶÷Föç5Ð¦FÖå÷77vBÒG´ôDôõôÔ5DU%ô4Ð¦F%ö÷7BÒF ¦F%÷÷'BÒSC3 ¦F%÷W6W"ÒGµõ5Du$U5õU4U'Ð¦F%÷77v÷&BÒGµõ5Du$U5õ55tõ$GÐ¦F%öæÖRÐ¦F%öÖ6öæâÒc@¦F&fÇFW"Òâ ¦Æ7EöF"ÒG'VP§&÷öÖöFRÒG'VP¦GGöçFW&f6RÒããã ¦GG÷÷'BÒc¦vWfVçE÷÷'BÒs ¦FFöç5÷FÒöÖçBöWG&ÖFFöç2òG´ôDôõõdU%ôDõGÒÂ÷W7"öÆ"÷Föã2öF7B×6¶vW2ööFöòöFFöç0¦FFöF"Ò÷f"öÆ"ööFöð§v÷&¶W'2ÒGµtõ$´U%5ô4õTåGÐ¦Öö7&öå÷F&VG2Ò ¦ÆÖEöÖVÖ÷'ö&BÒ#cC3SCSc ¦ÆÖEöÖVÖ÷'÷6ögBÒ#CsC3cC¦ÆÖE÷&WVW7BÒ ¦ÆÖE÷FÖUö7RÒc ¦ÆÖE÷FÖU÷&VÂÒ# ¦ÆÖE÷FÖU÷&VÅö7&öâÒ ¦ÆöuöÆWfVÂÒæfð¤ôDôõô4ôä`¢6ÖöBcCB"ED$tUEôD"öWF2ööFöòæ6öæb  ¢6Bâ"ED$tUEôD"òæVçb"ÃÄTå`¤4ôÕõ4Uõ$ô¤T5EôäÔS×föÇF6òBV6ò"Då5Dä4UôäÔR"ÂG"râÒruõòr¤å5Dä4UôäÔSÒG´å5Dä4UôäÔWÐ¤ôDôõõdU%4ôãÒG´ôDôõõdU%4ôçÐ¤ôDôõõdU%ôDõCÒG´ôDôõõdU%ôDõGÐ¤ôDôõôÔtSÒG´ôDôõôÔtWÐ¥õ5Du$U5ôÔtSÒGµuôÔtWÐ¤ôDôõôEEõõ%CÒG´EEõõ%GÐ¤ôDôõô4Eõõ%CÒG´4Eõõ%GÐ¥õ5Du$U5ôUDU$äÅõõ%CÒG´D%õõ%GÐ¥õ5Du$U5õU4U#ÒGµõ5Du$U5õU4U'Ð¥õ5Du$U5õ55tõ$CÒGµõ5Du$U5õ55tõ$GÐ¥õ5Du$U5ôD#ÒGµõ5Du$U5ôD'Ð¥4$TEô%TddU%3ÒGµ4$TEô%TddU%7Ð¤TddT5DdUô44Uõ4¤SÒG´TddT5DdUô44Uõ4¤WÐ¥tõ$µôÔTÓÒGµtõ$µôÔT×Ð¤ÔåDTää4Uõtõ$µôÔTÓÒG´ÔåDTää4Uõtõ$µôÔT×Ð¤Tå`¢6ÖöBc"ED$tUEôD"òæVçb  ¢Vç7W&U÷&÷öæWGv÷&°¢6Bâ"ED$tUEôD"ö6ö×÷6RçÖÂ"ÃÄ4ôÕõ4P§6W'f6W3 ¢F# ¢ÖvS¢GµuôÔtWÐ¢6öçFæW%öæÖS¢föÇF6ÖF"ÒG´å5Dä4UôäÔWÐ¢&W7F'C¢VæÆW72×7F÷V@¢6öÖÖæC¢à¢÷7Fw&W0¢Ö26&VEö'VffW'3ÒGµ4$TEô%TddU%7Ð¢Ö2VffV7FfUö66U÷6¦SÒG´TddT5DdUô44Uõ4¤WÐ¢Ö2v÷&µöÖVÓÒGµtõ$µôÔT×Ð¢Ö2ÖçFVææ6U÷v÷&µöÖVÓÒG´ÔåDTää4Uõtõ$µôÔT×Ð¢Ö2Öö6öææV7Föç3Ó# ¢Ö2&æFöÕ÷vUö6÷7CÓã¢Ö26V6·öçEö6ö×ÆWFöå÷F&vWCÓã¢Ö2vÅö'VffW'3ÓdÔ ¢Vçf&öæÖVçC ¢õ5Du$U5ôD#¢Gµõ5Du$U5ôD'Ð¢õ5Du$U5õU4U#¢Gµõ5Du$U5õU4U'Ð¢õ5Du$U5õ55tõ$C¢Gµõ5Du$U5õ55tõ$GÐ¢tDD¢÷f"öÆ"÷÷7Fw&W7ÂöFF÷vFF¢föÇVÖW3 ¢ÒâöF%öFF¢÷f"öÆ"÷÷7Fw&W7ÂöFF¢ÒâöæBÖF#¢öFö6¶W"ÖVçG'öçBÖæFF"æC§&ð¢÷'G3 ¢Ò##rããã¢G´D%õõ%GÓ£SC3" ¢VÇF6V6³ ¢FW7C¢²$4ÔBÕ4TÄÂ"Â'uö7&VGÕRGµõ5Du$U5õU4U'ÒÖBGµõ5Du$U5ôD'Ò%Ð¢çFW'fÃ¢W0¢FÖV÷WC¢W0¢&WG&W3¢# ¢7F'E÷W&öC¢W0¢æWGv÷&·3 ¢ÒçFW&æÀ ¢vV# ¢ÖvS¢G´ôDôõôÔtWÐ¢6öçFæW%öæÖS¢föÇF6ÖöFöòÒG´å5Dä4UôäÔWÐ¢&W7F'C¢VæÆW72×7F÷V@¢6öÖÖæC¢²"ÒÖ6öæfr"Â"öWF2ööFöòööFöòæ6öæb%Ð¢FWVæG5ööã ¢F# ¢6öæFFöã¢6W'f6UöVÇF¢Vçf&öæÖVçC ¢õ5C¢F ¢õ%C¢#SC3" ¢U4U#¢Gµõ5Du$U5õU4U'Ð¢55tõ$C¢Gµõ5Du$U5õ55tõ$GÐ¢÷'G3 ¢Ò"G´EEõõ%GÓ£c ¢Ò"G´4Eõõ%GÓ£s" ¢föÇVÖW3 ¢ÒâöWF2ööFöòæ6öæc¢öWF2ööFöòööFöòæ6öæc§&ð¢ÒâöWF2öFFöç2òG´ôDôõõdU%ôDõGÓ¢öÖçBöWG&ÖFFöç2òG´ôDôõõdU%ôDõGÐ¢ÒâöFF¢÷f"öÆ"ööFöð¢æWGv÷&·3 ¢ÒçFW&æÀ¢ÒGµ$õôäUEtõ$·Ð ¦æWGv÷&·3 ¢çFW&æÃ ¢çFW&æÃ¢G'VP¢Gµ$õôäUEtõ$·Ó ¢WFW&æÃ¢G'VP¤4ôÕõ4P ¢6B"ED$tUEôD""bbFö6¶W"6ö×÷6R6öæfrâöFWböçVÆÂ¢æfò%7F'FærG´å5Dä4UôäÔWÒâââ ¢6B"ED$tUEôD""bbFö6¶W"6ö×÷6RVÆÂbbFö6¶W"6ö×÷6RWÖB¢Vç6WBôDôõôÔ5DU%ô4ôDôõôÔ5DU%õ55tõ$Bõ5Du$U5õ55tõ$@¢7V66W72$öFöòç7Fæ6R7F'FVBâ §Ð ¦ç7FÆÅö6Æ°¢6Bâ"G´tÄô$Åô$çÒòG´4ÄôäÔWÒ"ÃÂt4Äp¢2÷W7"ö&âöVçb&6§6WBÖWVòVfÀ¤$4SÒ"ö÷B÷föÇF6ÖöFöòöç7Fæ6W2 ¦6ÖCÒ"G³¢ÖÆ7GÒ#²ç7CÒ"G³#¢×Ò ¦ÆÂ²µ²ÖB"D$4R"ÕÒbbfæB"D$4R"ÖÖæFWFÖÖFWF×GRB×&çFbrVeÆârÂ6÷'BÇÂG'VS²Ð§&W²µ²Öâ"Fç7B"bbÖB"D$4RòFç7B"ÕÒÇÂ²V6ò$ç7Fæ6Ræ÷Bf÷VæC¢G¶ç7C¢ÓÆæöæSçÒ"âc#²V6ò$fÆ&ÆS¢#²ÆÃ²WB²Ó²Ð¦Wb²w&WÔR%âG³ÓÒ""D$4RòC"òæVçb"#âöFWböçVÆÂÂ7WBÖCÒÖc"ÒÇÂG'VS²Ð¦66R"F6ÖB"à¢Æ7B¢&çFbrRÓ#G2RÓ2RÓ2RÓ2W5Æârå5Dä4RdU%4ôâEE4B5DEU0¢vÆR&VB×"²Fð¢µ²Öâ"G"ÕÒÇÂ6öçFçVP¢3Ò'7F÷VB#²Fö6¶W"2ÒÖf÷&ÖBw·²äæÖW7×ÒrÂw&W×'föÇF6ÖöFöòÒG"bb3Ò''Vææær ¢&çFbrRÓ#G2RÓ2RÓ2RÓ2W5Æâr"G""BWbôDôõõdU%4ôâ"G"""BWbôDôõôEEõõ%B"G"""BWbôDôõô4Eõõ%B"G"""G2 ¢FöæRÂÂÆÂ¢³°¢2Fö6¶W"2ÒÖf÷&ÖBwF&ÆR·²äæÖW7×ÕÇG·²å7FGW7×ÕÇG·²å÷'G7×ÒrÂw&WÔRwföÇF6ÒöFö÷ÆF"×ÄäÔU2r³°¢7F'GÇ7F÷Ç&W7F'B&W²6B"D$4RòFç7B"bbFö6¶W"6ö×÷6R"F6ÖB"³°¢Æöw2&W²6B"D$4RòFç7B"bbFö6¶W"6ö×÷6RÆöw2ÖbÒ×FÃÓ#³°¢æfò¢&W¢V6ò$ç7Fæ6S¢Fç7B ¢V6ò$öFöó¢BWbôDôõõdU%4ôâ"Fç7B" ¢V6ò$EE¢BWbôDôõôEEõõ%B"Fç7B" ¢V6ò$6C¢BWbôDôõô4Eõõ%B"Fç7B" ¢V6ò$D"Æö6Ã¢#rããã¢BWbõ5Du$U5ôUDU$äÅõõ%B"Fç7B" ¢V6ò$FFöç3¢D$4RòFç7BöWF2öFFöç2òBWbôDôõõdU%ôDõB"Fç7B" ¢V6ò$6öæfs¢D$4RòFç7BöWF2ööFöòæ6öæb ¢V6ò%6V7&WG3¢D$4RòFç7B÷6V7&WG2&ö÷BöæÇ ¢³°¢&6·W¢&W¢G3Ò"BFFR²UVÒVEòTTÒU2#²#Ò"D$4RòFç7Bö&6·W2#²Ö¶F"×"F" ¢SÒ"BWbõ5Du$U5õU4U""Fç7B" ¢Fö6¶W"WV2'föÇF6ÖF"ÒFç7B"uöGV×ÆÂÕR"GR"â"F"öF%òGG2ç7Â ¢F"Ö7¦b"F"ö&6·WòG¶ç7GÕòG·G7ÒçF"æw¢"Ô2"D$4RòFç7B"FFWF2&&6·W2öF%òGG2ç7Â ¢&ÒÖb"F"öF%òGG2ç7Â ¢V6ò"F"ö&6·WòG¶ç7GÕòG·G7ÒçF"æw¢ ¢³°¢¢V6ò%W6vS¢föÇF6ÖöFöò¶Æ7GÇ7Ç7F'GÇ7F÷Ç&W7F'GÆÆöw7Ææf÷Æ&6·WÒ¶ç7Fæ6UÒ"³°¦W60¤4Ä¢6ÖöB·"G´tÄô$Åô$çÒòG´4ÄôäÔWÒ ¢Æâ×6b"G´tÄô$Åô$çÒòG´4ÄôäÔWÒ""G´tÄô$Åô$çÒ÷föFöò ¢7V66W72$ÖævVÖVçB4Äç7FÆÆVC¢föÇF6ÖöFöòÆ3¢föFöòâ §Ð §6W'fW%ö°¢7W&Â×2ÓBÒÖÖ×FÖR2f6öæfræÖR#âöFWböçVÆÂÇÂ÷7FæÖRÔÂv²w·&çBCÒp§Ð §7VÖÖ'°¢Æö6Â²Ò"B6W'fW%ö ¢V6ð¢V6òÖR"G´u$TTçÒG´$ôÄGÔç7FÆÆFöâ6ö×ÆWFRâG´ä7Ò ¢µ²Då5DÄÅõtT$ÔâÖWÕÒbbV6ò%vV&Öã¢GG3¢òòG¶Ó£ ¢µ²Då5DÄÅôåÒÖWÕÒbbV6ò$ätå&÷ÖævW#¢GG¢òòG¶Ó£ ¢µ²Då5DÄÅõõ%DäU"ÖWÕÒbbV6ò%÷'FæW#¢GG3¢òòG¶Ó£CC2 ¢bµ²Då5DÄÅôôDôòÖWÕÓ²FVà¢V6ò$öFöòG´ôDôõõdU%4ôçÓ¢GG¢òòG¶Ó¢G´EEõõ%GÒ ¢V6ò$ç7Fæ6S¢G´å5Dä4UôäÔWÒ ¢V6ò%&ö÷C¢GµD$tUEôD'Ò ¢V6ò$7W7FöÒFFöç3¢GµD$tUEôD'ÒöWF2öFFöç2òG´ôDôõõdU%ôDõGÒò ¢V6ò%÷7Fw&U5Ã¢r²wfV7F÷"Æö÷&6²G´D%õõ%GÒ ¢V6ò$ÖævS¢föÇF6ÖöFöòÆ7B ¢f¢V6ò$Æös¢G´ÄôuôdÄWÒ ¢V6ð§Ð ¦Öâ°¢&ææW ¢&VfÆv@¢E÷&W&P¢ç7FÆÅöFö6¶W ¢ç7FÆÅ÷vV&Öà¢ç7FÆÅöçÐ¢ç7FÆÅ÷÷'FæW ¢bµ²Då5DÄÅôôDôòÖWÕÓ²FVà¢6VÆV7EööFöð¢7&VFUöç7Fæ6P¢ç7FÆÅö6Æ¢f¢7VÖÖ'§Ð ¦Öâ"D 