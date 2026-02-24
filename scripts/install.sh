#!/usr/bin/env bash
set -euo pipefail

# ── OpenCode Platform — Script de instalación para VPS Ubuntu 24.04 ──────────
# Uso one-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/enriquemastalli/opencode-platform/main/scripts/install.sh)
# Requiere: Ubuntu 24.04, acceso root/sudo

REPO_URL="https://github.com/enriquemastalli/opencode-platform.git"
INSTALL_DIR="/opt/opencode-platform"
WORKSPACES_DIR="/workspaces"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

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

# ── 5. Clonar o actualizar el repositorio ────────────────────────────────────
info "Instalando archivos de la plataforma..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Repositorio ya existe, actualizando..."
  git -C "$INSTALL_DIR" pull
  log "Repositorio actualizado"
else
  # Preservar .env si ya existe
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env" /tmp/opencode-platform.env.bak
    warn ".env guardado en /tmp/opencode-platform.env.bak"
  fi
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
  # Restaurar .env
  if [[ -f /tmp/opencode-platform.env.bak ]]; then
    cp /tmp/opencode-platform.env.bak "$INSTALL_DIR/.env"
    log ".env restaurado"
  fi
  log "Repositorio clonado en $INSTALL_DIR"
fi
chown -R opencode:opencode "$INSTALL_DIR"

# ── 6. Crear directorio de workspaces ────────────────────────────────────────
info "Creando directorios..."
mkdir -p "$WORKSPACES_DIR"
chown -R opencode:opencode "$WORKSPACES_DIR"
log "Directorio de workspaces: $WORKSPACES_DIR"

# ── 7. Configurar .env ────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  info "Configurando variables de entorno..."

  if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    echo ""
    warn "Necesitás el token del Cloudflare Tunnel."
    echo "  1. Ve a Cloudflare Zero Trust → Networks → Tunnels"
    echo "  2. Crea un tunnel nuevo, elige 'Docker'"
    echo "  3. Copia el token que aparece en el comando (la parte después de --token)"
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
docker compose -f "$INSTALL_DIR/docker-compose.yml" build --no-cache
log "Imágenes construidas"

# ── 9. Configurar firewall ────────────────────────────────────────────────────
info "Configurando firewall (UFW)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw --force enable
log "Firewall configurado (solo SSH + 80 internamente)"

# ── 10. Arrancar la plataforma ────────────────────────────────────────────────
info "Arrancando la plataforma..."
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d
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
echo "║  Para actualizar la plataforma en el futuro:                 ║"
echo "║    cd /opt/opencode-platform && git pull                     ║"
echo "║    docker compose up -d --build                              ║"
echo "║                                                              ║"
echo "║  Gestión:                                                    ║"
echo "║    Ver logs:    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
echo "║    Reiniciar:   systemctl restart opencode-platform          ║"
echo "║    Detener:     systemctl stop opencode-platform             ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
