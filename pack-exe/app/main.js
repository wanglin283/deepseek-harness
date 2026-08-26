// dsh-desktop — windowed launcher for DeepSeek Harness.
//
// Starts the bundled dsh web server (node.exe + runtime/repo) and shows the
// UI in an embedded window, so no external browser is needed.
//
// Layout (packaged):
//   dsh.exe                      Electron binary (renamed)
//   resources/app/main.js        this file
//   resources/runtime/node.exe   portable Node.js runtime
//   resources/runtime/repo/      repository snapshot with built artifacts
//
// For development, run `electron .` from this directory and point
// DSH_GUI_RUNTIME at a runtime directory (e.g. pack-exe/out/dsh-app/resources/runtime).
// Set DSH_GUI_SMOKE=1 to auto-close after the page loads (used by build tests).

const { app, BrowserWindow, dialog, shell } = require('electron')
const { spawn } = require('child_process')
const path = require('path')
const fs = require('fs')
const net = require('net')

const HOST = '127.0.0.1'
const PORT = 3080
const SERVER_READY_TIMEOUT_MS = 60_000
const SMOKE_TEST = process.env.DSH_GUI_SMOKE === '1'

function locateRuntime() {
  if (app.isPackaged) return path.join(process.resourcesPath, 'runtime')
  const devRuntime = process.env.DSH_GUI_RUNTIME
  if (devRuntime) return devRuntime
  throw new Error('development run requires DSH_GUI_RUNTIME pointing at a runtime directory')
}

function waitForServer(onReady, onTimeout) {
  const deadline = Date.now() + SERVER_READY_TIMEOUT_MS
  const probe = () => {
    const socket = net.connect({ port: PORT, host: HOST })
    socket.once('connect', () => {
      socket.destroy()
      onReady()
    })
    socket.once('error', () => {
      socket.destroy()
      if (Date.now() >= deadline) {
        onTimeout(new Error(`dsh web did not become ready on port ${PORT} within ${SERVER_READY_TIMEOUT_MS / 1000}s`))
      } else {
        setTimeout(probe, 500)
      }
    })
  }
  probe()
}

let serverProcess = null

function stopServer() {
  if (serverProcess === null || serverProcess.pid === undefined) return
  const pid = serverProcess.pid
  serverProcess = null
  try {
    // Windows: kill the whole process tree (dsh may spawn shells/terminals).
    spawn('taskkill', ['/pid', String(pid), '/T', '/F'], { stdio: 'ignore' })
  } catch {
    // best effort
  }
}

function startServer() {
  const runtimeDir = locateRuntime()
  const nodeExe = path.join(runtimeDir, 'node.exe')
  const repoDir = path.join(runtimeDir, 'repo')
  const entry = path.join(repoDir, 'apps', 'cli', 'lib', 'bin.js')
  for (const required of [nodeExe, entry]) {
    if (!fs.existsSync(required)) {
      throw new Error(`missing ${required} — is this a complete dsh-app bundle?`)
    }
  }
  serverProcess = spawn(nodeExe, [entry, 'web', '--no-open'], {
    cwd: repoDir,
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  serverProcess.stdout.on('data', (chunk) => console.log('[dsh]', chunk.toString().trim()))
  serverProcess.stderr.on('data', (chunk) => console.error('[dsh]', chunk.toString().trim()))
  serverProcess.on('exit', (code, signal) => {
    console.log(`[dsh] server exited (code=${code}, signal=${signal})`)
    serverProcess = null
  })
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 900,
    minHeight: 600,
    title: 'DeepSeek Harness',
    autoHideMenuBar: true,
    backgroundColor: '#0f1115',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })

  // Links outside the dsh origin open in the system browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith(`http://${HOST}:${PORT}`)) return { action: 'allow' }
    shell.openExternal(url)
    return { action: 'deny' }
  })

  win.webContents.on('did-finish-load', () => {
    console.log('[gui] window loaded')
    if (SMOKE_TEST) {
      setTimeout(() => app.quit(), 1500)
    }
  })
  win.webContents.on('did-fail-load', (_event, code, description) => {
    dialog.showErrorBox('dsh-desktop', `Failed to load the UI (${code}): ${description}`)
  })

  win.loadURL(`http://${HOST}:${PORT}`)
  win.on('closed', () => {
    stopServer()
  })
  return win
}

app.whenReady().then(() => {
  try {
    startServer()
  } catch (error) {
    dialog.showErrorBox('dsh-desktop', String(error))
    app.exit(1)
    return
  }
  waitForServer(
    () => {
      createWindow()
    },
    (error) => {
      dialog.showErrorBox('dsh-desktop', String(error))
      app.exit(1)
    },
  )
})

app.on('window-all-closed', () => {
  stopServer()
  app.quit()
})

app.on('will-quit', () => {
  stopServer()
})
