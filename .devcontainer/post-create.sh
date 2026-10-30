#!/usr/bin/env bash
# ==============================================================
# Codespace post-create setup — Laravel + Tailwind + cloud MySQL
#
# Installs/updates: Composer (latest), PHP pdo_mysql, app deps,
# ngrok, OpenCode (V2) — then configures .env and starts the app.
#
# Output is intentionally concise: warnings only when something
# needs attention (e.g. missing Codespace secrets).
#
# Credentials are NOT in this file. They come from Codespace
# secrets: DB_PASSWORD and NGROK_AUTHTOKEN (Repository access set).
# NO migrations are run — the app uses an existing database.
# ==============================================================

set -uo pipefail

# ------------------- configuration ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="$HOME/.local/bin"

REPO_URL="https://github.com/S-Marouene/Laravel-adm-tawilwindcss.git"
APP_DIR="src"

DB_CONNECTION=mysql
DB_HOST=mysql-onpc-onpc.g.aivencloud.com
DB_PORT=15850
DB_DATABASE=defaultdb
DB_USERNAME=avnadmin
DB_PASSWORD="${DB_PASSWORD:-}"        # Codespace secret: DB_PASSWORD

CA_FILE="certs/ca.pem"                # committed database CA (Aiven SSL)
CA_DEST="$HOME/.mysql-ca.pem"

NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"  # Codespace secret: NGROK_AUTHTOKEN

warn() { echo "  ⚠  $*"; }

# replace KEY=value in a file, or append it when missing
set_env_key() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=.*" "${file}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        printf '%s="%s"\n' "${key}" "${value}" >> "${file}"
    fi
}

# missing secrets → tell the user once, clearly
if [ -z "${DB_PASSWORD}" ]; then
    echo "⚠  DB_PASSWORD secret not set — add it at github.com/settings/codespaces"
    echo "   (name: DB_PASSWORD, Repository access: this repo), then rebuild."
fi
if [ -z "${NGROK_AUTHTOKEN}" ] && [ ! -f "$HOME/.ngrok-token" ]; then
    echo "⚠  NGROK_AUTHTOKEN secret not set — 'link' will ask for it later."
fi

# ------------------- 1. Composer (latest) ---------------------
if ! sudo -E composer self-update --quiet >/dev/null 2>&1
then sudo -E composer self-update || warn "Composer self-update failed (continuing)"
fi

# ------------------- 2. PHP pdo_mysql -------------------------
# The PHP devcontainer image ships without the MySQL PDO driver.
if ! php -m 2>/dev/null | grep -qiE '^pdo_mysql$'; then
    sudo docker-php-ext-install pdo_mysql >/dev/null 2>&1 \
        || sudo -E docker-php-ext-install pdo_mysql || warn "pdo_mysql compile failed"
    # docker-php-ext-enable loses PHP_INI_DIR under sudo — write the ini directly
    sudo sh -c 'mkdir -p /usr/local/etc/php/conf.d \
        && echo extension=pdo_mysql.so > /usr/local/etc/php/conf.d/docker-php-ext-pdo_mysql.ini'
    php -m 2>/dev/null | grep -qiE '^pdo_mysql$' \
        || warn "pdo_mysql still not loaded"
fi

# ------------------- 3. Database CA certificate ---------------
if [ -f "${REPO_ROOT}/${CA_FILE}" ]; then
    cp -f "${REPO_ROOT}/${CA_FILE}" "${CA_DEST}"
else
    warn "${CA_FILE} missing in the template repo"
fi

# ------------------- 4. Clone the application -----------------
cd "${REPO_ROOT}"
if [ ! -f "${APP_DIR}/artisan" ]; then
    rm -rf "${APP_DIR}"
    git clone --quiet "${REPO_URL}" "${APP_DIR}" || \
        warn "repository clone failed (${REPO_URL})"
fi

# ------------------- 5. PHP dependencies ----------------------
if [ -f "${APP_DIR}/composer.json" ]; then
    (cd "${APP_DIR}" && composer install --no-interaction --quiet --no-progress) \
        || warn "composer install failed"
fi

