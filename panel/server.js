'use strict'

const express = require('express')
const Docker = require('dockerode')
const simpleGit = require('simple-git')
const path = require('path')
const fs = require('fs')
const { execSync } = require('child_process')

require('dotenv').config({ path: path.join(__dirname, '..', '.env') })

const app = express()
const docker = new Docker({ socketPath: '/var/run/docker.sock' })

const PORT = process.env.PANEL_PORT || 3000
const WORKSPACES_DIR = process.env.WORKSPACES_DIR || '/workspaces'
const OPENCODE_IMAGE = process.env.OPENCODE_IMAGE || 'opencode-platform-opencode'
const BASE_PORT = parseInt(process.env.OPENCODE_BASE_PORT || '4100', 10)
const MAX_PROJECTS = parseInt(process.env.MAX_PROJECTS || '20', 10)

app.use(express.json())
app.use(express.static(path.join(__dirname, 'public')))

// ── Helpers ──────────────────────────────────────────────────────────────────

function containerName(projectName) {
  return `opencode-project-${projectName}`
}

function sanitizeName(name) {
  return name.toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^-+|-+$/g, '')
}

function getProjectsFromDisk() {
  if (!fs.existsSync(WORKSPACES_DIR)) return []
  return fs.readdirSync(WORKSPACES_DIR).filter(f => {
    return fs.statSync(path.join(WORKSPACES_DIR, f)).isDirectory()
  })
}

async function getContainerStatus(name) {
  try {
    const container = docker.getContainer(containerName(name))
    const info = await container.inspect()
    return {
      running: info.State.Running,
      port: extractPort(info),
      id: info.Id.slice(0, 12)
    }
  } catch {
    return { running: false, port: null, id: null }
  }
}

function extractPort(containerInfo) {
  try {
    const bindings = containerInfo.HostConfig.PortBindings['4096/tcp']
    return bindings ? parseInt(bindings[0].HostPort, 10) : null
  } catch {
    return null
  }
}

async function nextAvailablePort() {
  const containers = await docker.listContainers({ all: true })
  const usedPorts = new Set()
  for (const c of containers) {
    for (const p of c.Ports) {
      if (p.PublicPort) usedPorts.add(p.PublicPort)
    }
  }
  for (let p = BASE_PORT; p < BASE_PORT + MAX_PROJECTS; p++) {
    if (!usedPorts.has(p)) return p
  }
  throw new Error('No hay puertos disponibles')
}

function readProjectMeta(projectName) {
  const metaPath = path.join(WORKSPACES_DIR, projectName, '.opencode-meta.json')
  if (!fs.existsSync(metaPath)) return {}
  try {
    return JSON.parse(fs.readFileSync(metaPath, 'utf8'))
  } catch {
    return {}
  }
}

function writeProjectMeta(projectName, meta) {
  const metaPath = path.join(WORKSPACES_DIR, projectName, '.opencode-meta.json')
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2))
}

// ── Rutas API ─────────────────────────────────────────────────────────────────

