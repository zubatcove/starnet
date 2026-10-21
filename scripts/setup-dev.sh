#!/usr/bin/env bash
# Configure a local StarNet development environment on macOS or Linux.
#
#   bash scripts/setup-dev.sh                 # Node 22 + npm ci + sidecar smoke check
#   bash scripts/setup-dev.sh --desktop       # also Rust + Tauri system prerequisites
#   bash scripts/setup-dev.sh --test          # also run the fast merge gate (npm run test:fast)
#   bash scripts/setup-dev.sh --check         # report only; install nothing
#
# Windows: use scripts/setup-dev.ps1.
#
# The script is idempotent and only installs into user-level tool managers (nvm/fnm/rustup)
# unless --desktop asks for system packages, which go through apt/dnf/pacman (sudo) or
# xcode-select. It never touches the StarNet station data directory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

NODE_MAJOR=22          # matches CI (fast-gate.yml, desktop-build.yml) and the release train
NODE_MIN_MAJOR=18      # package.json engines
DESKTOP=0
RUN_TESTS=0
CHECK_ONLY=0
YES=0

for arg in "$@"; do
  case "$arg" in
    --desktop) DESKTOP=1 ;;
    --test) RUN_TESTS=1 ;;
    --check) CHECK_ONLY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B= G= Y= R= N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
WARNINGS=0

confirm() {
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  read -r -p "  $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}

OS=$(uname -s)
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  *) fail "unsupported OS $OS; on Windows run: powershell -ExecutionPolicy Bypass -File scripts\\setup-dev.ps1" ;;
esac

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && return 0
  return 1
}

# --- 1. base tools -----------------------------------------------------------------------------
step "Base tools ($PLATFORM)"
have git || fail "git is required: https://git-scm.com/downloads"
ok "git $(git --version | awk '{print $3}')"
have curl || fail "curl is required"
ok "curl"

# --- 2. Node.js --------------------------------------------------------------------------------
step "Node.js $NODE_MAJOR"
if have fnm; then eval "$(fnm env --shell bash)" || true; fi
load_nvm || true

current=$(have node && node_major || echo 0)
if [ "$current" = "$NODE_MAJOR" ]; then
  ok "node $(node -v)"
elif [ "$CHECK_ONLY" = 1 ]; then
  if [ "$current" -ge "$NODE_MIN_MAJOR" ]; then warn "node $(node -v) works, but CI uses Node $NODE_MAJOR"
  else warn "Node $NODE_MAJOR is not installed (found: ${current/#0/none})"; fi
else
  if type nvm >/dev/null 2>&1; then
    nvm install "$NODE_MAJOR" && nvm use "$NODE_MAJOR" >/dev/null
  elif have fnm; then
    fnm install "$NODE_MAJOR" && fnm use "$NODE_MAJOR"
  elif have volta; then
    volta install "node@$NODE_MAJOR"
  elif [ "$current" -ge "$NODE_MIN_MAJOR" ]; then
    warn "node $(node -v) works, but CI uses Node $NODE_MAJOR; install nvm or fnm to switch versions"
  elif confirm "No Node version manager found. Install nvm (user-level, ~/.nvm) and Node $NODE_MAJOR?"; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash
    load_nvm || fail "nvm installed but could not be loaded; open a new shell and re-run"
    nvm install "$NODE_MAJOR" && nvm use "$NODE_MAJOR" >/dev/null
    warn "nvm was installed without editing your shell profile; add this to it:  . \"\$HOME/.nvm/nvm.sh\""
  else
    fail "Node >= $NODE_MIN_MAJOR is required (Node $NODE_MAJOR recommended): https://nodejs.org or https://github.com/nvm-sh/nvm"
  fi
  [ "$(node_major)" -ge "$NODE_MIN_MAJOR" ] || fail "Node is still older than $NODE_MIN_MAJOR after install"
  ok "node $(node -v), npm $(npm -v)"
fi

