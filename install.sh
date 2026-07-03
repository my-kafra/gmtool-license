#!/usr/bin/env bash
# gmtool — customer install script (AlmaLinux / RHEL-family, Docker + watchtower + license).
#
#   curl -fsSL https://<static-host>/install.sh | bash
#
# Self-contained: writes docker-compose.yml / .env / settings.json into
# $GMTOOL_DIR (default ~/gmtool) and boots the stack. Idempotent — existing
# files are NEVER overwritten; re-running repairs/starts and re-checks the
# license (run it again after dropping license.json in place).
#
# Privilege model (auto-detected):
#   - root or sudo        → can install docker-ce + open firewalld port
#   - no sudo             → requires a working `docker` (group member or
#                           rootless); otherwise exits with an admin checklist
#
# Values may be passed as env vars to skip prompts (hybrid input model):
#   GMTOOL_DIR GHCR_USER GHCR_TOKEN IMAGE PORT
#   MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE
#   MODE (Renewal|Pre-Renewal)  RATHENA_DIR  FIREWALL (1|0)
#
# Vendor: set IMAGE_DEFAULT below before uploading to the static host.
set -euo pipefail

# ----------------------------------------------------------------------------
# vendor constants — EDIT BEFORE UPLOAD
IMAGE_DEFAULT="ghcr.io/my-kafra/gmtool:stable"
VENDOR_CONTACT="nuttapol.cr@gmail.com"
# ----------------------------------------------------------------------------

GMTOOL_DIR="${GMTOOL_DIR:-$HOME/gmtool}"
PORT="${PORT:-8888}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_off=$'\033[0m'
say()  { printf '%s\n' "${c_cyn}==>${c_off} $*"; }
ok()   { printf '%s\n' "${c_grn} ✓ ${c_off} $*"; }
warn() { printf '%s\n' "${c_yel} ! ${c_off} $*"; }
die()  { printf '%s\n' "${c_red} ✗  $*${c_off}" >&2; exit 1; }

# /dev/tty can exist yet be unopenable (no controlling terminal, e.g. CI) —
# probe by actually opening it.
has_tty() { ( : < /dev/tty; ) 2>/dev/null; }

# Prompt helper: env value wins (SET counts, even if empty — so RATHENA_DIR=
# means "skip, no rAthena"); otherwise read from the terminal.
# curl|bash makes stdin the script itself, so ALWAYS read from /dev/tty.
ask() { # ask VAR "Prompt" "default" [secret]
  local var="$1" prompt="$2" def="${3:-}" secret="${4:-}" val
  if [ -n "${!var+x}" ]; then return 0; fi
  has_tty || die "No terminal for prompts — pass $var as an env var instead."
  if [ -n "$secret" ]; then
    read -r -s -p "$prompt${def:+ [$def]}: " val < /dev/tty; echo
  else
    read -r -p "$prompt${def:+ [$def]}: " val < /dev/tty
  fi
  printf -v "$var" '%s' "${val:-$def}"
}

# Escape a value for embedding inside a JSON string (passwords may contain " \).
jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ----------------------------------------------------------------------------
say "gmtool customer install"
echo "    install dir : $GMTOOL_DIR"
echo "    image       : ${IMAGE:-$IMAGE_DEFAULT}"

# --- privilege detection ------------------------------------------------------
SUDO=""
HAVE_ROOT=0
if [ "$(id -u)" = 0 ]; then
  HAVE_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HAVE_ROOT=1; SUDO="sudo"
elif command -v sudo >/dev/null 2>&1 && has_tty; then
  # sudo exists but needs a password — try once, interactively.
  if sudo -v < /dev/tty 2>/dev/null; then HAVE_ROOT=1; SUDO="sudo"; fi
fi
[ $HAVE_ROOT -eq 1 ] && ok "root privileges available${SUDO:+ (via sudo)}" \
                     || warn "no root/sudo — will use existing docker only"

admin_checklist() {
  cat <<EOF

${c_yel}--- ADMIN CHECKLIST (needs root — send this to your system administrator) ---${c_off}
 1. Install Docker CE + compose plugin:
      dnf -y install dnf-plugins-core
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf -y install --allowerasing docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable --now docker
 2. Allow this user to use docker:
      usermod -aG docker $USER        (then log out + back in)
    — or set up rootless docker (dnf install -y docker-ce-rootless-extras, then
      dockerd-rootless-setuptool.sh install) and enable lingering so it
      survives logout:  loginctl enable-linger $USER
 3. Open the web UI port in the firewall:
      firewall-cmd --permanent --add-port=${PORT}/tcp && firewall-cmd --reload
Then re-run this installer.
EOF
  exit 1
}

