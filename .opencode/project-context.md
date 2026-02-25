# PROJECT CONTEXT — OpenCode Desktop Orchestrated Team Workspace (VPS + Cloudflare + GitHub + Zero Trust by Company Domain)

## 0) North Star
Implementar un **entorno web colaborativo** basado en OpenCode, instalado en un **VPS**, administrado desde una **consola web** (wizard) que, en el primer arranque, detecta que “no hay nada configurado” y **orquesta la configuración completa del ecosistema**:

- Cloudflare (DNS + Tunnel)
- Cloudflare Zero Trust (Access) **permitiendo acceso por dominio corporativo**, no por lista fija de emails
- GitHub (repositorio, acceso, y flujo de trabajo)
- Proveedores y modelos (OpenAI / Anthropic / Groq / Gemini / etc.)
- Estructura de workspaces aislados por tarea mediante **git worktrees**
- Sin Docker / sin devcontainers (arquitectura simple)

**Regla de oro:** “Instalo todo en el VPS; la configuración fina ocurre desde la administración web”.

---

## 1) Componentes del sistema

### 1.1 VPS Layer (infra mínima)
- Ubuntu LTS
- Node LTS + npm
- OpenCode instalado por npm
- cloudflared instalado (paquete oficial)
- UFW activo (solo SSH; nada de 80/443/8080 públicos)
- systemd services:
  - `opencode.service`
  - `cloudflared.service`
  - `controlplane.service` (nuevo: consola + wizard + proxy)

### 1.2 Control Plane (nuevo, obligatorio)
Una aplicación web liviana (Node) que:
- Expone la **administración web** y el **wizard**
- Persiste estado de configuración (SQLite mínimo)
- Integra API de Cloudflare (DNS / Tunnel / Access Apps / Policies / IdP reference)
- Integra API de GitHub (tokens, repo validation, cloning strategy, opcional webhooks)
- Gestiona la configuración de providers/modelos (validación + guardado seguro)
- Hace **reverse-proxy** hacia OpenCode Web una vez que el sistema está “READY”
- En modo “UNCONFIGURED” intercepta y manda al wizard (`/setup`)

> OpenCode no “trae” este wizard. Se implementa como capa encima.

---

## 2) Experiencia objetivo (User Journey)

### 2.1 Primera vez (ideal)
1) Admin abre el panel (URL temporal o por túnel básico de bootstrap)
2) El sistema detecta `STATUS=UNCONFIGURED`
3) Redirige a `/setup`
4) Wizard pregunta lo mínimo, valida, configura por API y aplica cambios
5) Al finalizar:
   - se crea `opencode.<dominio_empresa>`
   - se configura Zero Trust para autenticar con IdP corporativo
   - se activa policy: **email ends with @empresa.com** (y opcionalmente lista de dominios)
   - se configura GitHub repo base
   - se configuran providers/modelos
   - se marca `STATUS=READY`
6) Admin reingresa por `opencode.<dominio_empresa>` ya con Zero Trust activo.

### 2.2 Operación diaria
- Usuarios entran por `opencode.<dominio_empresa>`
- Cloudflare Access autentica con el IdP corporativo
- El Control Plane deja pasar y proxya a OpenCode
- Trabajo aislado por **worktrees** por tarea/usuario
- Merge por PR en GitHub
- Limpieza de worktrees

---

## 3) Requisito clave: Zero Trust por dominio corporativo

### 3.1 No se permite “lista fija de 6”
El acceso debe basarse en dominio(s) corporativo(s), por ejemplo:
- `@empresa.com`
- opcional: múltiples dominios (holding): `@empresa.com` OR `@empresa.net`

### 3.2 Login “por el dominio de la empresa”
Se interpreta como:
- Autenticación mediante **IdP corporativo** (Google Workspace / Entra ID / Okta / etc.)
- Política Access que permita usuarios cuyo email **termina en** uno de los dominios configurados

**Obligatorio en wizard:**
- Seleccionar tipo de IdP (mínimo: Google Workspace o Entra ID)
- Registrar/usar ese IdP en Cloudflare Zero Trust (si no existe, asistir)
- Crear Access Application para `opencode.<dominio>`
- Crear policy Include por `email ends with`

