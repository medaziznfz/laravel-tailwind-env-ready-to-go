#!/usr/bin/env bash
# ==============================================================
# Codespace post-create setup — Laravel + Tailwind + cloud MySQL
#
# Installs/updates: Composer (latest), PHP pdo_mysql, app deps,
# ngrok, OpenCode (V2) — then configures .env and starts the app.
#
# Verbose step-by-step output: every step prints a banner, a
# ✅ PASSED or ❌ FAILED verdict, and a final summary. The full
# log is also saved to post-create-report.txt (repo root).
#
# Credentials are NOT in this file. They come from Codespace
# secrets: DB_PASSWORD and NGROK_AUTHTOKEN (Repository access set).
# NO migrations are run — the app uses an existing database.
# ==============================================================

set -uo pipefail

# ------------------- configuration ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_FILE="${REPO_ROOT}/post-create-report.txt"
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

# ------------------- step engine ------------------------------
# everything the script prints also goes to the report file
exec > >(tee "${REPORT_FILE}") 2>&1

TOTAL=12
STEP_N=0
CURRENT=""
declare -a PASSED=() FAILED=()

ok()   { echo "    ✓ $*"; }
warn() { echo "    ⚠ $*"; }

step() {
    STEP_N=$((STEP_N + 1))
    echo ""
    echo "── [$STEP_N/${TOTAL}] $1"
    CURRENT="$1"
}

end_step() {
    if [ "$1" -eq 0 ]; then
        echo "    ✅ PASSED"
        PASSED+=("${CURRENT}")
    else
        echo "    ❌ FAILED"
        FAILED+=("${CURRENT}")
    fi
}

# replace KEY=value in a file, or append it when missing
set_env_key() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=.*" "${file}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        printf '%s="%s"\n' "${key}" "${value}" >> "${file}"
    fi
}

# ------------------- 1. Codespace secrets ---------------------
phase_secrets() {
    if [ -n "${DB_PASSWORD}" ]; then
        ok "DB_PASSWORD secret detected"
    else
        warn "DB_PASSWORD secret is EMPTY — the app will not reach the database"
        return 1
    fi
    if [ -n "${NGROK_AUTHTOKEN}" ] || [ -f "$HOME/.ngrok-token" ]; then
        ok "ngrok authtoken available"
    else
        warn "NGROK_AUTHTOKEN not set — 'link' will ask for it later"
    fi
    return 0
}

# ------------------- 2. Composer (latest) ---------------------
phase_composer() {
    if ! command -v composer >/dev/null 2>&1; then
        warn "composer binary not found"
        return 1
    fi
    sudo -E composer self-update >/dev/null 2>&1 || warn "self-update failed (continuing with bundled version)"
    ok "$(composer --version 2>/dev/null | head -n1)"
    return 0
}