# ------------------- 6. .env + APP_KEY + DB credentials -------
if [ -f "${APP_DIR}" ]; then
    cd "${APP_DIR}"
    if [ ! -f .env ]; then
        [ -f .env.example ] && cp .env.example .env || touch .env
    fi
    if grep -qE '^APP_KEY=$' .env || ! grep -qE '^APP_KEY=.*[[:alnum:]]' .env; then
        php artisan key:generate --force >/dev/null 2>&1 || warn "key:generate failed"
    fi
    set_env_key DB_CONNECTION "${DB_CONNECTION}" .env
    set_env_key DB_HOST       "${DB_HOST}"       .env
    set_env_key DB_PORT       "${DB_PORT}"       .env
    set_env_key DB_DATABASE   "${DB_DATABASE}"   .env
    set_env_key DB_USERNAME   "${DB_USERNAME}"   .env
    set_env_key DB_PASSWORD   "${DB_PASSWORD}"   .env
    set_env_key MYSQL_ATTR_SSL_CA "${CA_DEST}"   .env
fi

# ------------------- 7. npm install + Tailwind build ----------
if [ -f package.json ]; then
    npm install --no-audit --no-fund --loglevel=error \
        || warn "npm install failed"
    if grep -qE '"build"' package.json; then
        npm run build --loglevel=error >/dev/null 2>&1 || warn "npm run build failed"
    fi
fi

# ------------------- 8. OpenCode (V2) -------------------------
if ! command -v opencode >/dev/null 2>&1; then
    NPM_PREFIX="${HOME}/.npm-global"
    export NPM_CONFIG_PREFIX="${NPM_PREFIX}"
    mkdir -p "${NPM_PREFIX}"
    if npm install -g @opencode/cli@latest --loglevel=error >/dev/null 2>&1; then
        OPENCODE_BIN="$(find "${NPM_PREFIX}/bin" -maxdepth 1 -name 'opencode*' 2>/dev/null | head -n1)"
        [ -n "${OPENCODE_BIN}" ] && sudo ln -sf "${OPENCODE_BIN}" /usr/local/bin/opencode
    else
        warn "OpenCode install failed — run: npm i -g @opencode/cli"
    fi
fi

# ------------------- 9. ngrok (direct → apt fallback) ---------
if ! command -v ngrok >/dev/null 2>&1; then
    mkdir -p "${BIN_DIR}"
    case "$(uname -m)" in
        aarch64 | arm64) NGROK_ARCH="linux-arm64" ;;
        *)               NGROK_ARCH="linux-amd64" ;;
    esac
    if curl -fsSL "https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-${NGROK_ARCH}.tgz" \
        | tar -xz -C "${BIN_DIR}" 2>/dev/null
    then chmod +x "${BIN_DIR}/ngrok"
    else
        # fallback: official apt repository
        curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
            | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
            | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq ngrok \
            || warn "ngrok install failed"
    fi
fi
command -v ngrok >/dev/null 2>&1 && sudo ln -sf "$(command -v ngrok)" /usr/local/bin/ngrok 2>/dev/null

# persist the authtoken (home dir survives rebuilds)
if [ -n "${NGROK_AUTHTOKEN}" ]; then
    printf '%s' "${NGROK_AUTHTOKEN}" > "$HOME/.ngrok-token"
fi
if [ -f "$HOME/.ngrok-token" ] && command -v ngrok >/dev/null 2>&1; then
    ngrok config add-authtoken "$(cat "$HOME/.ngrok-token")" >/dev/null
fi

# ------------------- 10. serve & link commands ----------------
mkdir -p "${BIN_DIR}"
for CMD in serve link; do
    if [ -f "${REPO_ROOT}/bin/${CMD}" ]; then
        cp "${REPO_ROOT}/bin/${CMD}" "${BIN_DIR}/${CMD}"
        chmod +x "${BIN_DIR}/${CMD}"
        sudo ln -sf "${BIN_DIR}/${CMD}" "/usr/local/bin/${CMD}" 2>/dev/null
    else
        warn "bin/${CMD} missing in the template repo"
    fi
done

# ------------------- 11. Start the dev server -----------------
cd "${REPO_ROOT}"
if [ -f "${APP_DIR}/artisan" ] && [ -x "${BIN_DIR}/serve" ]; then
    "${BIN_DIR}/serve" >/dev/null 2>&1 || warn "dev server failed to start"
    sleep 2
    pgrep -f "artisan serve" >/dev/null 2>&1 || warn "dev server is not running — try: serve"
fi

# ------------------- done --------------------------------------
echo ""
echo "✅ Setup complete — app on http://localhost:8000"
echo "   link   → print the public ngrok URL"
echo "   serve  → restart the dev server"
echo "   opencode → AI coding agent"
