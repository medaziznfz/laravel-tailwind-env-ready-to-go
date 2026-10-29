#!/usr/bin/env bash
# =============================================================
# Codespace post-create setup
# 1. Updates Composer to the latest release
# 2. Copies the database SSL certificate (certs/ca.pem) to the container home
# 3. Clones the Laravel + Tailwind app into ./src
# 4. composer install
# 5. Creates .env from .env.example, generates APP_KEY
# 6. Writes the outside-database credentials
# 7. npm install + build (Tailwind)
# 8. Updates OpenCode (AI coding agent, V2) to the latest version
# 9. Installs ngrok + installs the `serve` and `link` commands from bin/
# 10. Starts the Laravel dev server in the background
# NO migrations are run — the app uses an existing database.
# =============================================================
set -euo pipefail

# --- Configuration (edit here if needed) ----------------------
REPO_URL="https://github.com/S-Marouene/Laravel-adm-tawilwindcss.git"
APP_DIR="src"

# Database: an outside Aiven MySQL instance (no DB in the Codespace)
DB_CONNECTION=mysql
DB_HOST=mysql-onpc-onpc.g.aivencloud.com
DB_PORT=15850
DB_DATABASE=defaultdb
DB_USERNAME=avnadmin
# The database password is NOT in this file (GitHub blocks committing it).
# It is read from a GitHub Codespace secret named DB_PASSWORD:
#   avatar → Settings → Codespaces → Codespaces secrets → New secret
# then set "Repository access" to this repo and rebuild the Codespace.
DB_PASSWORD="${DB_PASSWORD:-}"
# Aiven requires SSL. certs/ca.pem (committed in this repo) is the
# database CA certificate — it is copied into the container home and
# the path is written into .env as MYSQL_ATTR_SSL_CA.
CA_FILE="certs/ca.pem"              # file in this repo
CA_DEST="$HOME/.mysql-ca.pem"       # path written into src/.env

# ngrok authtoken — also read from a Codespace secret named NGROK_AUTHTOKEN
# (no token is stored in this file)
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"
# --------------------------------------------------------------

