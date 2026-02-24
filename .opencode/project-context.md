# OpenCode Platform — Project Context

## Qué es esto

Plataforma de gestión centralizada que permite al equipo interno de Essentia lanzar y conectarse a instancias de `opencode` corriendo en un VPS compartido. Cada miembro del equipo puede crear un proyecto (clonar un repo de GitHub/GitLab), y obtener una URL pública para usar opencode desde el browser o hacer `opencode attach` desde su máquina local con el TUI completo.

## Problema que resuelve

Sin esta plataforma, cada colaborador necesita:
- Instalar opencode localmente
- Gestionar sus propias API keys
- Tener el repo clonado en su máquina

Con esta plataforma:
- El código y los agentes corren en el servidor
- Cada usuario accede via browser o TUI remoto
- Las API keys se guardan por proyecto en el servidor
- El acceso está protegido por Cloudflare Access (Google Workspace)

## Arquitectura

```
Internet → Cloudflare Tunnel → Traefik (proxy) → Panel de gestión
                                               → opencode-proyecto-a (opencode web)
                                               → opencode-proyecto-b (opencode web)
                                               → opencode-proyecto-N ...
```

- **Cloudflare Tunnel**: expone el VPS sin abrir puertos al mundo. Cloudflare Access restringe el acceso a emails del equipo (@dominio.com via Google OAuth).
- **Traefik**: reverse proxy interno que enruta `/p/<nombre>/` a cada contenedor de opencode.
- **Panel de gestión**: app Node.js + HTML que permite crear/listar/start/stop/eliminar proyectos. Cada proyecto = un contenedor Docker con `opencode web`.
- **Workspaces**: los repos se clonan en `/workspaces/<nombre>/` del VPS y se montan como volumen en el contenedor.

## Stack técnico

| Capa | Tecnología |
|------|-----------|
| VPS | Ubuntu 24.04 en DigitalOcean |
| Contenerización | Docker + Docker Compose |
| Proxy interno | Traefik v3 |
| Zero Trust / Auth | Cloudflare Tunnel + Cloudflare Access |
| Panel backend | Node.js 22 + Express + Dockerode |
| Panel frontend | HTML + JS puro (sin framework) |
| Imagen opencode | node:22-slim + opencode-ai npm global |

## Estructura del proyecto

```
opencode-platform/
├── docker-compose.yml          # Traefik + Panel + Cloudflared
├── traefik/traefik.yml         # Config estática de Traefik (sin TLS, lo maneja CF)
├── opencode/Dockerfile         # Imagen base: node:22-slim + opencode-ai
├── panel/
│   ├── Dockerfile              # node:22-slim
│   ├── package.json            # express, dockerode, simple-git, dotenv
│   ├── server.js               # API REST completa de gestión de proyectos
│   └── public/index.html       # UI del panel (dark mode, estilo opencode)
├── scripts/install.sh          # Setup completo del VPS en un comando
├── .env.example                # Variables requeridas
└── .gitignore
```

## API del panel

| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/api/projects` | Lista proyectos con estado |
| POST | `/api/projects` | Crea proyecto (clona repo + levanta contenedor) |
| POST | `/api/projects/:name/start` | Inicia proyecto detenido |
| POST | `/api/projects/:name/stop` | Detiene proyecto |
| DELETE | `/api/projects/:name` | Elimina proyecto (workspace + contenedor) |
| GET | `/api/projects/:name/logs` | Últimas líneas de logs del contenedor |
| GET | `/api/health` | Health check |

## Flujo de un proyecto nuevo

1. Usuario entra al panel (URL pública del tunnel, autenticado con Google)
2. Click "Nuevo proyecto" → ingresa nombre, URL del repo, API keys
3. El panel: clona el repo en `/workspaces/<nombre>/`, crea `.env` con las keys, levanta contenedor `opencode web` con Traefik labels
4. Traefik detecta el contenedor nuevo y enruta `/p/<nombre>/` automáticamente
5. Usuario recibe URL pública y comando `opencode attach`

## Cómo conectarse a un proyecto

**Desde el browser:**
```
https://<tunnel>.cfargotunnel.com/p/<nombre>/
```

**Desde el TUI local:**
```bash
opencode attach https://<tunnel>.cfargotunnel.com/p/<nombre>/
```

## Variables de entorno (.env en el VPS)

```
CLOUDFLARE_TUNNEL_TOKEN=eyJ...   # Token del tunnel de Cloudflare
WORKSPACES_DIR=/workspaces        # Directorio de workspaces en el VPS
OPENCODE_BASE_PORT=4100           # Puerto inicial para contenedores
MAX_PROJECTS=20                   # Máximo de proyectos simultáneos
```

## Comandos útiles en el VPS

```bash
# Ver estado de todos los servicios
docker compose -f /opt/opencode-platform/docker-compose.yml ps

# Ver logs del panel
docker compose -f /opt/opencode-platform/docker-compose.yml logs -f panel

# Ver logs de un proyecto específico
docker logs opencode-project-<nombre> -f

# Reiniciar toda la plataforma
systemctl restart opencode-platform

# Listar proyectos activos
docker ps --filter "name=opencode-project-"
```

## Decisiones de diseño

- **Sin TLS en Traefik**: Cloudflare Tunnel ya termina TLS externamente. Traefik solo hace routing HTTP interno.
- **Password por proyecto**: cada contenedor de opencode tiene su propia `OPENCODE_SERVER_PASSWORD` generada aleatoriamente. Se guarda en `.opencode-meta.json` del workspace.
- **API keys por proyecto**: cada proyecto tiene su `.env` con las keys del usuario. Nunca se commitean al repo.
- **node:22-slim**: usa Debian/glibc en vez de Alpine/musl porque el binario `workerd` de opencode requiere glibc.
- **Dockerode**: el panel crea/gestiona contenedores directamente via Docker socket, sin scripts shell. Más robusto y portable.
- **Sin base de datos**: el estado de los proyectos se persiste en el filesystem (`/workspaces/<nombre>/.opencode-meta.json`). Simple y sin dependencias adicionales.

## Pendiente / próximos pasos

- [ ] Configurar Cloudflare Tunnel en el dashboard (apuntar a `http://traefik:80`)
- [ ] Activar Cloudflare Access con Google Workspace auth
- [ ] Ejecutar `scripts/install.sh` en el VPS
- [ ] Verificar routing de `opencode web` detrás de PathPrefix strip (puede necesitar ajuste si la UI usa paths absolutos)
- [ ] Agregar autenticación al panel mismo (actualmente confía en Cloudflare Access como única capa)
- [ ] Soporte para repos privados (SSH keys o GitHub token)
- [ ] Notificaciones cuando un proyecto lleva más de X días sin actividad
