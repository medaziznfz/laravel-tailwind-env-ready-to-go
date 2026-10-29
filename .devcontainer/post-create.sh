#!/usr/bin/env bash
# ==============================================================
# Codespace post-create setup — FAULT-TOLERANT + DIAGNOSTIC
# Every step runs independently; no failure kills the whole script.
# A full report is written to  post-create-report.txt  (repo root):
# send that file's content to your assistant for debugging.
#
# Steps:
#  1. Composer self-update          6. .env + APP_KEY + DB creds
#  2. PHP pdo_mysql extension       7. npm install + Tailwind build
#  3. Database CA certificate       8. OpenCode (V2)
#  4. Clone app into ./src          9. ngrok (direct download, apt fallback)
#  5. composer install             10. serve/link commands + dev server
# NO migrations are run — the app uses an existing database.
# ==============================================================

set -uo pipefail

# ---------- setup ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_FILE="${REPO_ROOT}/post-create-report.txt"

FAILED=()
PASSED=()
SKIPPED=()

exec > >(tee "${REPORT_FILE}") 2>&1

echo "══════════════════════════════════════════════════════"
echo "  POST-CREATE SETUP — $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "  Codespace container: $(uname -sr)"
echo "══════════════════════════════════════════════════════"

step() {
    local name="$1"; shift
    echo ""
    echo "────────────── $name ──────────────"
    if "$@"; then
        echo "→ ✅ ${name}: OK"
        PASSED+=("${name}")
    else
        echo "→ ❌ ${name}: FAILED"
        FAILED+=("${name}")
    fi
}

# ---------- Configuration ----------
REPO_URL="https://github.com/S-Marouene/Laravel-adm-tawilwindcss.git"
APP_DIR="src"

DB_CONNECTION=mysql
DB_HOST=mysql-onpc-onpc.g.aivencloud.com
DB_PORT=15850
DB_DATABASE=defaultdb
DB_USERNAME=avnadmin
# Provided by a GitHub Codespace secret named DB_PASSWORD (nothing committed here)
DB_PASSWORD="${DB_PASSWORD:-}"
# Aiven requires SSL — certs/ca.pem is copied and referenced from .env
CA_FILE="certs/ca.pem"
CA_DEST="$HOME/.mysql-ca.pem"

# ngrok authtoken — Codespace secret NGROK_AUTHTOKEN (nothing committed here)
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"

# ---------- missing-secret early warnings ----------
if [ -z "${DB_PASSWORD}" ]; then
    echo ""
    echo "❌ DB_PASSWORD is EMPTY — the Codespace secret was not found."
    echo "   Cause: no secret named 'DB_PASSWORD' is attached to this repo,"
    echo "   or it was added after the Codespace was created (fix = rebuild)."
    echo "   Fix: GitHub → Settings → Secrets and variables → Codespaces → New secret"
    echo "        Name DB_PASSWORD → Repository access: this repository → rebuild."
    echo "   Note: setup still continues so you can also fill src/.env manually."
fi
if [ -z "${NGROK_AUTHTOKEN}" ] && [ ! -f "$HOME/.ngrok-token" ]; then
    echo "❌ NGROK_AUTHTOKEN is EMPTY — 'link' will not work until you add"
    echo "   this Codespace secret (or run: ngrok config add-authtoken <token>)."
fi

# ---------- step implementations ----------
step_composer_selfupdate() {
    sudo -E composer self-update
}

step_php_extensions() {
    # the PHP devcontainer image ships WITHOUT the mysql PDO driver
    if php -m 2>/dev/null | grep -qiE '^pdo_mysql$'; then
        echo "pdo_mysql already loaded"
        return 0
    fi
    sudo docker-php-ext-install pdo_mysql
    php -m 2>/dev/null | grep -qiE '^pdo_mysql$' \
        || { echo "pdo_mysql still not loaded"; return 1; }
    echo "pdo_mysql loaded"
}

step_copy_ca() {
    if [ -f "${REPO_ROOT}/${CA_FILE}" ]; then
        cp "${REPO_ROOT}/${CA_FILE}" "${CA_DEST}" && \
            echo "CA copied: ${CA_DEST} ($(wc -l < "${CA_DEST}") lines)"
    else
        echo "${CA_FILE} missing from the template repo"
        return 1
    fi
}