# --- 3. npm dependencies -----------------------------------------------------------------------
step "npm dependencies"
lock_hash=$(node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha256").update(require("fs").readFileSync("package-lock.json")).digest("hex"))')
stamp=node_modules/.setup-dev-lock
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$lock_hash-$(node -v)" ]; then
  ok "node_modules matches package-lock.json (skip npm ci)"
elif [ "$CHECK_ONLY" = 1 ]; then
  warn "node_modules is missing or out of date; run npm ci"
else
  npm ci
  printf '%s' "$lock_hash-$(node -v)" > "$stamp"
  ok "npm ci complete"
fi

# --- 4. desktop shell (optional) ---------------------------------------------------------------
if [ "$DESKTOP" = 1 ]; then
  step "Desktop shell prerequisites (Rust + Tauri)"
  [ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  if have rustc && have cargo; then
    ok "rustc $(rustc --version | awk '{print $2}') (Cargo.toml needs >= 1.77.2)"
  elif [ "$CHECK_ONLY" = 1 ]; then
    warn "Rust is not installed"
  elif confirm "Install Rust via rustup (user-level, ~/.cargo)?"; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
    ok "rustc $(rustc --version | awk '{print $2}')"
  else
    warn "skipped Rust; desktop:dev and desktop:build will not work"
  fi

  if [ "$PLATFORM" = macos ]; then
    if xcode-select -p >/dev/null 2>&1; then ok "Xcode Command Line Tools"
    elif [ "$CHECK_ONLY" = 1 ]; then warn "Xcode Command Line Tools are not installed"
    else xcode-select --install || true; warn "finish the Xcode Command Line Tools installer, then re-run"; fi
  else
    # Same package set as .github/workflows/desktop-build.yml (Ubuntu); dnf/pacman names follow
    # the Tauri v2 prerequisites page.
    if have apt-get; then
      pm="sudo apt-get install -y"; pkgs="libwebkit2gtk-4.1-dev build-essential curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev libdbus-1-dev"
      check() { dpkg -s $pkgs >/dev/null 2>&1; }
    elif have dnf; then
      pm="sudo dnf install -y"; pkgs="webkit2gtk4.1-devel openssl-devel curl wget file libappindicator-gtk3-devel librsvg2-devel libxdo-devel dbus-devel"
      check() { rpm -q $pkgs >/dev/null 2>&1; }
    elif have pacman; then
      pm="sudo pacman -S --needed --noconfirm"; pkgs="webkit2gtk-4.1 base-devel curl wget file openssl appmenu-gtk-module libappindicator-gtk3 librsvg xdotool dbus"
      check() { pacman -Q $pkgs >/dev/null 2>&1; }
    else
      pm=""; check() { return 1; }
    fi
    if check; then ok "Tauri system packages"
    elif [ -z "$pm" ]; then warn "unknown package manager; install the Tauri prerequisites by hand: https://v2.tauri.app/start/prerequisites/"
    elif [ "$CHECK_ONLY" = 1 ]; then warn "Tauri system packages are missing: $pkgs"
    elif confirm "Install Tauri system packages with sudo ($pm ...)?"; then
      have apt-get && sudo apt-get update
      $pm $pkgs
      ok "Tauri system packages"
    else
      warn "skipped Tauri system packages"
    fi
  fi
  have npx && npx --no-install tauri --version >/dev/null 2>&1 && ok "tauri cli $(npx --no-install tauri --version | awk '{print $2}')"
fi

# --- 5. optional tools (report only) -----------------------------------------------------------
step "Optional tools"
chrome=""
for c in google-chrome google-chrome-stable chromium chromium-browser \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
  if have "$c" || [ -x "$c" ]; then chrome=$c; break; fi
done
if [ -n "${SKYNET_CHROME:-}" ]; then ok "Chrome for e2e tests: SKYNET_CHROME=$SKYNET_CHROME"
elif [ -n "$chrome" ]; then ok "Chrome for e2e tests: $chrome"
else warn "no Chrome/Chromium found; browser e2e tests in test:fast need one (or set SKYNET_CHROME)"; fi
have gitleaks && ok "gitleaks (npm run security:secrets)" || printf '  - gitleaks not found (only needed for npm run security:secrets)\n'
have ollama && ok "ollama (free local models)" || printf '  - ollama not found (optional: run agents on a local model, see README)\n'

# --- 6. verify ---------------------------------------------------------------------------------
step "Verify"
node --check sidecar/index.js && ok "sidecar entry point parses"
node -e 'for (const m of ["ajv","undici"]) require.resolve(m)' 2>/dev/null && ok "runtime dependencies resolve" \
  || warn "runtime dependencies do not resolve; run npm ci"
if [ "$RUN_TESTS" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
  npm run test:fast
  ok "npm run test:fast passed"
fi

if [ "$WARNINGS" -gt 0 ]; then step "Done ($WARNINGS warning(s) above)"; else step "Done"; fi
cat <<EOF
  Start the station:   npm start            then open http://localhost:8787
  Merge gate:          npm run test:fast
EOF
[ "$DESKTOP" = 1 ] && echo "  Desktop dev shell:   npm run desktop:dev"
exit 0
