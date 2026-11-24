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

# the app is cloned into a folder named after the real repository
# (last segment of REPO_URL, without the .git suffix) — e.g.
# Laravel-adm-tawilwindcss — not into a generic "src" folder
APP_DIR="$(basename "${REPO_URL}" .git)"
export APP_DIR                           # so serve/link inherit the right folder

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

# read KEY's value from an env file (quotes stripped), empty when absent
get_env_value() {
    local key="$1" file="$2"
    [ -f "${file}" ] || return 0
    sed -n "s/^${key}=//p" "${file}" | head -n1 \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# set KEY only when it is missing or empty — keeps generated secrets stable
# across rebuilds
ensure_env_key() {
    local key="$1" value="$2" file="$3"
    if [ -z "$(get_env_value "${key}" "${file}")" ]; then
        set_env_key "${key}" "${value}" "${file}"
    fi
}

# random hex string (openssl, falling back to PHP)
gen_hex() {
    openssl rand -hex "$1" 2>/dev/null || php -r "echo bin2hex(random_bytes($1));" 2>/dev/null
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

# ------------------- 3. PHP extensions ------------------------
# pdo_mysql  → cloud MySQL
# pcntl      → required by `php artisan reverb:start` (signal handling)
ensure_php_ext() {
    local ext="$1"
    if php -m 2>/dev/null | grep -qiE "^${ext}$"; then
        ok "${ext} already loaded"
        return 0
    fi
    echo "    … compiling ${ext} (~1 min, silent — log: /tmp/${ext}-build.log) …"
    sudo -E docker-php-ext-install "${ext}" >"/tmp/${ext}-build.log" 2>&1 || true
    # docker-php-ext-enable loses PHP_INI_DIR under sudo — run it with the env restored
    sudo PHP_INI_DIR=/usr/local/etc/php docker-php-ext-enable "${ext}" >/dev/null 2>&1 || true
    # belt & braces: write the ini file directly
    sudo sh -c "mkdir -p /usr/local/etc/php/conf.d \
        && echo extension=${ext}.so > /usr/local/etc/php/conf.d/docker-php-ext-${ext}.ini"
    if php -m 2>/dev/null | grep -qiE "^${ext}$"; then
        ok "${ext} loaded"
        return 0
    fi
    warn "${ext} still not loaded — last log lines:"
    tail -5 "/tmp/${ext}-build.log" 2>/dev/null | sed 's/^/        /'
    return 1
}

phase_pdo_mysql() {
    local rc=0
    ensure_php_ext pdo_mysql || rc=1
    ensure_php_ext pcntl     || rc=1
    if [ "${rc}" -ne 0 ]; then
        echo "        scan dir: $(php -r 'echo PHP_CONFIG_FILE_SCAN_DIR;' 2>/dev/null)"
        echo "        installed extensions:"
        ls -1 /usr/local/lib/php/extensions/*/ 2>/dev/null | sed 's/^/          /'
    fi
    return "${rc}"
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
    # cleanup: older versions of this template cloned the app into
    # "src/" — remove that legacy folder if it still exists
    [ -d "src" ] && rm -rf "src"
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
    # Always run install: it is fast when the lock file is already satisfied,
    # and it picks up newly-added packages (e.g. laravel/reverb) after a pull.
    echo "    … composer install (syncs composer.lock) …"
    if (cd "${APP_DIR}" && composer install --no-interaction --no-progress >/tmp/composer-install.log 2>&1); then
        ok "PHP dependencies installed"
        return 0
    fi
    warn "composer install failed — last lines:"
    tail -10 /tmp/composer-install.log | sed 's/^/        /'
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

        # ── Reverb (WebSocket) + queue ────────────────────────────────
        # Credentials are generated once and kept across rebuilds.
        set_env_key BROADCAST_CONNECTION reverb .env
        set_env_key QUEUE_CONNECTION     database .env
        ensure_env_key REVERB_APP_ID     "$(php -r 'echo random_int(100000, 999999);' 2>/dev/null)" .env
        ensure_env_key REVERB_APP_KEY    "$(gen_hex 16)" .env
        ensure_env_key REVERB_APP_SECRET "$(gen_hex 32)" .env
        set_env_key REVERB_HOST        127.0.0.1 .env
        set_env_key REVERB_PORT        8080      .env
        set_env_key REVERB_SCHEME      http      .env
        set_env_key REVERB_SERVER_HOST 0.0.0.0   .env
        set_env_key REVERB_SERVER_PORT 8080      .env
        # Browser-facing defaults; `link` repoints these at the public
        # ngrok WebSocket URL once a tunnel exists. Without a tunnel, use
        # the Codespaces-forwarded HTTPS port (works in the web editor and
        # desktop VS Code) and fall back to localhost elsewhere.
        if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
            WS_PUBLIC_HOST="${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
            WS_PUBLIC_PORT=443
            WS_PUBLIC_SCHEME=https
        else
            WS_PUBLIC_HOST=localhost
            WS_PUBLIC_PORT=8080
            WS_PUBLIC_SCHEME=http
        fi
        set_env_key REVERB_PUBLIC_HOST   "${WS_PUBLIC_HOST}"   .env
        set_env_key REVERB_PUBLIC_PORT   "${WS_PUBLIC_PORT}"   .env
        set_env_key REVERB_PUBLIC_SCHEME "${WS_PUBLIC_SCHEME}" .env

        php artisan config:clear >/dev/null 2>&1 || true

        echo "    ✓ APP_KEY + database credentials written to ${APP_DIR}/.env"
        echo "    ✓ Reverb credentials + queue config written to ${APP_DIR}/.env"
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

# ------------------- 10. ngrok (official apt repository) -------
# apt is the most reliable method on Codespaces (Ubuntu/Debian) —
# the standalone .tgz archive moved hosts once already, so we dropped it.
phase_ngrok() {
    if [ -n "${NGROK_AUTHTOKEN}" ]; then
        printf '%s' "${NGROK_AUTHTOKEN}" > "$HOME/.ngrok-token"
    fi
    if command -v ngrok >/dev/null 2>&1; then
        ok "$(ngrok --version 2>/dev/null) already available"
    else
        echo "    … installing ngrok via the official apt repository (may take a minute) …"
        curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
            | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" \
            | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
        sudo apt-get update -qq \
            && sudo apt-get install -y -qq ngrok \
            || { warn "ngrok install failed — check the network or the ngrok repository"; return 1; }
        ok "ngrok installed via apt"
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
    local missing=0 SRC CMD
    for SRC in "${REPO_ROOT}"/bin/*; do
        [ -f "${SRC}" ] || continue
        CMD="$(basename "${SRC}")"
        cp "${SRC}" "${BIN_DIR}/${CMD}"
        chmod +x "${BIN_DIR}/${CMD}"
        sudo ln -sf "${BIN_DIR}/${CMD}" "/usr/local/bin/${CMD}" 2>/dev/null
        ok "${CMD} → ${BIN_DIR}/${CMD}"
    done
    for CMD in serve link reverb queue dev; do
        if [ ! -x "${BIN_DIR}/${CMD}" ]; then
            warn "bin/${CMD} missing in the template repo"
            missing=1
        fi
    done
    return "${missing}"
}

# ------------------- 12. Start app services -------------------
phase_services() {
    if [ ! -f "${APP_DIR}/artisan" ]; then
        warn "app not present — cannot start the services"
        return 1
    fi

    local rc=0

    "${BIN_DIR}/dev" >/dev/null 2>&1 || { warn "dev reported an error"; rc=1; }

    # Laravel
    local tries
    for tries in 1 2 3 4 5; do
        if curl -s --max-time 2 -o /dev/null http://localhost:8000; then
            ok "Laravel answering on http://localhost:8000"
            break
        fi
        sleep 1
    done
    if ! curl -s --max-time 2 -o /dev/null http://localhost:8000; then
        warn "Laravel not answering on :8000 — try: serve"
        rc=1
    fi

    # Reverb
    if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
        ok "Reverb listening on ws://localhost:8080"
    else
        warn "Reverb not listening on :8080 — try: reverb"
        rc=1
    fi

    # Queue worker
    if pgrep -f "[a]rtisan queue:work" >/dev/null 2>&1; then
        ok "queue worker running"
    else
        warn "queue worker not running — try: queue"
        rc=1
    fi

    return "${rc}"
}

# ================= main run ====================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Codespace setup — Laravel + Tailwind + cloud MySQL      ║"
echo "╚══════════════════════════════════════════════════════════╝"

step "Codespace secrets (DB_PASSWORD, NGROK_AUTHTOKEN)"; phase_secrets;         end_step $?
step "Composer — latest version";                       phase_composer;        end_step $?
step "PHP extensions (pdo_mysql, pcntl)";               phase_pdo_mysql;       end_step $?
step "Database CA certificate";                         phase_ca;              end_step $?
step "Clone application";                               phase_clone;           end_step $?
step "PHP dependencies (composer install)";             phase_composer_install; end_step $?
step ".env, APP_KEY and DB credentials";                phase_env;             end_step $?
step "npm install + Tailwind build";                    phase_npm;             end_step $?
step "OpenCode (V2)";                                   phase_opencode;        end_step $?
step "ngrok";                                           phase_ngrok;           end_step $?
step "serve & link commands";                           phase_commands;        end_step $?
step "Start app, queue & Reverb";                      phase_services;        end_step $?

# ------------------- summary ----------------------------------
echo ""
echo "════════════════ SETUP SUMMARY ════════════════"
for P in "${PASSED[@]}"; do echo "  ✅ ${P}"; done
for F in "${FAILED[@]}"; do echo "  ❌ ${F}"; done
echo "────────────────────────────────────────────────"
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "✅ ALL ${TOTAL} STEPS PASSED — app on http://localhost:8000"
    echo "   link     → print the public app + WebSocket URLs"
    echo "   dev      → restart app, Reverb and the queue worker"
    echo "   doctor   → check app / Reverb / queue / tunnels"
    echo "   opencode → AI coding agent"
else
    echo "⚠  ${#FAILED[@]} step(s) failed — check the details above,"
    echo "   or open ${REPORT_FILE}"
fi
echo "════════════════════════════════════════════════"