step_clone_app() {
    cd "${REPO_ROOT}"
    if [ ! -f "${APP_DIR}/artisan" ]; then
        rm -rf "${APP_DIR}"
        git clone "${REPO_URL}" "${APP_DIR}"
    else
        echo "skipping clone — ${APP_DIR}/artisan already exists"
        if [ -d "${APP_DIR}/.git" ]; then
            git -C "${APP_DIR}" pull --ff-only || true
        fi
        return 0
    fi
}

step_composer_install() {
    cd "${REPO_ROOT}/${APP_DIR}"
    composer install --no-interaction
}

step_env_file() {
    cd "${REPO_ROOT}/${APP_DIR}"
    if [ ! -f .env ]; then
        if [ -f .env.example ]; then cp .env.example .env; else touch .env; fi
    fi
    # helper: replace KEY=value or append
    set_env_key() {
        local key="$1" value="$2"
        if grep -qE "^${key}=.*" .env; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" .env
        else
            printf '%s="%s"\n' "${key}" "${value}" >> .env
        fi
    }
    if grep -qE '^APP_KEY=$' .env || ! grep -qE '^APP_KEY=.*[[:alnum:]]' .env; then
        php artisan key:generate --force
    fi
    set_env_key DB_CONNECTION "${DB_CONNECTION}"
    set_env_key DB_HOST "${DB_HOST}"
    set_env_key DB_PORT "${DB_PORT}"
    set_env_key DB_DATABASE "${DB_DATABASE}"
    set_env_key DB_USERNAME "${DB_USERNAME}"
    set_env_key DB_PASSWORD "${DB_PASSWORD}"
    set_env_key MYSQL_ATTR_SSL_CA "$CA_DEST"
    echo "wrote DB_HOST=$(grep '^DB_HOST=' .env)"
}

step_npm_install() {
    cd "${REPO_ROOT}/${APP_DIR}"
    [ -f package.json ] || { echo "no package.json — skipped"; return 0; }
    npm install --no-audit --no-fund
}

step_npm_build() {
    cd "${REPO_ROOT}/${APP_DIR}"
    [ -f package.json ] || { echo "no package.json — skipped"; return 0; }
    if npm run 2>&1 | grep -qE "build"; then
        npm run build
    else
        echo "no build script — skipped"
        return 0
    fi
}

step_opencode() {
    # sudo resets PATH (node lives outside it) — install WITHOUT sudo
    # using a user-level npm prefix, then expose the binary system-wide.
    NPM_PREFIX="${HOME}/.npm-global"
    export NPM_CONFIG_PREFIX="${NPM_PREFIX}"
    mkdir -p "${NPM_PREFIX}"
    npm install -g @opencode/cli@latest
    BINFILE="$(find "${NPM_PREFIX}/bin" -maxdepth 1 -name 'opencode*' 2>/dev/null | head -n1)"
    if [ -n "${BINFILE}" ]; then
        sudo ln -sf "${BINFILE}" /usr/local/bin/opencode
    else
        echo "opencode binary not found in ${NPM_PREFIX}/bin"
        return 1
    fi
    opencode --version
}

step_ngrok() {
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    if [ -x "${BIN_DIR}/ngrok" ] || command -v ngrok >/dev/null 2>&1; then
        echo "ngrok binary already present"
    else
        case "$(uname -m)" in
            aarch64 | arm64) NGROK_ARCH="linux-arm64" ;;
            *)               NGROK_ARCH="linux-amd64" ;;
        esac
        echo "trying direct download (${NGROK_ARCH})..."
        if curl -fsSL \
            "https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-${NGROK_ARCH}.tgz" \
            | tar -xz -C "$BIN_DIR"; then
            chmod +x "$BIN_DIR/ngrok"
        else
            echo "direct download failed — trying the ngrok apt repository..."
            curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
                | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
            echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
                | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y ngrok
        fi
    fi
    NGROK_BIN="$(command -v ngrok || echo "${BIN_DIR}/ngrok")"
    if ! sudo ln -sf "${NGROK_BIN}" /usr/local/bin/ngrok 2>/dev/null; then
        echo "(symlink skipped — same file)"
    fi
    ngrok --version
}