---

## 4) Requisito clave: Instalación 100% automática en VPS

### 4.1 Script obligatorio
El agente debe generar y mantener:
- `install_vps.sh` (one-shot)
- Idempotente (correr 2 veces no rompe)
- Logs en: `/var/log/opencode-install.log`
- No hardcodear secretos (solo env vars / archivo `.env` fuera del repo)
- Instala:
  - Node LTS + npm
  - OpenCode via npm
  - cloudflared
  - Control Plane
  - systemd services
  - UFW (solo SSH)

### 4.2 Bootstrap “sin configurar”
El script deja el sistema funcionando en modo:
- `UNCONFIGURED`
- con un acceso temporal de bootstrap (ver sección 5)

---

## 5) Bootstrap de acceso antes de Zero Trust (problema real y solución)
Para poder correr el wizard, al principio **todavía no existe** `opencode.<dominio>` ni Access.

### 5.1 Solución recomendada (simple y segura)
- El script crea un **túnel bootstrap** a un hostname temporal (ej: `opencode-setup.<dominio-controlado>` o un subdominio controlado por nosotros)
- O alternativa: acceso solo por SSH + `cloudflared tunnel --url` temporal
- El wizard luego migra a `opencode.<dominio_empresa>`

**Regla:** el bootstrap debe expirar o deshabilitarse al pasar a `READY`.

---

## 6) Configuración por API (no manual)

### 6.1 Cloudflare
El Control Plane debe usar Cloudflare API para:
- Verificar que el dominio está en la cuenta Cloudflare indicada
- Crear Tunnel (si no existe)
- Crear/actualizar DNS record `opencode.<dominio_empresa>` hacia Tunnel
- Configurar cloudflared (credenciales + config.yml) y reiniciar servicio

**Nunca depender de “abrí browser en el VPS y logueate”** como requisito final.
Eso se acepta solo como bootstrap, no como diseño objetivo.

### 6.2 Zero Trust (Access)
Por API:
- Crear Access Application para `opencode.<dominio_empresa>`
- Crear policy “Allow” por dominio(s) de email
- Seleccionar IdP corporativo (o guiar su creación si aplica)

### 6.3 GitHub
Por API:
- Validar token y permisos
- Validar repositorio
- Configurar método de clonación (SSH recomendado; token HTTPS aceptable)
- (Opcional) configurar webhook / checks si se quiere automatizar algo

### 6.4 Model Providers
- Guardar API keys cifradas o protegidas (mínimo: permisos 600 + no repo)
- Validar conectividad (test prompt)
- Guardar modelo default y fallback

---

## 7) Persistencia / Estado (State Machine)

### 7.1 Estados
- `UNCONFIGURED`
- `CONFIGURING`
- `READY`
- `ERROR`

### 7.2 Fuente de verdad
- SQLite (mínimo) en `/srv/opencode/controlplane.db`
- Config final “exportable” a `/etc/opencode/setup.json` (read-only para servicios)

### 7.3 Reglas
- Si `UNCONFIGURED` => toda request al root redirige a `/setup`
- Si `READY` => root proxya a OpenCode Web
- Si `ERROR` => mostrar diagnóstico + opción retry por paso

---

## 8) Aislamiento de trabajo: git worktrees (sin Docker)

### 8.1 Regla
- `main` no se toca
- una tarea = un worktree
- un usuario no comparte worktree
- merge por PR

### 8.2 Estructura en disco
- Repo base: `/srv/repos/<project>`
- Workspaces: `/srv/workspaces/<ticket>-<user>/`

### 8.3 Scripts obligatorios
El Control Plane debe generar o incluir:
- `create_workspace.sh` (crea branch + worktree)
- `remove_workspace.sh` (limpia worktree)
- Opcional: endpoint web para crear/eliminar workspaces con roles/permisos

---

## 9) Seguridad

### 9.1 Obligatorio
- No exponer 80/443/8080 al público
- Acceso externo solo por Cloudflare Tunnel
- Zero Trust obligatorio para `READY`
- SSH solo por key
- Secrets fuera de repo
- Permisos estrictos en `/etc/opencode/*.env` y DB