if [ -z "${DB_PASSWORD:-}" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "!! DB_PASSWORD is empty — the database secret was not injected."
    echo "   Fix (only once, takes 1 minute):"
    echo "     1. Open https://github.com/settings/codespaces"
    echo "     2. Under 'Codespaces secrets' → New secret"
    echo "          Name:  DB_PASSWORD"
    echo "          Value: your database password"
    echo "     3. Repository access → select this repository"
    echo "     4. Rebuild the Codespace (Codespaces tab → rebuild)"
    echo "   The setup continues now, but the app won't reach the DB"
    echo "   until the .env has a real password (edit src/.env manually)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
if [ -z "${NGROK_AUTHTOKEN:-}" ] && ! [ -f "$HOME/.ngrok-token" ]; then
    echo "!! NGROK_AUTHTOKEN secret not set — see https://github.com/settings/codespaces"
    echo "   (or run 'ngrok config add-authtoken <token>' manually)."
fi

echo "==> Updating Composer to the latest release"
sudo -E composer self-update

# SSL certificate for the outside database
echo "==> Copying database CA certificate to ${CA_DEST}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "${REPO_ROOT}/${CA_FILE}" ]; then
    cp "${REPO_ROOT}/${CA_FILE}" "${CA_DEST}"
else
    echo "!! ${CA_FILE} not found in the template repo — SSL may fail"
fi

echo "==> Cloning application into ./${APP_DIR}"
if [ ! -f "${APP_DIR}/artisan" ]; then
    rm -rf "${APP_DIR}"
    git clone "${REPO_URL}" "${APP_DIR}"
elif [ -d "${APP_DIR}/.git" ]; then
    git -C "${APP_DIR}" pull --ff-only || true
fi

cd "${APP_DIR}"

echo "==> composer install"
composer install --no-interaction

if [ ! -f .env ]; then
    echo "==> Creating .env"
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        touch .env
    fi
fi

# Helper: replace KEY=value in .env, or append it if missing
set_env_key() {
    local key="$1" value="$2"
    if grep -qE "^${key}=.*" .env; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" .env
    else
        printf '%s="%s"\n' "${key}" "${value}" >> .env
    fi
}

echo "==> Generating APP_KEY"
if grep -qE '^APP_KEY=$' .env || ! grep -qE '^APP_KEY=.*[[:alnum:]]' .env; then
    php artisan key:generate --force
fi

echo "==> Writing database credentials into .env"
set_env_key DB_CONNECTION "${DB_CONNECTION}"
set_env_key DB_HOST "${DB_HOST}"
set_env_key DB_PORT "${DB_PORT}"
set_env_key DB_DATABASE "${DB_DATABASE}"
set_env_key DB_USERNAME "${DB_USERNAME}"
set_env_key DB_PASSWORD "${DB_PASSWORD}"
set_env_key MYSQL_ATTR_SSL_CA "$CA_DEST"

if [ -f package.json ]; then
    echo "==> npm install"
    npm install --no-audit --no-fund
    if npm run 2>&1 | grep -qE "build"; then
        echo "==> npm run build"
        npm run build || echo "!! Tailwind build failed — check package.json scripts"
    fi
fi

# ---------------- OpenCode (AI coding agent) -----------------
# Official V2 package (https://opencode.ai/v2/docs):
#   npm install -g @opencode/cli
# Its postinstall script selects the native binary for the platform.
if command -v opencode >/dev/null 2>&1; then
    echo "==> Updating OpenCode (V2) to the latest version"
    sudo npm install -g @opencode/cli@latest || echo "!! OpenCode update failed — run: sudo npm i -g @opencode/cli"
else
    echo "==> Installing OpenCode V2 (latest)"
    sudo npm install -g @opencode/cli@latest || echo "!! OpenCode install failed — run: sudo npm i -g @opencode/cli"
fi

# ---------------- ngrok + helper commands --------------------
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
if [ ! -x "${BIN_DIR}/ngrok" ] && ! command -v ngrok >/dev/null 2>&1; then
    echo "==> Installing ngrok"
    case "$(uname -m)" in
        aarch64 | arm64) NGROK_ARCH="linux-arm64" ;;
        *)               NGROK_ARCH="linux-amd64" ;;
    esac
    curl -fsSL "https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-${NGROK_ARCH}.tgz" \
        | tar -xz -C "$BIN_DIR"
    chmod +x "$BIN_DIR/ngrok"
fi
sudo ln -sf "${BIN_DIR}/ngrok" /usr/local/bin/ngrok

# persist the authtoken (home dir survives Codespace rebuilds)
if [ -n "${NGROK_AUTHTOKEN:-}" ]; then
    printf '%s' "${NGROK_AUTHTOKEN}" > "$HOME/.ngrok-token"
fi
if [ -f "$HOME/.ngrok-token" ]; then
    "${BIN_DIR}/ngrok" config add-authtoken "$(cat "$HOME/.ngrok-token")" >/dev/null
fi

# install the committed helper commands from the repo's bin/
for CMD in serve link; do
    if [ -f "${REPO_ROOT}/bin/${CMD}" ]; then
        cp "${REPO_ROOT}/bin/${CMD}" "${BIN_DIR}/${CMD}"
        chmod +x "${BIN_DIR}/${CMD}"
    else
        echo "!! bin/${CMD} missing in the template repo — command not installed"
    fi
done
sudo ln -sf "${BIN_DIR}/serve" /usr/local/bin/serve
sudo ln -sf "${BIN_DIR}/link" /usr/local/bin/link

# ---------------- start the app ------------------------------
if [ -f "${APP_DIR}/artisan" ]; then
    echo "==> Starting Laravel dev server"
    "${BIN_DIR}/serve" || true
fi

# NOTE: migrations are intentionally NOT run here.
# The app connects to an existing database, so run
# `php artisan migrate` manually only if/when needed.

echo ""
echo "✅ Setup complete."
echo "   App running:  http://localhost:8000  (already serving)"
echo "   Commands:     serve   → restart the app"
echo "                 link    → print your public ngrok URL"
echo "                 opencode → AI coding agent"