# --- docker availability ------------------------------------------------------
DOCKER="docker"
if docker info >/dev/null 2>&1; then
  ok "docker is usable as $USER"
elif [ $HAVE_ROOT -eq 1 ]; then
  if ! command -v docker >/dev/null 2>&1; then
    say "installing Docker CE (dnf)"
    $SUDO dnf -y install dnf-plugins-core
    $SUDO dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    $SUDO dnf -y install --allowerasing docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  $SUDO systemctl enable --now docker
  if [ "$(id -u)" != 0 ]; then
    $SUDO usermod -aG docker "$USER" || true
    warn "added $USER to the docker group — takes effect at next login; using sudo docker for this run"
  fi
  docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"
  ok "docker ready"
else
  warn "docker is not usable and there is no root/sudo to install it"
  admin_checklist
fi
$DOCKER compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing (docker-compose-plugin). Re-run with sudo available, or ask your admin."

# --- docker socket + config (watchtower needs both) ---------------------------
SOCK="${DOCKER_HOST:-$($DOCKER context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo unix:///var/run/docker.sock)}"
SOCK="${SOCK#unix://}"
case "$SOCK" in
  /*) ok "docker socket: $SOCK" ;;
  *)  warn "docker endpoint '$SOCK' is not a unix socket — watchtower auto-update will not work"; SOCK="/var/run/docker.sock" ;;
esac
if [ "$SOCK" != "/var/run/docker.sock" ]; then
  warn "rootless docker detected — auto-update stops at logout unless lingering is enabled:"
  warn "  (as root)  loginctl enable-linger $USER"
fi
DOCKER_CFG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
[ "$DOCKER" = "sudo docker" ] && DOCKER_CFG_DIR="/root/.docker"

# --- GHCR login ----------------------------------------------------------------
if grep -qs 'ghcr\.io' "$DOCKER_CFG_DIR/config.json" 2>/dev/null; then
  ok "already logged in to ghcr.io"
else
  say "GHCR login (credentials are provided by $VENDOR_CONTACT)"
  ask GHCR_USER  "GitHub username"
  ask GHCR_TOKEN "GHCR token (read:packages)" "" secret
  printf '%s' "$GHCR_TOKEN" | $DOCKER login ghcr.io -u "$GHCR_USER" --password-stdin \
    || die "ghcr.io login failed — check the token"
  ok "logged in to ghcr.io"
fi

# --- deployment directory ------------------------------------------------------
mkdir -p "$GMTOOL_DIR"/{public/{db,grf,system,icons,collection,npc},data,run}
cd "$GMTOOL_DIR"

# --- settings.json (prompt only when creating) ---------------------------------
if [ -f settings.json ]; then
  ok "settings.json exists — keeping it (delete it to reconfigure)"
  # Renamed in 2026-07: itemInfoGit/skillInfoGit collapsed into clientInfoGit.
  # The old keys are NO LONGER READ — git-save for client lub files silently
  # turns OFF until renamed.
  if grep -q '"itemInfoGit"\|"skillInfoGit"' settings.json; then
    warn "settings.json uses the legacy itemInfoGit/skillInfoGit keys — rename the block to \"clientInfoGit\" (old keys are ignored, client-file git-save is currently OFF)"
  fi
else
  say "rAthena database connection (the game MySQL/MariaDB)"
  ask MYSQL_HOST     "MySQL host" "127.0.0.1"
  ask MYSQL_PORT     "MySQL port" "3306"
  ask MYSQL_USER     "MySQL user" "ragnarok"
  ask MYSQL_PASSWORD "MySQL password" "" secret
  ask MYSQL_DATABASE "MySQL database" "ragnarok_main"
  ask MODE           "Server mode (Renewal / Pre-Renewal)" "Renewal"
  case "$MODE" in Renewal|Pre-Renewal) ;; *) die "MODE must be 'Renewal' or 'Pre-Renewal'";; esac
  case "$MYSQL_PORT" in ''|*[!0-9]*) die "MySQL port must be a number";; esac

  # Optional: point db/npc straight at a local rAthena checkout (read in place).
  ask RATHENA_DIR "rAthena directory on this machine (empty = copy files into public/ yourself)" ""
  DB_PATH="public/db"; NPC_PATH="public/npc"
  if [ -n "$RATHENA_DIR" ]; then
    [ -d "$RATHENA_DIR/db" ] && [ -d "$RATHENA_DIR/npc" ] \
      || die "$RATHENA_DIR does not look like rAthena (missing db/ or npc/)"
    RATHENA_DIR="$(cd "$RATHENA_DIR" && pwd)"
    DB_PATH="$RATHENA_DIR/db"; NPC_PATH="$RATHENA_DIR/npc"
    ok "db/npc will be read from $RATHENA_DIR (mounted into the container)"
  fi

  # TCP probe — warning only (the container connects on its own at boot).
  if ! (exec 3<>"/dev/tcp/$MYSQL_HOST/$MYSQL_PORT") 2>/dev/null; then
    warn "cannot reach $MYSQL_HOST:$MYSQL_PORT from here — check MySQL before login fails"
  else
    exec 3>&- 2>/dev/null || true
    ok "MySQL port reachable ($MYSQL_HOST:$MYSQL_PORT)"
  fi

  cat > settings.json <<EOF
{
  "_note": "Generated by install.sh. Full reference: settings.example.json in the docs. Paths are container paths; public/ data/ run/ are mounted from this directory.",
  "auth": {
    "mysql": {
      "host":     "$(jesc "$MYSQL_HOST")",
      "port":     $MYSQL_PORT,
      "user":     "$(jesc "$MYSQL_USER")",
      "password": "$(jesc "$MYSQL_PASSWORD")",
      "database": "$(jesc "$MYSQL_DATABASE")"
    },
    "minGroupId":      60,
    "sessionTtlHours": 4,
    "sessionFile":     ".data/auth.json"
  },
  "audit": { "enabled": true },
  "dbeditor": {
    "dbPath":         "$(jesc "$DB_PATH")",
    "npcPath":        "$(jesc "$NPC_PATH")",
    "itemInfoPath":   "public/system/itemInfo.lub",
    "grfPaths":       ["public/grf/data.grf"],
    "writableGrf":    "public/grf/custom.grf",
    "iconDir":        "public/icons",
    "collectionDir":  "public/collection",
    "textEncoding":   "windows-874",
    "mode":           "$MODE",
    "publicBaseUrl":  ""
  },
  "dashboard": {
    "serverStatus": {
      "enabled": true,
      "host":    "127.0.0.1",
      "ports": { "login": 6900, "char": 6121, "map": 5121 }
    }
  }
}
EOF
  ok "settings.json written"
fi

# --- .env -----------------------------------------------------------------------
if [ -f .env ]; then
  ok ".env exists — keeping it"
else
  cat > .env <<EOF
IMAGE=${IMAGE:-$IMAGE_DEFAULT}
PORT=$PORT
WATCHTOWER_POLL_INTERVAL=300
DOCKER_SOCK=$SOCK
DOCKER_CONFIG_JSON=$DOCKER_CFG_DIR/config.json
EOF
  ok ".env written"
fi

# --- docker-compose.yml -----------------------------------------------------------
if [ -f docker-compose.yml ]; then
  ok "docker-compose.yml exists — keeping it"
else
  # host network: 127.0.0.1 reaches MySQL + game ports directly; the app binds
  # $PORT on the host itself (no ports:/extra_hosts allowed in host mode).
  # :z = SELinux relabel for bind mounts (AlmaLinux is Enforcing by default).
  RA_MOUNT=""
  if [ -n "${RATHENA_DIR:-}" ] && [ -d "${RATHENA_DIR:-/nonexistent}" ]; then
    RA_MOUNT="      - $RATHENA_DIR:$RATHENA_DIR:z"$'\n'
  fi
  cat > docker-compose.yml <<EOF
services:
  gmtool:
    image: \${IMAGE}
    container_name: gmtool
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=\${PORT}
      - HOST=0.0.0.0
    volumes:
      - ./settings.json:/app/server/settings.json:ro,z
      - ./license.json:/app/server/license.json:ro,z
      - ./public:/app/server/public:z
      - ./data:/app/server/.data:z
      - ./run:/app/server/.run:z
$RA_MOUNT    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  watchtower:
    image: containrrr/watchtower
    container_name: gmtool-watchtower
    restart: unless-stopped
    security_opt:
      - label:disable
    volumes:
      - \${DOCKER_SOCK}:/var/run/docker.sock
      - \${DOCKER_CONFIG_JSON}:/config.json:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_POLL_INTERVAL=\${WATCHTOWER_POLL_INTERVAL}
      - WATCHTOWER_ROLLING_RESTART=true
EOF
  ok "docker-compose.yml written"
fi

# license.json placeholder: bind-mounting a MISSING file makes docker create a
# DIRECTORY in its place — pre-create an empty file so the mount is a file.
[ -e license.json ] || { touch license.json; ok "license.json placeholder created (replace with the real file from $VENDOR_CONTACT)"; }
[ -d license.json ] && die "license.json is a directory (bad earlier mount) — remove it and re-run"

# --- firewall (sudo mode only) ---------------------------------------------------
if [ $HAVE_ROOT -eq 1 ] && $SUDO systemctl is-active firewalld >/dev/null 2>&1; then
  FIREWALL="${FIREWALL:-}"
  if [ -z "$FIREWALL" ] && has_tty; then
    read -r -p "Open port $PORT/tcp in firewalld? [Y/n]: " a < /dev/tty
    case "${a:-Y}" in [Yy]*) FIREWALL=1 ;; *) FIREWALL=0 ;; esac
  fi
  if [ "${FIREWALL:-1}" = 1 ]; then
    $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null
    $SUDO firewall-cmd --reload >/dev/null
    ok "firewalld: $PORT/tcp open"
  else
    warn "firewalld untouched — the UI is only reachable locally / via your reverse proxy"
  fi
elif [ $HAVE_ROOT -eq 0 ]; then
  warn "no root — if the UI is unreachable, ask your admin: firewall-cmd --permanent --add-port=$PORT/tcp && firewall-cmd --reload"
fi

# --- boot ------------------------------------------------------------------------
say "starting containers"
$DOCKER compose up -d

say "waiting for gmtool health (up to 60s)"
HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  sleep 2
done
[ $HEALTH_OK -eq 1 ] || { $DOCKER compose logs --tail 30 gmtool || true; die "gmtool did not become healthy — see the logs above (usually a settings.json/MySQL problem)"; }
ok "gmtool is up on port $PORT"

# --- license status ---------------------------------------------------------------
LIC="$(curl -fsS "http://127.0.0.1:$PORT/api/license" 2>/dev/null || true)"
MODE_NOW="$(printf '%s' "$LIC" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
FP="$(printf '%s' "$LIC" | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

echo
if [ "$MODE_NOW" = "valid" ]; then
  ok "license is VALID — installation complete"
  echo "    open:  http://<this-server>:$PORT   (rAthena account with group_id >= 60)"
else
  warn "license not active yet (mode: ${MODE_NOW:-unknown})"
  echo
  echo "  NEXT STEPS"
  echo "  1. Send this fingerprint to $VENDOR_CONTACT:"
  echo "         ${FP:-'(no fingerprint — is the game DB reachable? check settings.json)'}"
  echo "  2. Replace $GMTOOL_DIR/license.json with the file you receive."
  echo "  3. Run:   cd $GMTOOL_DIR && $DOCKER compose restart gmtool"
  echo "     (or simply re-run this installer — it is safe to repeat)"
fi

# --- asset checklist ---------------------------------------------------------------
if [ ! -s public/system/itemInfo.lub ] || ! ls public/grf/*.grf >/dev/null 2>&1; then
  echo
  warn "client assets are not staged yet — copy them into $GMTOOL_DIR/public/:"
  echo "      public/system/itemInfo.lub     (from your client, the real >100KB file)"
  echo "      public/grf/*.grf               (client GRFs; list them in settings.json grfPaths)"
  grep -q '"dbPath": *"public/db"' settings.json 2>/dev/null && \
  echo "      public/db/ + public/npc/       (rAthena db yml + npc scripts — or re-run and point at your rAthena dir)"
  echo "    then: cd $GMTOOL_DIR && $DOCKER compose restart gmtool"
fi
echo
ok "done"
