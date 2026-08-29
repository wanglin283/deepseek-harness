<#
.SYNOPSIS
  One-command DSH upgrade + packaging: sync official master, restore the
  pack-exe tooling, then build and package the windowed app.

.DESCRIPTION
  Long-term workflow for keeping the packaged dsh-app in sync with upstream:

    1. Extract pack-exe from the feature branch (where it lives as commits)
    2. Fast-forward local master to origin/master (official latest)
    3. Restore pack-exe into the master worktree as a local (untracked) tool
    4. Run pack-exe\build.ps1, which installs deps, builds, and packages

  After the first run, master stays the pure official code plus the local
  pack-exe directory; later upgrades are just this script again.

  To contribute changes to pack-exe, switch to the feature branch, commit,
  and push (updates the open PR).

.PARAMETER Branch
  Feature branch that holds the pack-exe commits (default:
  feat/pack-exe-windows-bundler).

.PARAMETER SkipBuild
  Pass through to build.ps1: skip `pnpm run build` when artifacts exist.

.PARAMETER SkipElectron
  Pass through to build.ps1: skip Electron install.

.PARAMETER NoFetch
  Skip git fetch and use the locally cached origin/master (useful when the
  network is down but a recent fetch already succeeded).

.EXAMPLE
  .\pack-exe\update.ps1

.EXAMPLE
  .\pack-exe\update.ps1 -SkipBuild
#>
param(
  [string]$Branch = "feat/pack-exe-windows-bundler",
  [switch]$SkipBuild,
  [switch]$SkipElectron,
  [switch]$NoFetch
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TempDir = Join-Path $env:TEMP "dsh-update-pack-exe"

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" }
}

Push-Location $RepoRoot
try {
  Write-Host "==> [1/5] Check worktree is clean" -ForegroundColor Cyan
  $dirty = & git status --porcelain
  if ($LASTEXITCODE -ne 0) { throw "git status failed" }
  if ($dirty) {
    Write-Host "  uncommitted changes present:" -ForegroundColor Yellow
    $dirty | ForEach-Object { Write-Host "    $_" }
    throw "Please commit or stash local changes before upgrading"
  }

  Write-Host "==> [2/5] Extract pack-exe from branch '$Branch'" -ForegroundColor Cyan
  if (-not (& git rev-parse --verify --quiet "refs/heads/$Branch")) {
    throw "branch '$Branch' not found (it holds the pack-exe commits)"
  }
  if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
  New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
  # git archive includes only committed pack-exe files (out/, app/node_modules
  # and other gitignored material stays behind - exactly what packaging needs).
  & git archive $Branch pack-exe | tar -x -C $TempDir
  if ($LASTEXITCODE -ne 0) { throw "extracting pack-exe failed" }
  Write-Host "  extracted to $TempDir"

  Write-Host "==> [3/5] Sync master to origin/master" -ForegroundColor Cyan
  if (-not $NoFetch) {
    Invoke-Checked "git" @("fetch", "origin", "master")
  } else {
    Write-Host "  -NoFetch: using cached origin/master"
  }
  Invoke-Checked "git" @("checkout", "-B", "master", "origin/master")
  $newVersion = (Get-Content (Join-Path $RepoRoot "apps\cli\package.json") -Raw | ConvertFrom-Json).version
  $newCommit = & git rev-parse --short HEAD
  Write-Host "  master now at $newCommit (dsh $newVersion)"

  Write-Host "==> [4/5] Restore pack-exe into the worktree" -ForegroundColor Cyan
  if (Test-Path (Join-Path $RepoRoot "pack-exe")) { Remove-Item (Join-Path $RepoRoot "pack-exe") -Recurse -Force }
  Copy-Item (Join-Path $TempDir "pack-exe") (Join-Path $RepoRoot "pack-exe") -Recurse -Force
  Write-Host "  pack-exe restored (untracked local tooling)"

  Write-Host "==> [5/6] Build (forced: upstream may have added packages)" -ForegroundColor Cyan
  # build.ps1 only builds when artifacts are missing, which is wrong after an
  # upgrade (stale lib/bin.js would silently skip building newly added
  # packages). Force the full build here unless -SkipBuild.
  if (-not $SkipBuild) {
    $env:CI = "true"
    # Prefer the known-good Node 24 portable runtime for the build.
    $nodeDir = "D:\Program\SDKS\node-v24.19.0-win-x64"
    if (-not (Test-Path (Join-Path $nodeDir "node.exe"))) {
      $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
      if ($nodeCommand) { $nodeDir = Split-Path -Parent $nodeCommand.Source }
    }
    $env:PATH = "$nodeDir;$env:PATH"
    Invoke-Checked "pnpm" @("run", "build")
  }

  Write-Host "==> [6/6] Package" -ForegroundColor Cyan
  $buildArgs = @((Join-Path $RepoRoot "pack-exe\build.ps1"), "-SkipBuild")
  if ($SkipElectron) { $buildArgs += "-SkipElectron" }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $buildArgs
  if ($LASTEXITCODE -ne 0) { throw "packaging failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "Upgrade complete." -ForegroundColor Green
Write-Host "  new bundle: $RepoRoot\pack-exe\out\dsh-app"
Write-Host "  copy it to the target machine and double-click dsh.exe"
