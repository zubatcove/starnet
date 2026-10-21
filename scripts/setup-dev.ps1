# Configure a local StarNet development environment on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts\setup-dev.ps1             # Node 22 + npm ci + sidecar smoke check
#   powershell -ExecutionPolicy Bypass -File scripts\setup-dev.ps1 -Desktop    # also Rust + Tauri prerequisites
#   powershell -ExecutionPolicy Bypass -File scripts\setup-dev.ps1 -Test       # also run npm run test:fast
#   powershell -ExecutionPolicy Bypass -File scripts\setup-dev.ps1 -Check      # report only; install nothing
#
# macOS/Linux: use scripts/setup-dev.sh. Installs go through winget (user scope where available).
# The script is idempotent and never touches %APPDATA%\ai.skynet.harness.
[CmdletBinding()]
param(
  [switch]$Desktop,
  [switch]$Test,
  [switch]$Check,
  [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$NodeMajor = 22      # matches CI (fast-gate.yml, desktop-build.yml) and the release train
$NodeMinMajor = 18   # package.json engines
$script:Warnings = 0

function Step($m) { Write-Host "`n==> $m" -ForegroundColor White }
function Ok($m)   { Write-Host "  + $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow; $script:Warnings++ }
function Fail($m) { Write-Host "  x $m" -ForegroundColor Red; exit 1 }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Confirm($q) {
  if ($Yes) { return $true }
  if (-not [Environment]::UserInteractive) { return $false }
  return (Read-Host "  $q [y/N]") -match '^[Yy]'
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Node-Major { if (Have node) { [int](node -p "process.versions.node.split('.')[0]") } else { 0 } }
function Winget-Install($id, $label) {
  if (-not (Have winget)) { Fail "winget is not available; install $label by hand" }
  winget install --id $id -e --accept-source-agreements --accept-package-agreements
  Refresh-Path
}

# --- 1. base tools -----------------------------------------------------------------------------
Step 'Base tools (windows)'
if (-not (Have git)) { Fail 'git is required: https://git-scm.com/download/win (or: winget install Git.Git)' }
Ok (git --version)

# --- 2. Node.js --------------------------------------------------------------------------------
Step "Node.js $NodeMajor"
$current = Node-Major
if ($current -eq $NodeMajor) {
  Ok "node $(node -v)"
} elseif ($Check) {
  if ($current -ge $NodeMinMajor) { Warn "node $(node -v) works, but CI uses Node $NodeMajor" } else { Warn "Node $NodeMajor is not installed" }
} else {
  if (Have fnm) {
    fnm install $NodeMajor; fnm use $NodeMajor
  } elseif (Have nvm) {
    nvm install $NodeMajor; nvm use $NodeMajor; Refresh-Path
  } elseif (Have volta) {
    volta install "node@$NodeMajor"
  } elseif ($current -ge $NodeMinMajor) {
    Warn "node $(node -v) works, but CI uses Node $NodeMajor; install fnm or nvm-windows to switch versions"
  } elseif (Confirm "Install Node.js $NodeMajor LTS with winget?") {
    Winget-Install 'OpenJS.NodeJS.22' 'Node.js'
  } else {
    Fail "Node >= $NodeMinMajor is required (Node $NodeMajor recommended): https://nodejs.org"
  }
  if ((Node-Major) -lt $NodeMinMajor) { Fail "Node is still older than $NodeMinMajor; open a new terminal and re-run" }
  Ok "node $(node -v), npm $(npm -v)"
}

# --- 3. npm dependencies -----------------------------------------------------------------------
Step 'npm dependencies'
$lockHash = (Get-FileHash package-lock.json -Algorithm SHA256).Hash.ToLower()
$stamp = 'node_modules\.setup-dev-lock'
$want = "$lockHash-$(node -v)"
if ((Test-Path $stamp) -and ((Get-Content $stamp -Raw) -eq $want)) {
  Ok 'node_modules matches package-lock.json (skip npm ci)'
} elseif ($Check) {
  Warn 'node_modules is missing or out of date; run npm ci'
} else {
  npm ci
  if ($LASTEXITCODE -ne 0) { Fail 'npm ci failed' }
  Set-Content -Path $stamp -Value $want -NoNewline
  Ok 'npm ci complete'
}

# --- 4. desktop shell (optional) ---------------------------------------------------------------
if ($Desktop) {
  Step 'Desktop shell prerequisites (Rust + Tauri)'
  if (Have rustc) {
    Ok "rustc $((rustc --version).Split(' ')[1]) (Cargo.toml needs >= 1.77.2)"
  } elseif ($Check) {
    Warn 'Rust is not installed'
  } elseif (Confirm 'Install Rust (rustup) with winget?') {
    Winget-Install 'Rustlang.Rustup' 'Rust'
    rustup default stable-msvc
    Ok "rustc $((rustc --version).Split(' ')[1])"
  } else { Warn 'skipped Rust; desktop:dev and desktop:build will not work' }

  # Tauri on Windows needs the MSVC C++ build tools and WebView2 (preinstalled on Windows 11).
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $hasMsvc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if ($hasMsvc) { Ok 'MSVC C++ build tools' }
  elseif ($Check) { Warn 'MSVC C++ build tools are missing' }
  elseif (Confirm 'Install Visual Studio Build Tools (C++ workload) with winget? (large download)') {
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements `
      --override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    Ok 'MSVC C++ build tools'
  } else { Warn 'skipped MSVC build tools: https://v2.tauri.app/start/prerequisites/#windows' }

  $wv = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  if ((Test-Path $wv) -or (Test-Path ($wv -replace 'HKLM:\\SOFTWARE\\WOW6432Node', 'HKCU:\SOFTWARE'))) { Ok 'WebView2 runtime' }
  else { Warn 'WebView2 runtime not detected: https://developer.microsoft.com/microsoft-edge/webview2/' }
}

# --- 5. optional tools (report only) -----------------------------------------------------------
Step 'Optional tools'
$chromes = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
$chrome = $chromes | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($env:SKYNET_CHROME) { Ok "Chrome for e2e tests: SKYNET_CHROME=$env:SKYNET_CHROME" }
elseif ($chrome) { Ok "Chrome for e2e tests: $chrome" }
else { Warn 'no Chrome found; browser e2e tests in test:fast need one (or set SKYNET_CHROME)' }
if (Have gitleaks) { Ok 'gitleaks (npm run security:secrets)' } else { Write-Host '  - gitleaks not found (only needed for npm run security:secrets)' }
if (Have ollama) { Ok 'ollama (free local models)' } else { Write-Host '  - ollama not found (optional: run agents on a local model, see README)' }

# --- 6. verify ---------------------------------------------------------------------------------
Step 'Verify'
node --check sidecar/index.js
if ($LASTEXITCODE -eq 0) { Ok 'sidecar entry point parses' } else { Fail 'sidecar/index.js does not parse' }
node -e 'for (const m of ["ajv","undici"]) require.resolve(m)' 2>$null
if ($LASTEXITCODE -eq 0) { Ok 'runtime dependencies resolve' } else { Warn 'runtime dependencies do not resolve; run npm ci' }
if ($Test -and -not $Check) {
  npm run test:fast
  if ($LASTEXITCODE -ne 0) { Fail 'npm run test:fast failed' }
  Ok 'npm run test:fast passed'
}

if ($script:Warnings -gt 0) { Step "Done ($($script:Warnings) warning(s) above)" } else { Step 'Done' }
Write-Host '  Start the station:   npm start            then open http://localhost:8787'
Write-Host '  Merge gate:          npm run test:fast'
if ($Desktop) { Write-Host '  Desktop dev shell:   npm run desktop:dev' }
