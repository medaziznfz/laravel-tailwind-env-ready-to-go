# 🚀 Laravel + Tailwind — Ready-to-Go Codespace Template

One-click GitHub Codespace that provisions a **fully running Laravel + Tailwind CSS application**, backed by a cloud MySQL database, exposed to the internet through **ngrok** — with zero local setup.

[![PHP](https://img.shields.io/badge/PHP-8.5-777BB4?logo=php&logoColor=white)](https://www.php.net/releases/8.5/)
[![Node.js](https://img.shields.io/badge/Node.js-26-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![Composer](https://img.shields.io/badge/Composer-latest-885630?logo=composer&logoColor=white)](https://getcomposer.org/)
[![MySQL](https://img.shields.io/badge/MySQL-Aiven%20Cloud-4479A1?logo=mysql&logoColor=white)](https://aiven.io/)
[![ngrok](https://img.shields.io/badge/Tunnel-ngrok-1F1E37?logo=ngrok&logoColor=white)](https://ngrok.com/)
[![OpenCode](https://img.shields.io/badge/AI%20agent-OpenCode-black)](https://opencode.ai/)
[![Platform](https://img.shields.io/badge/Platform-Codespaces-24292f?logo=github&logoColor=white)](https://github.com/features/codespaces)

---

## ✨ What you get

| Component | Detail |
|---|---|
| 🐘 **PHP 8.5.12** (latest stable) | [official devcontainer image](https://mcr.microsoft.com/devcontainers/php), Debian 13 *trixie* |
| 🎼 **Composer** | self-updated to the **latest release** on every build |
| 🟩 **Node.js 26 + npm 11** | installed via devcontainer feature |
| 🗄️ **Cloud MySQL** | Aiven instance — **no database runs inside the Codespace** |
| 🔐 **SSL by default** | committed `certs/ca.pem` wired into Laravel's `MYSQL_ATTR_SSL_CA` |
| 🌐 **ngrok tunnel** | the app is public at a stable `...ngrok-free.app` URL |
| 🔌 **Reverb WebSocket** | real-time notifications on port 8080, auto-started |
| 📬 **Queue worker** | database-backed worker, auto-started |
| 🤖 **OpenCode V2** | AI coding agent CLI, auto-updated to latest |
| 🖥️ **Auto-serving** | the app is already running on port 8000 when you arrive |

## 📁 Repository structure

```
.
├── .devcontainer/
│   ├── devcontainer.json      # container recipe: image, features, ports, extensions
│   └── post-create.sh         # full auto-setup, runs on Codespace creation
├── bin/
│   ├── dev                    # start app + Reverb + queue worker
│   ├── serve                  # restart the Laravel dev server (background)
│   ├── reverb                 # restart the Reverb WebSocket server
│   ├── queue                  # restart the queue worker
│   ├── link                   # print/update the public ngrok URLs
│   └── doctor                 # health check for all services
├── certs/
│   └── ca.pem                 # database CA certificate (Aiven SSL)
└── README.md
```

## ⚡ Quick start

1. **Add your credentials as Codespaces secrets (once, 1 minute)**

   The repo never stores your database password or ngrok token — GitHub injects them into the Codespace automatically:

   1. Open the repo → **Settings → Secrets and variables → Codespaces** (or *avatar → Settings → Codespaces → Codespaces secrets*)
   2. Add **two secrets**:

      | Name | Value |
      |---|---|
      | `DB_PASSWORD` | your database password |
      | `NGROK_AUTHTOKEN` | your [ngrok authtoken](https://dashboard.ngrok.com/get-started/your-authtoken) |

   3. In **Repository access**, select this repository.

   > Each user of the template does this from **their own account** with their own values — nothing database-related is shared.

2. **Use this template** — `Use this template → Create a new repository` (or fork)
3. **Open a Codespace** — `Code ▾ → Codespaces → Create codespace on main`
3. **Wait a few minutes** — the setup script runs 12 steps, shows a ✅/❌ verdict for each one, and ends with a summary:

   ```
   ── [1/12] Codespace secrets (DB_PASSWORD, NGROK_AUTHTOKEN)
       ✅ PASSED
   ── [2/12] Composer — latest version
       ✅ PASSED
   …

   ✅ ALL 12 STEPS PASSED — app on http://localhost:8000
   ```

   If a step fails, check the details in the terminal or the full log: `post-create-report.txt` (repo root).

4. **Get your public link** — in the terminal, type:

   ```bash
   link
   # → https://xxxx-xx-xx-xx-xx.ngrok-free.app
   #   🔌 Reverb WebSocket: https://yyyy-xx-xx-xx-xx.ngrok-free.app
   ```

> Forgot to set a secret? No problem — at Codespace creation the script prints exactly which credential is missing and how to add it. Until then you can also edit `.env` inside the app folder by hand.

That's it — the app is live on the internet, sharing your terminal session's Codespace, connected to the cloud database.

## 🛠️ Commands

| Command | Description |
|---|---|
| `dev` | Start/restart **all three services**: Laravel, Reverb, queue worker |
| `link` | Print the **public app + WebSocket URLs** (starts/reuses both tunnels, syncs `APP_URL` + `REVERB_PUBLIC_*`) |
| `serve` | Restart the Laravel dev server on **port 8000** (background, log at `/tmp/laravel-serve.log`) |
| `reverb` | Restart the Reverb WebSocket server on **port 8080** (log at `/tmp/laravel-reverb.log`) |
| `queue` | Restart the queue worker (log at `/tmp/laravel-queue.log`) |
| `doctor` | Check app / Reverb / queue / config / tunnels in one shot |
| `opencode` | AI coding agent ([docs](https://opencode.ai/v2/docs)) — sign in once via the TUI |
| `npm run dev` | Tailwind / Vite **watch mode** on port 5173 (inside the app folder) |

Forwarded ports: `8000` (Laravel) · `8080` (Reverb WebSocket) · `5173` (Vite)

## 🔌 Real-time (Reverb) & queues

The Codespace keeps three processes alive in the background:

| Service | Port | Log |
|---|---|---|
| Laravel (`php artisan serve`) | 8000 | `/tmp/laravel-serve.log` |
| Reverb (`php artisan reverb:start --debug`) | 8080 | `/tmp/laravel-reverb.log` |
| Queue worker (`php artisan queue:work`) | — | `/tmp/laravel-queue.log` |

`link` opens **two** ngrok tunnels — one for the app and one for Reverb — then rewrites
`APP_URL` and `REVERB_PUBLIC_*` in the app `.env`, so the browser's Echo client connects to
`wss://<reverb-tunnel>.ngrok-free.app`. Without `link`, the browser uses
`ws://localhost:8080`, which works through Codespaces port forwarding.

The setup generates `REVERB_APP_ID` / `REVERB_APP_KEY` / `REVERB_APP_SECRET` once and keeps
them across rebuilds. `BROADCAST_CONNECTION=reverb` and `QUEUE_CONNECTION=database` are set
automatically; the `jobs` and `failed_jobs` tables already exist in the cloud database.

Verify everything with:

```bash
doctor
```


## 🗄️ Database

The connection targets a **cloud MySQL instance** (Aiven) — nothing is installed locally:

```env
DB_CONNECT=mysql
DB_HOST=mysql-onpc-onpc.g.aivencloud.com
DB_PORT=15850
DB_DATABASE=defaultdb
DB_USERNAME=avnadmin
MYSQL_ATTR_SSL_CA=~/.mysql-ca.pem    # ← copy of certs/ca.pem
```

- `certs/ca.pem` is copied to `~/.mysql-ca.pem` at creation (persistent across rebuilds) and referenced from `.env` — this satisfies Aiven's required TLS connection.
- **Migrations are never run automatically.** The database tables already exist — if you ever need to migrate manually, run `php artisan migrate` inside the app folder *knowing what it touches*.
- All non-secret values (host, port, database, user) live at the top of `.devcontainer/post-create.sh`.
- **Secrets are handled through GitHub Codespaces secrets** (`DB_PASSWORD`, `NGROK_AUTHTOKEN`) — nothing credential-like is ever committed (GitHub's push protection would block it anyway).

## 🔒 Security

- The repository contains **no live credentials** — passwords come from Codespace secrets, injected as environment variables into the Codespace only for accounts that configured them.
- GitHub's **push protection** keeps verifying every push: any accidentally added credential is rejected before it lands.
- ngrok tokens are scoped per-account; each user tunnels with their own.

## 🎛️ Customization

Everything lives in **two files** — no container knowledge needed:

| Change | Where |
|---|---|
| App repository / folder name | `REPO_URL` — the clone folder is the real repo name (e.g. `Laravel-adm-tawilwindcss`), derived automatically from the URL |
| Database host / name / user | `DB_*` block — `.devcontainer/post-create.sh` |
| PHP version | image tag in `.devcontainer/devcontainer.json` (e.g. `4.1.7-8.5-trixie` → swap `8.4`) |
| Node.js version | `"version": "26"` under `features` |
| Credentials | Codespace secrets: `DB_PASSWORD`, `NGROK_AUTHTOKEN` |

One nuance to know: DB values are written as `"quoted"` strings into the app `.env` (safe for passwords with special chars), and keys not in the replacement list (e.g. custom keys like `PREVENTION_API_*`) survive untouched.

## 🖥️ Local run (optional, no Codespaces)

The container commands also work in a plain local terminal, as long as you have PHP ≥ 8.2 + Composer + Node installed:

```bash
composer install
cp .env.example .env && php artisan key:generate
php artisan serve && npm run dev
```

## 🧰 Troubleshooting

| Symptom | Fix |
|---|---|
| `Connection refused` / timeout to DB | Check `DB_HOST`/`DB_PORT` at the top of `post-create.sh`, and that the Aiven instance is running |
| `certificate verify failed` | `cp certs/ca.pem ~/.mysql-ca.pem` then retry; if persistent, verify the Aiven CA hasn't rotated |
| Tunnel didn't come up | `cat /tmp/ngrok.log` (app) / `cat /tmp/ngrok-reverb.log` (Reverb); ensure the token is valid — check `ngrok config check` |
| Notifications not instant | `doctor`; confirm `BROADCAST_CONNECTION=reverb` and check `/tmp/laravel-reverb.log`; run `link` so `REVERB_PUBLIC_*` matches the current tunnel |
| Reverb exits with `Undefined constant SIGINT` | `pcntl` is missing — rerun the setup (PHP extensions step) or `sudo docker-php-ext-install pcntl` |
| Queue jobs not processed | `doctor`; check `/tmp/laravel-queue.log`; run `queue` to restart the worker |
| Blank page / 500 on first visit | `tail -f storage/logs/laravel.log` in the app folder — usually a missing table or cache permission |
| `asset()` URLs wrong (mixed content) | Run `link` again — it syncs `APP_URL` to the current tunnel |

---

**Stack:** Laravel · Tailwind CSS · Vite · Reverb · Queues · MySQL (Aiven) · ngrok · OpenCode · VS Code · GitHub Codespaces
