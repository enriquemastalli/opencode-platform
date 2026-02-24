#!/usr/bin/env bash
set -euo pipefail

# ── OpenCode Platform — Script de instalación para VPS Ubuntu 24.04 ──────────
# Uso one-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/enriquemastalli/opencode-platform/main/scripts/install.sh)
# Requiere: Ubuntu 24.04, acceso root/sudo, CLOUDFLARE_TUNNEL_TOKEN configurado

REPO_URL="https://github.com/enriquemastalli/opencode-platform.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/opencode-platform"
WORKSPACES_DIR="/workspaces"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   OpenCode Platform — Instalación    ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. Verificar root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Ejecutar como root: sudo bash <(curl -fsSL https://raw.githubusercontent.com/enriquemastalli/opencode-platform/main/scripts/install.sh)"
fi

# ── 2. Actualizar sistema ─────────────────────────────────────────────────────
info "Actualizando sistema..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl git ca-certificates gnupg lsb-release ufw

# ── 3. Instalar Docker ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Instalando Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  log "Docker instalado"
else
  log "Docker ya instalado ($(docker --version))"
fi

# ── 4. Crear usuario opencode (no root) ───────────────────────────────────────
if ! id "opencode" &>/dev/null; then
  info "Creando usuario 'opencode'..."
  useradd -m -s /bin/bash opencode
  usermod -aG docker opencode
  log "Usuario 'opencode' creado y añadido al grupo docker"
else
  log "Usuario 'opencode' ya existe"
  usermod -aG docker opencode
fi

# ── 5. Crear directorios ──────────────────────────────────────────────────────
info "Creando directorios..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$WORKSPACES_DIR"
chown -R opencode:opencode "$INSTALL_DIR"
chown -R opencode:opencode "$WORKSPACES_DIR"
log "Directorios: $INSTALL_DIR y $WORKSPACES_DIR"

# ── 6. Clonar repositorio ─────────────────────────────────────────────────────
info "Clonando repositorio..."
CLONE_DIR="$(mktemp -d)"
git clone --depth=1 "$REPO_URL" "$CLONE_DIR"
cp -r "$CLONE_DIR"/{docker-compose.yml,traefik,panel,opencode} "$INSTALL_DIR/"
rm -rf "$CLONE_DIR"
chown -R opencode:opencode "$INSTALL_DIR"
log "Archivos instalados en $INSTALL_DIR"

# ── 7. Configurar .env ────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  info "Configurando variables de entorno..."

  if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    echo ""
    warn "Necesitás el token del Cloudflare Tunnel."
    echo "  1. Ve a Cloudflare Zero Trust → Networks → Tunnels"
    echo "  2. Crea un tunnel nuevo, elige 'cloudflared'"
    echo "  3. Copia el token que aparece en el comando de instalación"
    echo ""
    read -rp "Pegá el token aquí: " CLOUDFLARE_TUNNEL_TOKEN
  fi

  cat > "$ENV_FILE" <<EOF
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
WORKSPACES_DIR=${WORKSPACES_DIR}
OPENCODE_BASE_PORT=4100
MAX_PROJECTS=20
EOF
  chmod 600 "$ENV_FILE"
  chown opencode:opencode "$ENV_FILE"
  log ".env configurado"
else
  log ".env ya existe, no se sobreescribe"
fi

# ── 8. Construir imágenes Docker ──────────────────────────────────────────────
info "Construyendo imágenes Docker (puede tardar unos minutos)..."
cd "$INSTALL_DIR"
docker compose build --no-cache
log "Imágenes construidas"

# ── 9. Configurar firewall ────────────────────────────────────────────────────
info "Configurando firewall (UFW)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp   # Traefik (solo accesible via tunnel, pero necesario internamente)
ufw --force enable
log "Firewall configurado (solo SSH + 80 internamente)"

# ── 10. Arrancar la plataforma ────────────────────────────────────────────────
info "Arrancando la plataforma..."
cd "$INSTALL_DIR"
docker compose up -d
log "Plataforma arrancada"

# ── 11. Configurar systemd para auto-arranque ─────────────────────────────────
info "Configurando auto-arranque con systemd..."
cat > /etc/systemd/system/opencode-platform.service <<EOF
[Unit]
Description=OpenCode Platform
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable opencode-platform
log "Auto-arranque configurado"

# ── 12. Verificar estado ──────────────────────────────────────────────────────
echo ""
info "Verificando estado de los servicios..."
sleep 5
docker compose -f "$INSTALL_DIR/docker-compose.yml" ps

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   ¡Instalación completa!                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Próximos pasos:                                             ║"
echo "║                                                              ║"
echo "║  1. Ve a Cloudflare Zero Trust → Networks → Tunnels          ║"
echo "║     Configura la ruta pública del tunnel apuntando a:        ║"
echo "║     http://traefik:80                                        ║"
echo "║                                                              ║"
echo "║  2. Activa Cloudflare Access para proteger el acceso:        ║"
echo "║     Zero Trust → Access → Applications                       ║"
echo "║     Crea una app y permite solo tu dominio de Google         ║"
echo "║                                                              ║"
echo "║  3. Compartí la URL del tunnel con tu equipo                 ║"
echo "║                                                              ║"
echo "║  Gestión:                                                    ║"
echo "║    Ver logs:    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
echo "║    Reiniciar:   systemctl restart opencode-platform          ║"
echo "║    Detener:     systemctl stop opencode-platform             ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