// GET /api/projects — lista todos los proyectos con su estado
app.get('/api/projects', async (req, res) => {
  try {
    const names = getProjectsFromDisk()
    const projects = await Promise.all(names.map(async name => {
      const status = await getContainerStatus(name)
      const meta = readProjectMeta(name)
      return {
        name,
        repo: meta.repo || null,
        createdAt: meta.createdAt || null,
        createdBy: meta.createdBy || null,
        running: status.running,
        port: status.port,
        containerId: status.id
      }
    }))
    res.json(projects)
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

// POST /api/projects — crea un nuevo proyecto
app.post('/api/projects', async (req, res) => {
  const { name, repo, apiKeys, createdBy } = req.body

  if (!name || !repo) {
    return res.status(400).json({ error: 'name y repo son obligatorios' })
  }

  const safeName = sanitizeName(name)
  if (!safeName) {
    return res.status(400).json({ error: 'Nombre de proyecto inválido' })
  }

  const workspaceDir = path.join(WORKSPACES_DIR, safeName)

  if (fs.existsSync(workspaceDir)) {
    return res.status(409).json({ error: `El proyecto "${safeName}" ya existe` })
  }

  try {
    // 1. Clonar el repo
    fs.mkdirSync(workspaceDir, { recursive: true })
    const git = simpleGit()
    await git.clone(repo, workspaceDir)

    // 2. Escribir .env con las API keys del usuario
    if (apiKeys && Object.keys(apiKeys).length > 0) {
      const envContent = Object.entries(apiKeys)
        .map(([k, v]) => `${k}=${v}`)
        .join('\n')
      fs.writeFileSync(path.join(workspaceDir, '.env'), envContent)
    }

    // 3. Guardar metadata del proyecto
    writeProjectMeta(safeName, {
      repo,
      createdAt: new Date().toISOString(),
      createdBy: createdBy || 'unknown'
    })

    // 4. Obtener puerto disponible y arrancar contenedor
    const port = await nextAvailablePort()
    const password = generatePassword()

    const routerName = `project-${safeName}`
    const container = await docker.createContainer({
      name: containerName(safeName),
      Image: OPENCODE_IMAGE,
      Env: [
        `OPENCODE_SERVER_PASSWORD=${password}`,
        `OPENCODE_SERVER_USERNAME=opencode`
      ],
      HostConfig: {
        Binds: [`${workspaceDir}:/workspace`],
        PortBindings: { '4096/tcp': [{ HostPort: String(port) }] },
        RestartPolicy: { Name: 'unless-stopped' },
        NetworkMode: 'opencode-net'
      },
      ExposedPorts: { '4096/tcp': {} },
      Labels: {
        'traefik.enable': 'true',
        [`traefik.http.routers.${routerName}.rule`]: `PathPrefix(\`/p/${safeName}/\`)`,
        [`traefik.http.routers.${routerName}.entrypoints`]: 'web',
        [`traefik.http.routers.${routerName}.priority`]: '10',
        [`traefik.http.middlewares.${routerName}-strip.stripprefix.prefixes`]: `/p/${safeName}`,
        [`traefik.http.routers.${routerName}.middlewares`]: `${routerName}-strip`,
        [`traefik.http.services.${routerName}.loadbalancer.server.port`]: '4096'
      }
    })

    await container.start()

    // Guardar password y puerto en metadata
    writeProjectMeta(safeName, {
      repo,
      createdAt: new Date().toISOString(),
      createdBy: createdBy || 'unknown',
      port,
      password
    })

    res.status(201).json({
      name: safeName,
      repo,
      port,
      password,
      containerId: container.id.slice(0, 12)
    })
  } catch (err) {
    // Limpiar si algo falló
    try { fs.rmSync(workspaceDir, { recursive: true, force: true }) } catch {}
    res.status(500).json({ error: err.message })
  }
})

// POST /api/projects/:name/start — arranca un proyecto detenido
app.post('/api/projects/:name/start', async (req, res) => {
  const { name } = req.params
  try {
    const meta = readProjectMeta(name)
    if (!meta.port) {
      return res.status(400).json({ error: 'Proyecto sin puerto asignado, recréalo' })
    }

    // Si el contenedor existe, arrancarlo; si no, recrearlo
    try {
      const container = docker.getContainer(containerName(name))
      await container.start()
    } catch {
      const workspaceDir = path.join(WORKSPACES_DIR, name)
      const routerName = `project-${name}`
      const container = await docker.createContainer({
        name: containerName(name),
        Image: OPENCODE_IMAGE,
        Env: [
          `OPENCODE_SERVER_PASSWORD=${meta.password || ''}`,
          `OPENCODE_SERVER_USERNAME=opencode`
        ],
        HostConfig: {
          Binds: [`${workspaceDir}:/workspace`],
          PortBindings: { '4096/tcp': [{ HostPort: String(meta.port) }] },
          RestartPolicy: { Name: 'unless-stopped' },
          NetworkMode: 'opencode-net'
        },
        ExposedPorts: { '4096/tcp': {} },
        Labels: {
          'traefik.enable': 'true',
          [`traefik.http.routers.${routerName}.rule`]: `PathPrefix(\`/p/${name}/\`)`,
          [`traefik.http.routers.${routerName}.entrypoints`]: 'web',
          [`traefik.http.routers.${routerName}.priority`]: '10',
          [`traefik.http.middlewares.${routerName}-strip.stripprefix.prefixes`]: `/p/${name}`,
          [`traefik.http.routers.${routerName}.middlewares`]: `${routerName}-strip`,
          [`traefik.http.services.${routerName}.loadbalancer.server.port`]: '4096'
        }
      })
      await container.start()
    }

    res.json({ name, running: true })
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

// POST /api/projects/:name/stop — detiene un proyecto
app.post('/api/projects/:name/stop', async (req, res) => {
  const { name } = req.params
  try {
    const container = docker.getContainer(containerName(name))
    await container.stop()
    res.json({ name, running: false })
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

// DELETE /api/projects/:name — elimina proyecto (soft: detiene contenedor, borra workspace)
app.delete('/api/projects/:name', async (req, res) => {
  const { name } = req.params
  try {
    // Detener y eliminar contenedor
    try {
      const container = docker.getContainer(containerName(name))
      await container.stop().catch(() => {})
      await container.remove()
    } catch {}

    // Eliminar workspace del disco
    const workspaceDir = path.join(WORKSPACES_DIR, name)
    if (fs.existsSync(workspaceDir)) {
      fs.rmSync(workspaceDir, { recursive: true, force: true })
    }

    res.json({ name, deleted: true })
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

// GET /api/projects/:name/logs — últimas líneas de logs del contenedor
app.get('/api/projects/:name/logs', async (req, res) => {
  const { name } = req.params
  const lines = parseInt(req.query.lines || '50', 10)
  try {
    const container = docker.getContainer(containerName(name))
    const logs = await container.logs({ stdout: true, stderr: true, tail: lines })
    // dockerode devuelve Buffer con header multiplexado, limpiarlo
    const clean = logs.toString('utf8').replace(/[\x00-\x08\x0e-\x1f]/g, '')
    res.json({ logs: clean })
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

// GET /api/health
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', workspacesDir: WORKSPACES_DIR })
})

// ── Utils ─────────────────────────────────────────────────────────────────────

function generatePassword(length = 16) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
  let result = ''
  for (let i = 0; i < length; i++) {
    result += chars[Math.floor(Math.random() * chars.length)]
  }
  return result
}

// ── Arrancar ──────────────────────────────────────────────────────────────────

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Panel de gestión corriendo en http://0.0.0.0:${PORT}`)
  console.log(`Workspaces: ${WORKSPACES_DIR}`)
})