### 9.2 Recomendado
- Rotación de tokens
- Backups diarios de:
  - `/etc/opencode`
  - `/srv/opencode/controlplane.db`
  - `/srv/repos`
- Logs con rotación

---

## 10) Archivos y rutas estándar (contract)

### 10.1 VPS
- `/srv/opencode/` (control plane + runtime)
- `/srv/repos/`
- `/srv/workspaces/`
- `/etc/opencode/opencode.env` (variables runtime, 600)
- `/etc/opencode/setup.json` (config final exportada, 600)
- `/etc/cloudflared/config.yml`
- `/var/log/opencode-install.log`

### 10.2 Servicios systemd
- `/etc/systemd/system/opencode.service`
- `/etc/systemd/system/controlplane.service`
- `cloudflared.service` (oficial)

---

## 11) Wizard — pasos (definición exacta)

### Paso 1: Dominio de empresa
Inputs:
- `company_domain_dns` (ej: `empresa.com`)
- Subdominio a usar (default fijo): `opencode`
Resultado:
- Hostname objetivo: `opencode.empresa.com`
Validaciones:
- El dominio está en Cloudflare account (o dar instrucciones claras)

### Paso 2: Cloudflare API
Inputs:
- Cloudflare API token (scopes mínimos)
- Account ID
- Zone ID (si aplica; o deducir por API)
Acciones:
- Crear/asegurar tunnel
- Crear/asegurar DNS record
- Instalar credenciales y config
- Reiniciar cloudflared
Validación:
- `opencode.empresa.com` responde con challenge/proxy (según etapa)

### Paso 3: Zero Trust (Identity + Policy por dominio)
Inputs:
- Tipo de IdP: (Google Workspace / Entra / Okta / custom OIDC)
- Dominios permitidos (lista): `empresa.com` (+ opcionales)
Acciones:
- Crear Access Application para hostname
- Crear policy Allow: `email ends with @empresa.com` OR otros
Validación:
- request sin auth => redirect/login
- request con auth del dominio => permite

### Paso 4: GitHub
Inputs:
- Token (fine-grained o classic)
- Owner/Org
- Repo
- Método de clonación (SSH recomendado)
Acciones:
- Validar token + acceso repo
- Clonar repo a `/srv/repos/<project>`
Validación:
- `git fetch` OK

### Paso 5: Model Providers
Inputs:
- Provider seleccionado
- API key
- Modelo default
- Fallback (opcional)
Acciones:
- Test de completions
- Guardar config
Validación:
- prueba pasa y persiste

### Paso 6: Finalizar
Acciones:
- Export a `/etc/opencode/setup.json`
- Set status READY
- Deshabilitar bootstrap si existe
- Reiniciar servicios
Resultado:
- acceso final por `opencode.empresa.com` con Zero Trust

---

## 12) No-negociables del agente (comportamiento)

- No inventar valores sensibles
- No hardcodear secretos en scripts o repo
- Cada paso crítico debe:
  1) verificar prerequisitos
  2) ejecutar acción
  3) validar
  4) persistir estado
- Preferir simplicidad operativa sobre “arquitecturas bonitas”
- Mantener un “happy path” para 6 usuarios, escalable luego

---

## 13) Output esperado del agente (deliverables mínimos)
1) `PROJECT_CONTEXT.md` (este documento)
2) `install_vps.sh` (npm + infra + control plane)
3) `controlplane/` (app Node) con:
   - `/setup` wizard
   - API clients Cloudflare + GitHub
   - estado + persistencia
   - reverse proxy hacia OpenCode
4) `create_workspace.sh` + `remove_workspace.sh`
5) systemd unit files generados por script

---

## 14) Definición de “done”
- VPS instalado con un comando (script)
- Admin abre panel, ve wizard
- Configura dominio empresa (DNS)
- Zero Trust autentica con IdP corporativo
- Acceso permitido por dominio de email (no lista fija)
- OpenCode accesible solo por `opencode.<dominio_empresa>`
- Repos/worktrees funcionan
- Providers/modelos funcionales
- Bootstrap deshabilitado al final