step_helper_commands() {
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    for CMD in serve link; do
        if [ -f "${REPO_ROOT}/bin/${CMD}" ]; then
            cp "${REPO_ROOT}/bin/${CMD}" "${BIN_DIR}/${CMD}"
            chmod +x "${BIN_DIR}/${CMD}"
            sudo ln -sf "${BIN_DIR}/${CMD}" "/usr/local/bin/${CMD}"
            echo "installed ${CMD} → ${BIN_DIR}/${CMD}"
        else
            echo "bin/${CMD} missing from the template repo"
            return 1
        fi
    done
    # persist the ngrok authtoken (home survives rebuilds)
    if [ -n "${NGROK_AUTHTOKEN:-}" ]; then
        printf '%s' "${NGROK_AUTHTOKEN}" > "$HOME/.ngrok-token"
    fi
    if [ -f "$HOME/.ngrok-token" ] && command -v ngrok >/dev/null 2>&1; then
        NGROK_BIN="$(command -v ngrok)"
        if "${NGROK_BIN}" config add-authtoken "$(cat "$HOME/.ngrok-token")" >/dev/null; then
            echo "ngrok authtoken registered"
        else
            echo "!! failed to register the ngrok authtoken"
            return 1
        fi
    else
        echo "ngrok token NOT registered (missing token or binary)"
        return 1
    fi
}

step_serve_app() {
    cd "${REPO_ROOT}"
    [ -f "${APP_DIR}/artisan" ] || { echo "no ${APP_DIR}/artisan — skipped"; return 0; }
    pkill -f "artisan serve" >/dev/null 2>&1 || true
    cd "${APP_DIR}"
    nohup php artisan serve --host=0.0.0.0 --port=8000 >/tmp/laravel-serve.log 2>&1 &
    sleep 2
    tail -2 /tmp/laravel-serve.log
}

# ---------- run the steps ----------
step "1. Composer self-update"        step_composer_selfupdate
step "2. PHP pdo_mysql extension"     step_php_extensions
step "3. Database CA certificate"     step_copy_ca
step "4. Clone application"           step_clone_app
step "5. composer install"            step_composer_install
step "6. .env + APP_KEY + DB creds"   step_env_file
step "7. npm install"                 step_npm_install
step "8. Tailwind build"              step_npm_build
step "9. OpenCode"                    step_opencode
step "10. ngrok"                      step_ngrok
step "11. serve & link commands"      step_helper_commands
step "12. Start dev server"           step_serve_app

# ---------- environment diagnostics ----------
cd "${REPO_ROOT}"
echo ""
echo "────────────── DIAGNOSTICS ──────────────"
php -v 2>/dev/null | head -1 || echo "php missing"
composer -V 2>/dev/null || echo "composer missing"
node -v 2>/dev/null || echo "node missing"
npm -v 2>/dev/null || echo "npm missing"
(command -v ngrok && ngrok --version) 2>/dev/null || echo "ngrok not available"
(command -v opencode && opencode --version) 2>/dev/null || echo "opencode not available"
[ -f "$HOME/.mysql-ca.pem" ]        && echo "SSL CA file: present" || echo "SSL CA file: MISSING"
[ -f "${REPO_ROOT}/${APP_DIR}/.env" ]         && echo ".env file: present"   || echo ".env file: MISSING"
[ -d "${REPO_ROOT}/${APP_DIR}/vendor" ]       && echo "vendor/: present"     || echo "vendor/: MISSING"
[ -d "${REPO_ROOT}/${APP_DIR}/node_modules" ] && echo "node_modules/: present" || echo "node_modules/: MISSING"
[ -d "${REPO_ROOT}/${APP_DIR}/public/build" ] && echo "public/build/: present" || echo "public/build/: MISSING"
pgrep -f "artisan serve" >/dev/null && echo "dev server: RUNNING on :8000" || echo "dev server: NOT running"
curl -s -o /dev/null -w "port 8000 HTTP code: %{http_code}\n" --max-time 3 http://localhost:8000 || true
echo "ngrok S3 reachability: $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://ngrok-agent.s3.amazonaws.com/ || echo unreachable)"

# ---------- summary ----------
echo ""
echo "══════════════════════════════════════════════════════"
echo "  SUMMARY"
echo "══════════════════════════════════════════════════════"
if [ ${#PASSED[@]} -gt 0 ]; then
    for s in "${PASSED[@]}"; do echo "✅ OK:      $s"; done
fi
for s in "${SKIPPED[@]:-}"; do
    [ -n "$s" ] && echo "⏭️  SKIPPED: $s"
done
if [ ${#FAILED[@]} -gt 0 ]; then
    for s in "${FAILED[@]}"; do
        echo "❌ FAILED:  $s"
    done
    echo ""
    echo "⚠️  ${#FAILED[@]} step(s) failed."
    echo "   👉 Open post-create-report.txt (this file, repo root) and"
    echo "      send its full content to your assistant."
else
    echo "🎉 ALL STEPS PASSED — try:  link"
fi
echo "Report saved to: ${REPORT_FILE}"
