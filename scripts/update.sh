#!/usr/bin/env bash
set -euo pipefail

# ── OpenCode Platform — Script de actualización ───────────────────────────────
# Uso: bash /opt/opencode-platform/scripts/update.sh
# O directamente desde el VPS: cd /opt/opencode-platform && git pull && bash scripts/update.sh

INSTALL_DIR="/opt/opencode-platform"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  echo "Ejecutar como root: sudo bash scripts/update.sh"
  exit 1
fi

info "Actualizando código..."
git -C "$INSTALL_DIR" pull
log "Código actualizado"

info "Reconstruyendo imágenes y reiniciando servicios..."
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --build
log "Plataforma actualizada y corriendo"

echo ""
docker compose -f "$INSTALL_DIR/docker-compose.yml" ps
