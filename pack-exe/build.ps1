<#
.SYNOPSIS
  Package the DeepSeek Harness repository into a windowed desktop app
  (dsh.exe + embedded Electron window + bundled runtime).

.DESCRIPTION
  Drop this pack-exe directory into the repository root and run build.ps1.
  The output out\dsh-app is a self-contained Windows desktop app:
  double-click dsh.exe to open the dsh Web UI in its own window - no
  browser needed, no Node.js install needed.

  When the upstream DSH repo is upgraded, copy pack-exe into the new checkout
  (or git pull in place) and rerun this script to produce a fresh bundle.

.PARAMETER NodeDir
  Directory containing a portable node.exe (Node 24+). Auto-detected when
  omitted.

.PARAMETER SkipBuild
  Skip `pnpm run build`. Use when artifacts are already fresh.

.PARAMETER SkipElectron
  Skip Electron install (uses the existing app\node_modules\electron).

.EXAMPLE
  .\pack-exe\build.ps1

.EXAMPLE
  .\pack-exe\build.ps1 -NodeDir D:\SDKS\node-v24.19.0-win-x64 -SkipBuild
#>
param(
  [string]$NodeDir = "",
  [switch]$SkipBuild,
  [switch]$SkipElectron
)

$ErrorActionPreference = "Stop"
$PackDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $PackDir
$OutApp = Join-Path $PackDir "out\dsh-app"
$Runtime = Join-Path $OutApp "resources\runtime\repo"
$AppSource = Join-Path $PackDir "app"
$Scripts = Join-Path $PackDir "scripts"

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" }
}

function Copy-WithRobocopy {
  param([string]$Source, [string]$Destination, [string[]]$ExcludeDirs)
  $rcArgs = @($Source, $Destination, "/E", "/XJ", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
  foreach ($dir in $ExcludeDirs) { $rcArgs += @("/XD", $dir) }
  & robocopy @rcArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($Source -> $Destination) with exit code $LASTEXITCODE" }
}

Write-Host "==> [1/8] Check environment" -ForegroundColor Cyan

# Node.js portable runtime.
$candidates = @("D:\Program\SDKS\node-v24.19.0-win-x64", "$env:USERPROFILE\.nvm\versions\node")
if ($NodeDir -eq "") {
  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCommand) { $candidates += Split-Path -Parent $nodeCommand.Source }
  $NodeDir = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ "node.exe")) } | Select-Object -First 1
}
if (-not $NodeDir -or -not (Test-Path (Join-Path $NodeDir "node.exe"))) {
  throw "node.exe not found. Pass -NodeDir pointing at a portable Node 24+ directory."
}
$NodeExe = Join-Path $NodeDir "node.exe"
Write-Host "  node: $NodeExe"

# Workspace dependencies.
if (-not (Test-Path (Join-Path $RepoRoot "node_modules"))) {
  Write-Host "  node_modules missing, running pnpm install ..."
  $env:CI = "true"
  Invoke-Checked "pnpm" @("install")
}

# Built artifacts (apps\cli\lib\bin.js is the bundled entry the app runs).
$BuiltEntry = Join-Path $RepoRoot "apps\cli\lib\bin.js"
if (-not (Test-Path $BuiltEntry)) {
  if ($SkipBuild) { throw "build artifacts missing and -SkipBuild was given" }
  Write-Host "  build artifacts missing, running pnpm run build ..."
  $env:CI = "true"
  Invoke-Checked "pnpm" @("run", "build")
} elseif (-not $SkipBuild) {
  Write-Host "  artifacts present (-SkipBuild to keep them untouched)"
}

Write-Host "==> [2/8] Clean output" -ForegroundColor Cyan
# Stop leftover app/server processes first: they hold DLL handles inside the
# previous bundle and would block the cleanup below.
Get-Process dsh, electron -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "  stopping leftover process $($_.Id) ($($_.ProcessName))"
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
$conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($conn) {
  $conn | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
    Write-Host "  stopping leftover server process $_"
    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
  }
}
if (Test-Path $OutApp) { Remove-Item $OutApp -Recurse -Force }
New-Item -ItemType Directory -Path $Runtime -Force | Out-Null

Write-Host "==> [3/8] Prepare Electron runtime" -ForegroundColor Cyan
$ElectronExe = Join-Path $AppSource "node_modules\electron\dist\electron.exe"
if (-not (Test-Path $ElectronExe)) {
  if ($SkipElectron) { throw "Electron not installed and -SkipElectron was given" }
  Write-Host "  installing electron (first run downloads ~100 MB) ..."
  Push-Location $AppSource
  try {
    Invoke-Checked "npm" @("install")
  } finally {
    Pop-Location
  }
}
if (-not (Test-Path $ElectronExe)) { throw "Electron dist not found after install" }
$ElectronDist = Join-Path $AppSource "node_modules\electron\dist"
Write-Host "  electron: $((Get-Content (Join-Path $AppSource 'node_modules\electron\package.json') -Raw | ConvertFrom-Json).version)"

Write-Host "==> [4/8] Copy Electron shell (electron.exe -> dsh.exe)" -ForegroundColor Cyan
Copy-WithRobocopy -Source $ElectronDist -Destination $OutApp
if (Test-Path (Join-Path $OutApp "electron.exe")) {
  Move-Item (Join-Path $OutApp "electron.exe") (Join-Path $OutApp "dsh.exe") -Force
} else {
  throw "electron.exe not found in dist"
}