# ------------------- 3. PHP pdo_mysql -------------------------
phase_pdo_mysql() {
    if php -m 2>/dev/null | grep -qiE '^pdo_mysql$'; then
        ok "pdo_mysql already loaded"
        return 0
    fi
    echo "    … compiling pdo_mysql (~1 min, silent — log: /tmp/pdo-build.log) …"
    sudo -E docker-php-ext-install pdo_mysql >/tmp/pdo-build.log 2>&1 \
        || { echo "    ⚠ compile — last lines:"; tail -5 /tmp/pdo-build.log | sed 's/^/        /'; }
    # docker-php-ext-enable loses PHP_INI_DIR under sudo — run it with the env restored
    sudo PHP_INI_DIR=/usr/local/etc/php docker-php-ext-enable pdo_mysql >/dev/null 2>&1 || true
    # belt & braces: write the ini file directly
    sudo sh -c 'mkdir -p /usr/local/etc/php/conf.d \
        && echo extension=pdo_mysql.so > /usr/local/etc/php/conf.d/docker-php-ext-pdo_mysql.ini'
    if php -m 2>/dev/null | grep -qiE '^pdo_mysql$'; then
        ok "pdo_mysql loaded"
        return 0
    fi
    warn "pdo_mysql still not loaded — diagnostics:"
    echo "        scan dir: $(php -r 'echo PHP_CONFIG_FILE_SCAN_DIR;' 2>/dev/null)"
    echo "        conf.d contents:"
    ls -1 /usr/local/etc/php/conf.d/ 2>/dev/null | sed 's/^/          /'
    echo "        installed extensions:"
    ls -1 /usr/local/lib/php/extensions/*/ 2>/dev/null | sed 's/^/          /'
    echo "        php startup output:"
    php -v 2>&1 | head -3 | sed 's/^/          /'
    return 1
}

# ------------------- 4. Database CA certificate ---------------
phase_ca() {
    if [ ! -f "${REPO_ROOT}/${CA_FILE}" ]; then
        warn "${CA_FILE} missing in the template repo"
        return 1
    fi
    cp -f "${REPO_ROOT}/${CA_FILE}" "${CA_DEST}"
    ok "CA certificate installed at ${CA_DEST}"
    return 0
}

# ------------------- 5. Clone the application -----------------
phase_clone() {
    cd "${REPO_ROOT}" || return 1
    if [ -f "${APP_DIR}/artisan" ]; then
        ok "application already present in ${APP_DIR}/"
        return 0
    fi
    rm -rf "${APP_DIR}"
    git clone --quiet "${REPO_URL}" "${APP_DIR}" || { warn "clone failed (${REPO_URL})"; return 1; }
    ok "cloned into ${APP_DIR}/"
    return 0
}

# ------------------- 6. PHP dependencies ----------------------
phase_composer_install() {
    if [ ! -f "${APP_DIR}/composer.json" ]; then
        warn "no composer.json in ${APP_DIR}/"
        return 1
    fi
    if [ -f "${APP_DIR}/vendor/autoload.php" ]; then
        ok "vendor/ already up to date"
        return 0
    fi
    echo "    … composer install (may take a couple of minutes) …"
    if (cd "${APP_DIR}" && composer install --no-interaction --no-progress); then
        ok "PHP dependencies installed"
        return 0
    fi
    warn "composer install failed"
    return 1
}

# ------------------- 7. .env + APP_KEY + credentials ----------
phase_env() {
    if [ ! -d "${APP_DIR}" ]; then
        warn "app directory missing"
        return 1
    fi
    (
        cd "${APP_DIR}" || exit 1
        if [ ! -f .env ]; then
            [ -f .env.example ] && cp .env.example .env || touch .env
        fi
        if grep -qE '^APP_KEY=$' .env || ! grep -qE '^APP_KEY=.*[[:alnum:]]' .env; then
            php artisan key:generate --force >/dev/null 2>&1 \
                || { echo "    ⚠ key:generate failed"; exit 1; }
        fi
        set_env_key DB_CONNECTION    "${DB_CONNECTION}" .env
        set_env_key DB_HOST          "${DB_HOST}"       .env
        set_env_key DB_PORT          "${DB_PORT}"       .env
        set_env_key DB_DATABASE      "${DB_DATABASE}"   .env
        set_env_key DB_USERNAME      "${DB_USERNAME}"   .env
        set_env_key DB_PASSWORD      "${DB_PASSWORD}"   .env
        set_env_key MYSQL_ATTR_SSL_CA "${CA_DEST}"      .env
        echo "    ✓ APP_KEY + database credentials written to ${APP_DIR}/.env"
    )
    return $?
}

# ------------------- 8. npm install + Tailwind build ----------
phase_npm() {
    if [ ! -f "${APP_DIR}/package.json" ]; then
        warn "no package.json in ${APP_DIR}/ — skipping"
        return 0
    fi
    (
        cd "${APP_DIR}" || exit 1
        echo "    … npm install …"
        npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 || { echo "    ⚠ npm install failed"; exit 1; }
        echo "    ✓ npm dependencies installed"
        if grep -qE '"build"' package.json; then
            echo "    … npm run build (Tailwind) …"
            npm run build --loglevel=error >/dev/null 2>&1 || { echo "    ⚠ npm run build failed"; exit 1; }
            echo "    ✓ assets built"
        fi
    )
    return $?
}

# ------------------- 9. OpenCode (V2) -------------------------
phase_opencode() {
    if command -v opencode >/dev/null 2>&1; then
        ok "$(opencode --version 2>/dev/null | head -n1) already available"
        return 0
    fi
    NPM_PREFIX="${HOME}/.npm-global"
    export NPM_CONFIG_PREFIX="${NPM_PREFIX}"
    mkdir -p "${NPM_PREFIX}"
    echo "    … npm install -g @opencode/cli (may take a minute) …"
    if ! npm install -g @opencode/cli@latest --loglevel=error >/dev/null 2>&1; then
        warn "OpenCode install failed — run: npm i -g @opencode/cli"
        return 1
    fi
    OPENCODE_BIN="$(find "${NPM_PREFIX}/bin" -maxdepth 1 -name 'opencode*' 2>/dev/null | head -n1)"
    if [ -n "${OPENCODE_BIN}" ]; then
        sudo ln -sf "${OPENCODE_BIN}" /usr/local/bin/opencode
        ok "opencode installed"
        return 0
    fi
    warn "opencode binary not found after install"
    return 1
}

# ------------------- 10. ngrok (direct → apt fallback) --------
phase_ngrok() {
    if [ -n "${NGROK_AUTHTOKEN}" ]; then
        printf '%s' "${NGROK_AUTHTOKEN}" > "$HOME/.ngrok-token"
    fi
    if command -v ngrok >/dev/null 2>&1; then
        ok "$(ngrok --version 2>/dev/null) already available"
    else
        mkdir -p "${BIN_DIR}"
        case "$(uname -m)" in
            aarch64 | arm64) NGROK_ARCH="linux-arm64" ;;
            *)               NGROK_ARCH="linux-amd64" ;;
        esac
        if curl -fsSL "https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-${NGROK_ARCH}.tgz" \
            | tar -xz -C "${BIN_DIR}" 2>/dev/null
        then
            chmod +x "${BIN_DIR}/ngrok"
            ok "ngrok downloaded"
        else
            # fallback: official apt repository
            echo "    … direct download failed, trying apt repository …"
            curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
                | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
            echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
                | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
            sudo apt-get update -qq && sudo apt-get install -y -qq ngrok \
                || { warn "ngrok install failed"; return 1; }
            ok "ngrok installed via apt"
        fi
    fi
    sudo ln -sf "$(command -v ngrok)" /usr/local/bin/ngrok 2>/dev/null
    if command -v ngrok >/dev/null 2>&1 && [ -f "$HOME/.ngrok-token" ]; then
        ngrok config add-authtoken "$(cat "$HOME/.ngrok-token")" >/dev/null
        ok "authtoken configured"
    fi
    command -v ngrok >/dev/null 2>&1
}

# ------------------- 11. serve & link commands ----------------
phase_commands() {
    mkdir -p "${BIN_DIR}"
    local missing=0
    for CMD in serve link; do
        if [ -f "${REPO_ROOT}/bin/${CMD}" ]; then
            cp "${REPO_ROOT}/bin/${CMD}" "${BIN_DIR}/${CMD}"
            chmod +x "${BIN_DIR}/${CMD}"
            sudo ln -sf "${BIN_DIR}/${CMD}" "/usr/local/bin/${CMD}" 2>/dev/null
            ok "${CMD} → ${BIN_DIR}/${CMD}"
        else
            warn "bin/${CMD} missing in the template repo"
            missing=1
        fi
    done
    return "${missing}"
}

# ------------------- 12. Start the dev server -----------------
phase_server() {
    if [ ! -f "${APP_DIR}/artisan" ]; then
        warn "app not present — cannot start the server"
        return 1
    fi
    "${BIN_DIR}/serve" >/dev/null 2>&1 || warn "serve reported an error"
    sleep 2
    pgrep -f "artisan serve" >/dev/null 2>&1 || { warn "server is not running — try: serve"; return 1; }
    if curl -s --max-time 3 -o /dev/null http://localhost:8000; then
        ok "app answering on http://localhost:8000"
    else
        warn "server process running but port 8000 not answering yet"
    fi
    return 0
}

# ================= main run ====================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Codespace setup — Laravel + Tailwind + cloud MySQL      ║"
echo "╚══════════════════════════════════════════════════════════╝"

step "Codespace secrets (DB_PASSWORD, NGROK_AUTHTOKEN)"; phase_secrets;         end_step $?
step "Composer — latest version";                       phase_composer;        end_step $?
step "PHP extension pdo_mysql";                         phase_pdo_mysql;       end_step $?
step "Database CA certificate";                         phase_ca;              end_step $?
step "Clone application";                               phase_clone;           end_step $?
step "PHP dependencies (composer install)";             phase_composer_install; end_step $?
step ".env, APP_KEY and DB credentials";                phase_env;             end_step $?
step "npm install + Tailwind build";                    phase_npm;             end_step $?
step "OpenCode (V2)";                                   phase_opencode;        end_step $?
step "ngrok";                                           phase_ngrok;           end_step $?
step "serve & link commands";                           phase_commands;        end_step $?
step "Start dev server";                                phase_server;          end_step $?

# ------------------- summary ----------------------------------
echo ""
echo "════════════════ SETUP SUMMARY ════════════════"
for P in "${PASSED[@]}"; do echo "  ✅ ${P}"; done
for F in "${FAILED[@]}"; do echo "  ❌ ${F}"; done
echo "────────────────────────────────────────────────"
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "✅ ALL ${TOTAL} STEPS PASSED — app on http://localhost:8000"
    echo "   link     → print the public ngrok URL"
    echo "   serve    → restart the dev server"
    echo "   opencode → AI coding agent"
else
    echo "⚠  ${#FAILED[@]} step(s) failed — check the details above,"
    echo "   or open ${REPORT_FILE}"
fi
echo "════════════════════════════════════════════════"
