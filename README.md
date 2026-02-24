# OpenCode Platform

Plataforma para desplegar y gestionar instancias de [opencode-ai](https://opencode.ai) por proyecto en un VPS. Cada proyecto vive en su propio contenedor Docker, tiene su propio workspace Git y es accesible desde el browser o mediante el TUI remoto de opencode.

---

## Arquitectura

```
Internet (HTTPS)
       │
       ▼
Cloudflare Tunnel  ──── TLS terminado en el edge de Cloudflare
       │
       ▼ HTTP interno
  Traefik v3.2  (puerto 80, routing por PathPrefix)
       │
       ├──  /              →  Panel de gestión  (opencode-panel:3000)
       │
       └──  /p/<nombre>/   →  Contenedor del proyecto  (opencode-ai:4096)
                               (creados y destruidos dinámicamente por el panel)

Red interna: opencode-net (bridge)
Volumen compartido: /workspaces  (bind mount en el VPS)
```

El panel tiene acceso al socket de Docker y gestiona el ciclo de vida de los contenedores de proyecto. Traefik descubre los contenedores automáticamente via labels y enruta el tráfico sin reinicios.

---

## Requisitos previos

- VPS con **Ubuntu 24.04** y acceso `root`
- Cuenta de **Cloudflare** (el plan gratuito es suficiente)
- Un **Cloudflare Tunnel** creado en Zero Trust → Networks → Tunnels
- Token del tunnel (se obtiene al crear el tunnel en el paso de instalación)

---

## Instalación

```bash
# 1. Clonar el repositorio en el VPS
git clone <url-del-repo> /opt/opencode-platform
cd /opt/opencode-platform

# 2. Ejecutar el instalador como root
sudo bash scripts/install.sh
```

El script hace automáticamente:
1. Actualiza el sistema e instala dependencias (`git`, `curl`, `ufw`, etc.)
2. Instala Docker y Docker Compose
3. Crea el usuario `opencode` (sin root) con acceso a Docker
4. Crea los directorios `/opt/opencode-platform` y `/workspaces`
5. Solicita el token de Cloudflare Tunnel y genera el `.env`
6. Construye las imágenes Docker
7. Configura el firewall UFW (solo SSH + puerto 80 internamente)
8. Levanta la plataforma con `docker compose up -d`
9. Registra un servicio systemd para auto-arranque

---

## Configuración post-instalación

### 1. Configurar la ruta del Cloudflare Tunnel

En **Cloudflare Zero Trust → Networks → Tunnels → \<tu tunnel\> → Public Hostnames**:

| Campo | Valor |
|-------|-------|
| Subdomain | `opencode` (o el que prefieras) |
| Domain | tu dominio en Cloudflare |
| Service | `http://traefik:80` |

### 2. Proteger el acceso con Cloudflare Access (recomendado)

En **Zero Trust → Access → Applications → Add an application**:

- Tipo: `Self-hosted`
- URL: la misma del tunnel
- Policy: permitir solo correos de tu organización (Google, GitHub, etc.)

Esto evita que cualquier persona pueda acceder al panel o a los proyectos.

---

## Uso del panel

Accedé al panel en la URL pública de tu tunnel. Desde ahí podés:

### Crear un proyecto

1. Clic en **Nuevo proyecto**
2. Completar:
   - **Nombre**: identificador único (solo minúsculas, números y guiones)
   - **URL del repositorio**: URL Git del proyecto a clonar
   - **API Keys** (opcional): variables de entorno que se guardan en `.env` dentro del workspace (por ejemplo `ANTHROPIC_API_KEY`)
3. Clic en **Crear proyecto** — el panel clona el repo y lanza el contenedor automáticamente

### Gestionar proyectos

Desde cada tarjeta de proyecto podés:

- **Iniciar / Detener** el contenedor
- **Ver logs** en tiempo real (últimas 100 líneas)
- **Copiar la URL** para abrir en el browser
- **Copiar el comando** `opencode attach` para conectar el TUI local
- **Eliminar** el proyecto (borra el workspace del VPS; el repo remoto no se toca)

### Conectar el TUI de opencode (desde tu máquina local)

Con el proyecto corriendo, copiá el comando desde la vista **Conectar TUI** o desde la tarjeta del proyecto:

```bash
opencode attach https://<tu-tunnel>/p/<nombre-del-proyecto>/
```

Esto abre el TUI completo de opencode conectado al workspace remoto.

---

## API REST

El panel expone una API REST en `/api/`:

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/projects` | Lista todos los proyectos con su estado |
| `POST` | `/api/projects` | Crea un proyecto (clona repo + lanza contenedor) |
| `POST` | `/api/projects/:name/start` | Inicia un proyecto detenido |
| `POST` | `/api/projects/:name/stop` | Detiene un proyecto en ejecución |
| `DELETE` | `/api/projects/:name` | Elimina contenedor y workspace |
| `GET` | `/api/projects/:name/logs` | Logs del contenedor (`?lines=50`) |
| `GET` | `/api/health` | Health check del panel |

Ejemplo para crear un proyecto via `curl`:

```bash
curl -X POST https://<tu-tunnel>/api/projects \
  -H "Content-Type: application/json" \
  -d '{
    "name": "mi-proyecto",
    "repo": "https://github.com/org/repo.git",
    "createdBy": "Juan García",
    "apiKeys": {
      "ANTHROPIC_API_KEY": "sk-ant-..."
    }
  }'
```

---

## Variables de entorno

Definidas en `.env` (copiá `.env.example` como base):

| Variable | Default | Descripción |
|----------|---------|-------------|
| `CLOUDFLARE_TUNNEL_TOKEN` | — | Token del tunnel de Cloudflare Zero Trust |
| `PANEL_PORT` | `3000` | Puerto interno del panel (no se expone directamente) |
| `WORKSPACES_DIR` | `/workspaces` | Directorio donde se clonan los repos en el VPS |
| `OPENCODE_BASE_PORT` | `4100` | Puerto inicial para los contenedores de proyecto |
| `MAX_PROJECTS` | `20` | Máximo de proyectos simultáneos |

---

## Gestión en producción

```bash
# Ver estado de los servicios
docker compose ps

# Ver logs en tiempo real
docker compose logs -f

# Reiniciar la plataforma
systemctl restart opencode-platform

# Detener la plataforma
systemctl stop opencode-platform

# Actualizar (rebuild de imágenes)
git pull
docker compose build --no-cache
docker compose up -d
```

---

## Estructura del repositorio

```
opencode-platform/
├── docker-compose.yml      # Orquestación principal
├── .env.example            # Template de variables de entorno
├── opencode/
│   └── Dockerfile          # Imagen del agente opencode-ai
├── panel/
│   ├── Dockerfile          # Imagen del panel de gestión
│   ├── server.js           # API REST (Express + Dockerode)
│   ├── package.json
│   └── public/
│       └── index.html      # Frontend SPA (Vanilla JS)
├── scripts/
│   └── install.sh          # Instalador para VPS Ubuntu 24.04
└── traefik/
    └── traefik.yml         # Configuración del reverse proxy
```