# Slim the Electron shell: keep only en-US/zh-CN locales and drop the
# chromium license page (not used at runtime).
Write-Host "  slimming Electron shell ..."
$LocalesDir = Join-Path $OutApp "locales"
if (Test-Path $LocalesDir) {
  Get-ChildItem $LocalesDir -Filter "*.pak" | Where-Object { $_.BaseName -notin @("en-US", "zh-CN") } | Remove-Item -Force
}
Remove-Item (Join-Path $OutApp "LICENSES.chromium.html") -Force -ErrorAction SilentlyContinue

Write-Host "==> [5/8] Copy app code (main.js) into resources\app" -ForegroundColor Cyan
$AppDst = Join-Path $OutApp "resources\app"
Copy-WithRobocopy -Source $AppSource -Destination $AppDst -ExcludeDirs @("node_modules", (Join-Path $AppSource "node_modules"))
if (-not (Test-Path (Join-Path $AppDst "main.js"))) { throw "main.js missing in app bundle" }

Write-Host "==> [6/8] Copy node.exe + relink tooling into resources\runtime" -ForegroundColor Cyan
$RuntimeRoot = Join-Path $OutApp "resources\runtime"
New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
Copy-Item $NodeExe (Join-Path $RuntimeRoot "node.exe") -Force
Copy-Item (Join-Path $Scripts "relink.mjs") (Join-Path $RuntimeRoot "relink.mjs") -Force
$LinkMap = Join-Path $RuntimeRoot "linkmap.json"
if (Test-Path $LinkMap) { Remove-Item $LinkMap -Force }

Write-Host "==> [7/8] Copy repository + node_modules into resources\runtime\repo" -ForegroundColor Cyan
# Name-based /XD exclusions: robocopy matches these against the source tree
# (absolute paths match the destination tree instead and silently fail).
# Only what dsh needs at runtime is copied; dev/CI material is dropped.
$RepoExcludes = @(
  "node_modules", ".git", "pack-exe", "out", "build.log",
  ".agents", ".claude", ".github", ".dsh-build",
  "docs", "examples", "scripts", "website", "python", "patches"
)
Copy-WithRobocopy -Source $RepoRoot -Destination $Runtime -ExcludeDirs $RepoExcludes

$RootNmSrc = Join-Path $RepoRoot "node_modules"
$RootNmDst = Join-Path $Runtime "node_modules"
Copy-WithRobocopy -Source $RootNmSrc -Destination $RootNmDst
Invoke-Checked $NodeExe @((Join-Path $Scripts "copy-links.mjs"), $RepoRoot, $Runtime, $RootNmSrc, $RootNmDst, $LinkMap)

$childNms = Get-ChildItem $RepoRoot -Recurse -Directory -Filter "node_modules" -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -ne $RootNmSrc }
$handled = 0
foreach ($childNm in $childNms) {
  $rel = $childNm.FullName.Substring($RepoRoot.Length).TrimStart("\", "/")
  # Skip node_modules under directories that were excluded from the snapshot.
  $skip = $false
  foreach ($ex in $RepoExcludes) {
    if ($rel -like "$ex\*" -or $rel -eq $ex) { $skip = $true; break }
  }
  if ($skip) { continue }
  $childDst = Join-Path $Runtime $rel
  Copy-WithRobocopy -Source $childNm.FullName -Destination $childDst
  Invoke-Checked $NodeExe @((Join-Path $Scripts "copy-links.mjs"), $RepoRoot, $Runtime, $childNm.FullName, $childDst, $LinkMap)
  $handled++
}
Write-Host "  recreated junctions for $handled child node_modules trees"

# Post-cleanup: drop packages that no runtime dependency closure references.
# subagent-codex / subagent-claude-code are orphan workspace packages (no
# bundle mounts them), and mermaid is a docs-toolchain devDependency only.
Write-Host "  dropping unused heavy packages (codex, claude-agent-sdk, mermaid) ..."
$PnpmDst = Join-Path $RootNmDst ".pnpm"
if (Test-Path $PnpmDst) {
  Get-ChildItem $PnpmDst -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like "@openai+codex*" -or
    $_.Name -like "@anthropic-ai+claude-agent-sdk*" -or
    $_.Name -like "mermaid@*" -or
    $_.Name -like "@mermaid-js+*"
  } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==> [8/8] Write version info" -ForegroundColor Cyan
$version = (Get-Content (Join-Path $RepoRoot "apps\cli\package.json") -Raw | ConvertFrom-Json).version
$gitHash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
"dsh $version ($gitHash) - packaged $((Get-Date).ToString('yyyy-MM-dd HH:mm'))" |
  Out-File (Join-Path $OutApp "VERSION.txt") -Encoding utf8

Write-Host ""
Write-Host "Packaging complete: $OutApp" -ForegroundColor Green
$sizeMb = [Math]::Round(((Get-ChildItem $OutApp -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 0)
Write-Host "  total size: $sizeMb MB (reported size includes junction double-counting)"
Write-Host "  double-click dsh.exe to open DeepSeek Harness in its own window"
